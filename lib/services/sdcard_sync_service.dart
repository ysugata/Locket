import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'omi_device_service.dart';
import 'sdcard_protocol.dart';
import 'wal_store.dart';

/// Syncs OPUS audio stored on the Omi CV1's SD card to the server.
///
/// Supports both legacy (single-file) and new multi-file protocols.
/// The protocol is auto-detected from storageInfo: if field[1] < 1000,
/// it's the new multi-file protocol (field[1] = fileCount); if >= 1000,
/// it's the legacy protocol (field[1] = byte offset).
///
/// Reliability rules (matched to fw 3.0.17 behavior, see
/// _syncMultiFile for the firmware-verified details):
/// - Reads time out on stream inactivity only, never mid-transfer,
///   and resume from the received byte offset after a stall.
/// - The firmware auto-deletes fully-streamed files itself; the client
///   never sends CMD_DELETE, and any audio whose upload failed is
///   persisted to the disk WAL because the device no longer has it.
class SDCardSyncService extends ChangeNotifier {
  final OmiDeviceService device;
  final String uploadUrl;
  final String authToken;
  final String deviceId;

  /// Safety net for firmware auto-delete: frames whose upload failed
  /// are persisted here (the device no longer has them).
  final WalStore? walStore;

  static const Duration _firstDataTimeout = Duration(seconds: 5);

  /// A transfer that keeps sending data never times out — hours of
  /// audio can take far longer than any fixed cap over BLE. Only a
  /// stalled stream (no notification for this long) is aborted.
  static const Duration _inactivityTimeout = Duration(seconds: 30);

  /// Backstop for a single read attempt. Combined with offset resume,
  /// even files larger than this window still complete.
  static const Duration _absoluteReadTimeout = Duration(hours: 2);

  /// After a stall, re-issue CMD_READ_FILE from the received offset
  /// this many times (each retry only happens when bytes advanced).
  static const int _maxReadAttempts = 10;

  static const Duration _httpTimeout = Duration(seconds: 60);
  static const int _httpMaxAttempts = 3;
  static const int _maxChunkBytes = 500 * 1024;

  /// CV1 firmware emits one OPUS frame per 10 ms.
  static const int _opusFrameMillis = 10;

  final ValueNotifier<double> progress = ValueNotifier(0.0);
  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// Bytes received in the current sync run (for the progress UI).
  final ValueNotifier<int> transferredBytes = ValueNotifier(0);
  int totalBytesOnCard = 0;

  /// Human-readable line describing what the sync is doing RIGHT NOW
  /// ("削除 応答待ち 42s / 最大90s" etc.), shown on the sync card so a
  /// long-running operation never looks frozen.
  final ValueNotifier<String?> currentActivity = ValueNotifier(null);

  /// 0..1 gauge for the current timed activity (null = hidden).
  final ValueNotifier<double?> activityProgress = ValueNotifier(null);

  Timer? _activityTicker;

  void _setActivity(String? text, {double? fraction}) {
    currentActivity.value = text;
    activityProgress.value = fraction;
    notifyListeners();
  }

  /// Rescue phase 1 — free space by confirmed deletes + probe reads.
  ///
  /// Field evidence (builds 10-12):
  /// - Delete FAILURES all map to code 0x7 and fast-fail while the SD
  ///   worker is busy, but a SUCCESS response (0x00) is real — the
  ///   firmware only sends it after the file was actually removed.
  ///   Persistence pays off: build 12 got a 0x00 on round 5.
  /// - The storage stats lag behind reality by MORE than a session
  ///   (firmware RAM caches refresh only on reboot when the worker is
  ///   wedged), so stats cannot be the success signal in-session.
  /// - The first index-0 entries are 0-byte boot files (unset RTC →
  ///   tiny hex timestamp → sorted first); several must be cleared
  ///   before deletes reach real data.
  ///
  /// Strategy: keep firing deletes and count 0x00 responses. Every
  /// [probeEvery] confirmed deletions, try ONE probe read — if audio
  /// flows, space/wedge has recovered and the drain can start. Stats
  /// are logged for reference only.
  Future<bool> _rescueFreeSpace() async {
    final deadline = DateTime.now().add(const Duration(minutes: 90));
    const maxConfirmedDeletes = 12;
    const probeEvery = 3;

    var confirmedDeletes = 0;
    var round = 0;
    var nextProbeAt = probeEvery;

    while (confirmedDeletes < maxConfirmedDeletes &&
        !_cancelled &&
        DateTime.now().isBefore(deadline)) {
      round++;
      // Never delete down to the last file — index 0 would then be the
      // current recording file, and the firmware happily deletes it,
      // recreates it, and we'd chew through it forever.
      try {
        final s = await device.getStorageList();
        if (s.length > 1 && s[1] <= 1) {
          _log('RESCUE: only the recording file remains — stopping deletes');
          break;
        }
      } catch (_) {}
      _setActivity('削除要求 ラウンド$round (確定削除 $confirmedDeletes件)...');
      int? code;
      try {
        code = await device.deleteStorageFile(
          0,
          timeout: const Duration(seconds: 30),
        );
      } catch (e) {
        _log('RESCUE round $round: delete write failed: $e');
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      if (_cancelled) break;

      if (code == 0x00) {
        confirmedDeletes++;
        sacrificedFiles.value = confirmedDeletes;
        _log(
          'RESCUE round $round: delete CONFIRMED (0x0) — '
          'total $confirmedDeletes',
        );
        await Future<void>.delayed(const Duration(seconds: 5));

        if (confirmedDeletes >= nextProbeAt) {
          nextProbeAt = confirmedDeletes + probeEvery;
          _log('RESCUE: probe read after $confirmedDeletes deletes');
          _setActivity('試し読み中（確定削除 $confirmedDeletes件後）— 最大35秒');
          final probe = await _readFile(0, expectedSize: 0);
          if (_cancelled) break;
          if (probe.frames.isNotEmpty) {
            _log(
              'RESCUE: PROBE SUCCESS — ${probe.frames.length} frames '
              'flowed, reads recovered',
            );
            // The firmware auto-deletes a fully-streamed file, so the
            // probe data may be the ONLY copy — secure it before
            // anything else.
            _setActivity('試し読みデータをアップロード中...');
            final secured = await _uploadOrSpill(
              probe.frames,
              probe.epochSeconds,
            );
            if (!secured) {
              lastError.value = '試し読みデータの保全に失敗しました。中断します';
              _setActivity(null);
              return false;
            }
            try {
              await device.stopStorageSync();
            } catch (_) {}
            await Future<void>.delayed(const Duration(milliseconds: 500));
            _setActivity(null);
            return true;
          }
          _log('RESCUE: probe still dry — continuing deletes');
          // The probe may have re-wedged the worker; give it a break.
          _setActivity('試し読み後のワーカー回復待ち（60秒）...');
          try {
            await device.stopStorageSync();
          } catch (_) {}
          await Future<void>.delayed(const Duration(seconds: 60));
        }
      } else if (code == null) {
        // Timeout: the request likely queued on the busy worker —
        // give it time to land before firing another.
        _log('RESCUE round $round: delete response timeout — waiting 60s');
        for (var i = 0; i < 60 && !_cancelled; i++) {
          _setActivity(
            '削除のキュー処理待ち ${i}s / 60s (ラウンド$round, '
            '確定削除 $confirmedDeletes件)',
            fraction: i / 60,
          );
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      } else {
        // Fast-fail (0x7 etc.): worker busy — short pause, refire.
        _log(
          'RESCUE round $round: busy response '
          '0x${code.toRadixString(16)} — retry in 20s',
        );
        for (var i = 0; i < 20 && !_cancelled; i++) {
          _setActivity(
            'SDワーカー多忙 — 20秒後に再試行 (ラウンド$round, '
            '確定削除 $confirmedDeletes件)',
            fraction: i / 20,
          );
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }

    // Final probe: even without reaching the budget, reads may have
    // recovered from the deletions that did land.
    if (!_cancelled && confirmedDeletes > 0) {
      _log('RESCUE: final probe read (confirmed=$confirmedDeletes)');
      _setActivity('最終確認の試し読み中...');
      final probe = await _readFile(0, expectedSize: 0);
      if (probe.frames.isNotEmpty) {
        _log('RESCUE: FINAL PROBE SUCCESS');
        _setActivity('試し読みデータをアップロード中...');
        final secured = await _uploadOrSpill(probe.frames, probe.epochSeconds);
        if (!secured) {
          lastError.value = '試し読みデータの保全に失敗しました。中断します';
          _setActivity(null);
          return false;
        }
        try {
          await device.stopStorageSync();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _setActivity(null);
        return true;
      }
    }

    _setActivity(null);
    _log(
      'RESCUE phase 1 result: confirmedDeletes=$confirmedDeletes '
      'rounds=$round — reads did not recover',
    );
    return false;
  }

  /// Upload frames, falling back to the disk WAL. The device may have
  /// already auto-deleted the source file, so a `false` return means
  /// the audio could be lost and the caller must stop the operation.
  Future<bool> _uploadOrSpill(List<Uint8List> frames, int? epochSeconds) async {
    if (frames.isEmpty) return true;
    final ts = _resolveTimestampStart(0, epochSeconds);
    final ok = await _uploadFrames(frames, timestampStart: ts);
    if (ok) return true;
    final store = walStore;
    if (store != null) {
      final body = encodeLengthPrefixedFrames(frames);
      final saved = await store.writeSegment(body, ts);
      if (saved) {
        _log('upload failed — spilled ${frames.length} frames to disk WAL');
        return true;
      }
    }
    return false;
  }

  /// Recent sync events, shown in the in-app debug sheet so failures
  /// can be diagnosed from TestFlight builds without a tethered device.
  final ValueNotifier<List<String>> debugLog = ValueNotifier<List<String>>(
    const [],
  );
  static const int _debugLogMax = 100;

  void _log(String entry) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final line = '$ts $entry';
    debugPrint('[SDSync] $line');
    final next = [line, ...debugLog.value];
    if (next.length > _debugLogMax) {
      next.removeRange(_debugLogMax, next.length);
    }
    debugLog.value = next;
  }

  StreamSubscription<List<int>>? _storageSub;
  bool _cancelled = false;

  SDCardSyncService({
    required this.device,
    required this.uploadUrl,
    required this.authToken,
    required this.deviceId,
    this.walStore,
  });

  Completer<void>? _activeCompleter;

  /// Cancel an in-progress sync immediately.
  void cancel() {
    _cancelled = true;
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.complete();
    }
    _storageSub?.cancel();
    _storageSub = null;
    _activityTicker?.cancel();
    _activityTicker = null;
  }

  /// True while a rescue sync (audio paused, sacrificial deletes
  /// allowed) is running — the UI labels the sync card accordingly.
  final ValueNotifier<bool> isRescue = ValueNotifier(false);

  /// Number of unreadable files sacrificed during the current rescue.
  final ValueNotifier<int> sacrificedFiles = ValueNotifier(0);

  Future<void> syncAll() => _run(rescue: false);

  /// Rescue sync for a wedged, full card: pauses the live audio
  /// subscription (frees the BLE TX pool and the firmware's SD worker)
  /// and deletes up to [maxSacrifice] unreadable files to give the
  /// full LittleFS allocation headroom, after which reads recover.
  Future<void> rescueSync({int maxSacrifice = 5}) =>
      _run(rescue: true, maxSacrifice: maxSacrifice);

  Future<void> _run({required bool rescue, int maxSacrifice = 0}) async {
    if (isSyncing.value) return;
    _cancelled = false;
    isSyncing.value = true;
    isRescue.value = rescue;
    sacrificedFiles.value = 0;
    lastError.value = null;
    progress.value = 0.0;
    transferredBytes.value = 0;
    notifyListeners();

    try {
      if (rescue) {
        _log('=== RESCUE MODE: pausing live audio ===');
        await device.pauseAudioNotifications();
        // Give the firmware a moment to drain in-flight audio TX.
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      // Stop any in-progress storage operation.
      await device.stopStorageSync();
      // 500ms settle after STOP — the firmware ignores commands sent
      // too soon (official client's "PR #5905 pattern").
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Read storage info.
      final storageInfo = await device.getStorageList();
      _log('storageInfo: $storageInfo');
      if (storageInfo.isEmpty) {
        lastError.value = 'ストレージ情報が取得できません';
        return;
      }
      totalBytesOnCard = storageInfo[0];
      final field1 = storageInfo.length > 1 ? storageInfo[1] : 0;
      notifyListeners();

      if (totalBytesOnCard < 100) {
        _log('No meaningful data ($totalBytesOnCard B)');
        return;
      }

      // A rescue only makes sense against a wedged, loaded card. On a
      // near-empty card its delete phase would pointlessly chew
      // through the current recording file over and over.
      if (rescue && totalBytesOnCard < 1024 * 1024) {
        lastError.value =
            'SDカードはほぼ空です（${totalBytesOnCard}B）。'
            'レスキューは不要です — 通常の同期だけで十分です';
        _log('rescue not needed: card nearly empty');
        return;
      }

      // CV1 firmware uses the new multi-file protocol (CMD_READ_FILE
      // 0x11, CMD_DELETE_FILE 0x12). field1 < 1000 → new firmware
      // (field1 = fileCount). field1 >= 1000 → old firmware (field1 =
      // byte offset, use legacy).
      if (field1 < 1000) {
        _log('multi-file: $field1 files, $totalBytesOnCard B');
        await _syncMultiFile(
          field1,
          rescue: rescue,
          maxSacrifice: maxSacrifice,
        );
      } else {
        _log('legacy: offset=$field1');
        await _syncLegacy(field1);
      }
    } catch (e) {
      lastError.value = e.toString();
      _log('error: $e');
    } finally {
      await _storageSub?.cancel();
      _storageSub = null;
      // Always tell the firmware to stop streaming: an aborted read
      // otherwise leaves the device pushing storage data, which can
      // interfere with live audio and the next sync.
      try {
        await device.stopStorageSync();
      } catch (_) {}
      if (rescue) {
        try {
          await device.resumeAudioNotifications();
          _log('=== RESCUE MODE: live audio resumed ===');
        } catch (e) {
          _log('audio resume failed: $e');
        }
      }
      _activityTicker?.cancel();
      _activityTicker = null;
      currentActivity.value = null;
      activityProgress.value = null;
      isSyncing.value = false;
      isRescue.value = false;
      notifyListeners();
    }
  }

  /// New multi-file protocol, built around what fw 3.0.17 actually
  /// does (verified against Omi_CV1_v3.0.17 firmware source):
  ///
  /// - CMD_LIST packs every entry into ONE notification, so it breaks
  ///   beyond ~22 files (MTU) — never rely on it for iteration.
  /// - The firmware AUTO-DELETES a file after streaming it to the END
  ///   marker (except the currently-recording file) and re-indexes the
  ///   remaining files. So: read index [base] repeatedly; when the
  ///   stats file count drops, the next file slid into [base]; when it
  ///   doesn't (empty entry / recording file), advance base.
  /// - Client-side CMD_DELETE is sent ONLY in rescue mode, and only
  ///   for the file that just failed to read (index [base]) — it is
  ///   both the space-freeing sacrifice and the blocker removal. The
  ///   normal path never deletes: after the firmware's auto-delete it
  ///   would hit a re-indexed, unsynced file.
  /// - Because the device deletes on its own, an upload failure must
  ///   not lose audio: failed uploads are spilled to the disk WAL and
  ///   recovered later via the same /sdcard/upload endpoint.
  Future<void> _syncMultiFile(
    int fileCountFromStats, {
    bool rescue = false,
    int maxSacrifice = 0,
  }) async {
    if (fileCountFromStats <= 0) {
      _log('stats report no files');
      return;
    }

    var base = 0;
    var uploaded = 0;
    var spilled = 0;
    var skipped = 0;
    var processed = 0;
    var consecutiveStalls = 0;
    // Drain-phase sacrifice budget — deliberately separate from the
    // phase-1 confirmed-delete counter (build 13 conflated them and
    // aborted a healthy drain after 6 successful uploads).
    var drainSacrifices = 0;
    var lastStallBase = -1;
    var skippedStallers = 0;

    // Rescue phase 1: free space BEFORE any read, with patience.
    // Field evidence (build 10): deletes issued right after a read
    // fail in ~30ms — the SD worker is busy for minutes (connect-time
    // flush / a previous read wedged in full-LittleFS scans) and the
    // firmware fast-fails new requests. Reads also crash the device
    // outright sometimes. So: no reads at all until deletes succeed.
    if (rescue && maxSacrifice > 0) {
      _log('RESCUE phase 1: confirmed-delete + probe strategy');
      final readsRecovered = await _rescueFreeSpace();
      if (_cancelled) return;
      if (!readsRecovered) {
        lastError.value =
            '削除を重ねても読み出しが復活しませんでした'
            '（確定削除 ${sacrificedFiles.value}件）。もう一度レスキューを'
            '実行すると続きから削除が進みます。数回試してもダメな場合は'
            'ファーム更新（SD全消去）をご検討ください';
        _log('RESCUE phase 1 failed — reads did not recover');
        return;
      }
      _log(
        'RESCUE phase 1 done: reads recovered after '
        '${sacrificedFiles.value} confirmed delete(s) — starting drain',
      );
    }

    while (processed < fileCountFromStats && !_cancelled) {
      // Re-read stats each round: the firmware re-indexes after its
      // auto-delete, and the count tells us whether [base] advanced.
      final statsBefore = await device.getStorageList();
      final countBefore = statsBefore.length > 1 ? statsBefore[1] : 0;
      if (countBefore == 0) break;
      // Never touch the newest file — it is (or may be) the file the
      // firmware is currently recording into: it streams fine but is
      // not auto-deleted, so it would be re-uploaded on every sync.
      // It syncs on a later run once a newer file exists.
      if (base >= countBefore - 1) {
        _log('reached newest (possibly recording) file — stopping');
        break;
      }

      _log('Reading file[$base] (count=$countBefore)');
      _setActivity('ファイル[$base] を読み出し中... (残り $countBefore 件)');
      final result = await _readFileWithResume(
        base,
        expectedSize: 0,
        onProgress: (_) {
          if (totalBytesOnCard > 0) {
            progress.value = (transferredBytes.value / totalBytesOnCard).clamp(
              0.0,
              0.99,
            );
          }
          notifyListeners();
        },
      );
      if (_cancelled) break;
      processed++;

      if (result.frames.isNotEmpty) {
        consecutiveStalls = 0;
        skippedStallers = 0;
        final ts = _resolveTimestampStart(0, result.epochSeconds);
        final ok = await _uploadFrames(result.frames, timestampStart: ts);
        if (ok) {
          uploaded++;
        } else if (walStore != null) {
          // The firmware may already have auto-deleted this file — the
          // phone now holds the only copy. Persist it for later upload.
          final body = encodeLengthPrefixedFrames(result.frames);
          final saved = await walStore!.writeSegment(body, ts);
          if (saved) {
            spilled++;
            _log(
              'upload failed — spilled ${result.frames.length} frames '
              'to disk WAL for later recovery',
            );
          } else {
            lastError.value = 'アップロードとWAL退避の両方に失敗しました。中断します';
            _log('upload AND wal spill failed — aborting');
            break;
          }
        } else {
          lastError.value = 'アップロードに失敗しました。中断します';
          break;
        }
      } else {
        skipped++;
        final stall = !result.endReceived && !result.deviceReportedEmpty;
        _log(
          'File[$base]: no data '
          '(end=${result.endReceived} empty=${result.deviceReportedEmpty})',
        );

        if (stall) {
          consecutiveStalls++;
          if (!rescue && consecutiveStalls >= 2) {
            // A wedged card makes every read stall for 30s+ — bailing
            // early keeps the auto-sync from grinding for an hour.
            lastError.value =
                'SDが読み出しに応答しません（満杯によるウェッジの可能性）。'
                '設定の「SDレスキュー同期」を試してください';
            _log('2 consecutive stalls — aborting auto sync');
            break;
          }
          if (rescue) {
            // First stall on this file: probably a transient worker
            // wedge — give it a minute and retry the SAME file before
            // sacrificing real data.
            if (lastStallBase != base) {
              lastStallBase = base;
              _log('stall on file[$base] — 60s cooldown then retry');
              for (var i = 0; i < 60 && !_cancelled; i++) {
                _setActivity(
                  'ワーカー回復待ち ${i}s / 60s → ファイル[$base] を再試行',
                  fraction: i / 60,
                );
                await Future<void>.delayed(const Duration(seconds: 1));
              }
              _setActivity(null);
              continue; // retry same base (stats re-read at loop top)
            }
            // Second stall on the same file: this entry is unreadable
            // (2 read attempts + in-read resume all yielded nothing).
            // Now that space is freed, deleting it rescues nothing —
            // SKIP it and keep draining. Field data (build 14) showed
            // dead entries interleaved with good files, and a
            // 5-sacrifice budget forced manual restarts every few
            // files. Only when several distinct files stall in a row
            // (suggesting a re-wedge rather than dead entries) is one
            // sacrifice spent to relieve filesystem pressure.
            consecutiveStalls = 0;
            lastStallBase = -1;
            skippedStallers++;
            if (skippedStallers % 3 == 0 && drainSacrifices < maxSacrifice) {
              drainSacrifices++;
              _log(
                'RESCUE: 3 consecutive dead entries — sacrificing '
                'file[$base] to relieve pressure '
                '($drainSacrifices/$maxSacrifice)',
              );
              try {
                final code = await device.deleteStorageFile(
                  base,
                  timeout: const Duration(seconds: 10),
                );
                _log(
                  'RESCUE: delete response '
                  '${code == null ? "timeout" : "0x${code.toRadixString(16)}"} '
                  '(ignored)',
                );
              } catch (e) {
                _log('RESCUE: delete write failed: $e');
              }
              sacrificedFiles.value = sacrificedFiles.value + 1;
              for (var i = 0; i < 45 && !_cancelled; i++) {
                _setActivity(
                  '削除の反映待ち ${i}s / 45s (ファイル[$base])',
                  fraction: i / 45,
                );
                await Future<void>.delayed(const Duration(seconds: 1));
              }
              _setActivity(null);
              // Count drop detected below decides base advancement.
            } else {
              _log(
                'RESCUE: file[$base] unreadable — skipping '
                '(kept on device, $skippedStallers skipped so far)',
              );
              // No delete: the advance rule below sees an unchanged
              // count and moves past this entry.
            }
          }
        } else {
          consecutiveStalls = 0;
        }
      }

      // Advance rule: if the firmware auto-deleted the file we just
      // drained (or the rescue delete succeeded), the count drops and
      // the next file is at [base] again. If the count is unchanged
      // (zero-size entry, error response, or the recording file),
      // move past it.
      final statsAfter = await device.getStorageList();
      final countAfter = statsAfter.length > 1 ? statsAfter[1] : 0;
      if (countAfter >= countBefore) {
        base++;
      } else {
        _log('file removed on device (count $countBefore→$countAfter)');
      }
    }

    if (!_cancelled && uploaded > 0 && lastError.value == null) {
      final statsEnd = await device.getStorageList();
      totalBytesOnCard = statsEnd.isNotEmpty ? statsEnd[0] : 0;
      progress.value = 1.0;
      notifyListeners();
    }
    if (!_cancelled &&
        uploaded == 0 &&
        spilled == 0 &&
        lastError.value == null &&
        processed > 0) {
      lastError.value =
          'ファイルは見つかりましたがデータを読み出せませんでした '
          '($processed 件試行)。詳細は虫アイコンのログ';
    }
    _log(
      'multi-file done: uploaded=$uploaded spilled=$spilled '
      'skipped=$skipped processed=$processed cancelled=$_cancelled',
    );
  }

  /// Read one file completely, resuming from the received byte offset
  /// after a stall. A single BLE hiccup mid-transfer no longer restarts
  /// an hours-long file from zero — CMD_READ_FILE takes an offset, so
  /// each retry continues where the stream stopped (the official
  /// client resumes the same way via `wal.storageOffset`).
  Future<_FileReadResult> _readFileWithResume(
    int index, {
    required int expectedSize,
    void Function(double fraction)? onProgress,
  }) async {
    final frames = <Uint8List>[];
    var offset = 0;
    int? epochSeconds;
    var endReceived = false;
    var deviceReportedEmpty = false;

    for (var attempt = 1; attempt <= _maxReadAttempts; attempt++) {
      if (_cancelled) break;
      if (attempt > 1) {
        _log(
          'File $index: resuming at offset $offset '
          '(attempt $attempt/$_maxReadAttempts)',
        );
        // Make sure the previous (stalled) read session is closed
        // before asking for the next range.
        try {
          await device.stopStorageSync();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      final r = await _readFile(
        index,
        expectedSize: expectedSize,
        startOffset: offset,
        onProgress: onProgress,
      );
      frames.addAll(r.frames);
      offset += r.audioBytes;
      epochSeconds ??= r.epochSeconds;
      deviceReportedEmpty |= r.deviceReportedEmpty;

      if (r.endReceived || _cancelled) {
        endReceived = r.endReceived;
        break;
      }
      if (r.audioBytes == 0) {
        // No progress on this attempt — retrying won't help.
        _log('File $index: no progress, giving up');
        break;
      }
    }

    final complete =
        endReceived &&
        !_cancelled &&
        (expectedSize <= 0 || offset >= expectedSize);
    _log(
      'File $index total: ${frames.length} frames, '
      '$offset/$expectedSize B, end=$endReceived, complete=$complete',
    );
    return _FileReadResult(
      frames: frames,
      complete: complete,
      endReceived: endReceived,
      deviceReportedEmpty: deviceReportedEmpty,
      audioBytes: offset,
      epochSeconds: epochSeconds,
    );
  }

  /// One read attempt using CMD_READ_FILE (0x11, fileIndex, offset).
  /// Times out only when the stream stalls: 5s for the first
  /// notification, then 30s of inactivity — a flowing transfer runs
  /// as long as it needs (2h backstop per attempt).
  Future<_FileReadResult> _readFile(
    int index, {
    required int expectedSize,
    int startOffset = 0,
    void Function(double fraction)? onProgress,
  }) async {
    final frames = <Uint8List>[];
    var audioBytes = 0;
    int? epochSeconds;
    var endReceived = false;
    var deviceReportedEmpty = false;
    String? deviceError;

    final completer = Completer<void>();
    _activeCompleter = completer;

    Timer? stallTimer;
    void armStallTimer(Duration timeout, String label) {
      stallTimer?.cancel();
      stallTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('$label (${timeout.inSeconds}s)'),
          );
        }
      });
    }

    armStallTimer(_firstDataTimeout, 'No storage data after CMD_READ_FILE');

    _storageSub = device.storageStream.listen(
      (value) {
        if (_cancelled) return;
        final n = parseSdNotification(value, SdProtocol.multiFile);
        if (n.isEcho) return;
        armStallTimer(_inactivityTimeout, 'Storage stream stalled');

        if (n.isResponse) {
          switch (n.responseCode) {
            case SdResponseCode.ok:
              return; // ack — data follows
            case SdResponseCode.endOfFile:
              endReceived = true;
              if (!completer.isCompleted) completer.complete();
            case SdResponseCode.emptyFile:
              endReceived = true;
              deviceReportedEmpty = true;
              if (!completer.isCompleted) completer.complete();
            default:
              deviceError =
                  'device response 0x${n.responseCode!.toRadixString(16)}';
              if (!completer.isCompleted) completer.complete();
          }
          return;
        }

        frames.addAll(n.frames);
        audioBytes += n.audioBytes;
        epochSeconds ??= n.epochSeconds;
        transferredBytes.value = transferredBytes.value + n.audioBytes;
        if (expectedSize > 0) {
          onProgress?.call(
            ((startOffset + audioBytes) / expectedSize).clamp(0.0, 1.0),
          );
        } else {
          // Size unknown (list fallback) — signal "bytes only".
          onProgress?.call(-1);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    void onBleState() {
      if (device.connectionState.value == OmiConnectionState.disconnected) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('BLE disconnected'));
        }
      }
    }

    device.connectionState.addListener(onBleState);

    try {
      await device.readStorageFile(index, offset: startOffset);
      await completer.future.timeout(_absoluteReadTimeout);
    } on TimeoutException catch (e) {
      _log('Read file $index stalled: ${e.message}');
    } catch (e) {
      _log('Read file $index failed: $e');
    } finally {
      stallTimer?.cancel();
      device.connectionState.removeListener(onBleState);
      await _storageSub?.cancel();
      _storageSub = null;
    }

    if (deviceError != null) {
      _log('File $index: $deviceError');
    }
    final complete =
        endReceived &&
        deviceError == null &&
        !_cancelled &&
        (expectedSize <= 0 || startOffset + audioBytes >= expectedSize);
    _log(
      'File $index attempt: ${frames.length} frames, '
      '+$audioBytes B (from $startOffset), end=$endReceived',
    );
    return _FileReadResult(
      frames: frames,
      complete: complete,
      endReceived: endReceived,
      deviceReportedEmpty: deviceReportedEmpty,
      audioBytes: audioBytes,
      epochSeconds: epochSeconds,
    );
  }

  /// Legacy single-file protocol: command 0x00 with offset.
  Future<void> _syncLegacy(int storageOffset) async {
    final frames = <Uint8List>[];
    var audioBytes = 0;
    int? epochSeconds;
    var endReceived = false;
    final expected = totalBytesOnCard - storageOffset;

    final completer = Completer<void>();
    _activeCompleter = completer;

    Timer? stallTimer;
    void armStallTimer(Duration timeout, String label) {
      stallTimer?.cancel();
      stallTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('$label (${timeout.inSeconds}s)'),
          );
        }
      });
    }

    armStallTimer(_firstDataTimeout, 'No storage data after legacy read');

    _storageSub = device.storageStream.listen(
      (value) {
        if (_cancelled) return;
        final n = parseSdNotification(value, SdProtocol.legacy);
        if (n.isEcho) return;
        armStallTimer(_inactivityTimeout, 'Storage stream stalled');

        if (n.isResponse) {
          switch (n.responseCode) {
            case SdResponseCode.ok:
              return;
            case SdResponseCode.endOfFile:
            case SdResponseCode.emptyFile:
              endReceived = true;
              if (!completer.isCompleted) completer.complete();
            default:
              _log(
                'legacy response 0x'
                '${n.responseCode!.toRadixString(16)}',
              );
              if (!completer.isCompleted) completer.complete();
          }
          return;
        }

        frames.addAll(n.frames);
        audioBytes += n.audioBytes;
        epochSeconds ??= n.epochSeconds;
        transferredBytes.value = transferredBytes.value + n.audioBytes;
        if (expected > 0) {
          progress.value = (audioBytes / expected).clamp(0.0, 0.99);
          notifyListeners();
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    void onBleState() {
      if (device.connectionState.value == OmiConnectionState.disconnected) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('BLE disconnected'));
        }
      }
    }

    device.connectionState.addListener(onBleState);

    try {
      await device.writeStorageCommand(0x00, 1, storageOffset);
      await completer.future.timeout(_absoluteReadTimeout);
    } on TimeoutException {
      lastError.value = 'SD同期が停止しました（データは削除していません）';
      return;
    } finally {
      stallTimer?.cancel();
      device.connectionState.removeListener(onBleState);
      await _storageSub?.cancel();
      _storageSub = null;
    }

    if (_cancelled) {
      lastError.value = 'Sync cancelled';
      return;
    }

    _log(
      'legacy read: ${frames.length} frames, '
      '$audioBytes/$expected B, end=$endReceived',
    );

    if (!endReceived) {
      lastError.value = '読み出しが完了しませんでした（SDはクリアしません）';
      return;
    }
    if (frames.isEmpty) {
      _log('No frames received');
      return;
    }

    final ok = await _uploadFrames(
      frames,
      timestampStart: _resolveTimestampStart(0, epochSeconds),
    );
    if (!ok) return;

    // Clear SD card only after a complete read AND successful upload.
    await device.writeStorageCommand(0x01, 1, 0);
    totalBytesOnCard = 0;
    progress.value = 1.0;
    notifyListeners();
  }

  /// Pick the recording start epoch for `X-Timestamp-Start`: prefer the
  /// file-list timestamp, then a timestamp embedded in the data stream,
  /// then fall back to the sync time.
  int _resolveTimestampStart(int listTimestamp, int? streamTimestamp) {
    if (listTimestamp >= sdMinPlausibleEpoch) return listTimestamp;
    if (streamTimestamp != null) return streamTimestamp;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  /// Upload frames via HTTP POST to /sdcard/upload.
  /// Chunks large payloads to stay under Cloudflare Tunnel limits.
  Future<bool> _uploadFrames(
    List<Uint8List> frames, {
    required int timestampStart,
  }) async {
    if (frames.isEmpty) return true;

    // Split into chunks.
    final chunks = <List<Uint8List>>[];
    var current = <Uint8List>[];
    var currentSize = 0;
    for (final f in frames) {
      final entrySize = 4 + f.length;
      if (currentSize + entrySize > _maxChunkBytes && current.isNotEmpty) {
        chunks.add(current);
        current = <Uint8List>[];
        currentSize = 0;
      }
      current.add(f);
      currentSize += entrySize;
    }
    if (current.isNotEmpty) chunks.add(current);

    _log('Uploading ${frames.length} frames in ${chunks.length} chunks');

    var framesSent = 0;
    for (var i = 0; i < chunks.length; i++) {
      if (_cancelled) return false;
      final chunk = chunks[i];
      final body = encodeLengthPrefixedFrames(chunk);
      // Each chunk starts where the previous one ended in recording time.
      final chunkTimestamp =
          timestampStart + (framesSent * _opusFrameMillis) ~/ 1000;
      _log(
        'Chunk ${i + 1}/${chunks.length}: '
        '${chunk.length} frames (${body.length} B) ts=$chunkTimestamp',
      );

      final ok = await _postChunk(body, chunkTimestamp, i + 1, chunks.length);
      if (!ok) return false;
      framesSent += chunk.length;
    }

    _log('All ${chunks.length} chunks uploaded');
    return true;
  }

  Future<bool> _postChunk(
    Uint8List body,
    int timestampStart,
    int chunkNo,
    int chunkCount,
  ) async {
    final uri = Uri.parse('$uploadUrl?token=$authToken');
    for (var attempt = 1; attempt <= _httpMaxAttempts; attempt++) {
      if (_cancelled) return false;
      try {
        final response = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/octet-stream',
                'X-Codec': 'opus',
                'X-Sample-Rate': '16000',
                'X-Channels': '1',
                'X-Frame-Format': 'length-prefixed',
                'X-Frame-Header': 'none',
                'X-Device-Id': deviceId,
                'X-Timestamp-Start': '$timestampStart',
                'Authorization': 'Bearer $authToken',
              },
              body: body,
            )
            .timeout(_httpTimeout);

        if (response.statusCode == 200) return true;

        _log('Upload error: ${response.statusCode} ${response.body}');
        if (response.statusCode >= 400 && response.statusCode < 500) {
          // Client error — retrying the same payload won't help.
          lastError.value =
              'Upload failed: HTTP ${response.statusCode} (chunk $chunkNo)';
          return false;
        }
      } catch (e) {
        _log('Upload attempt $attempt failed: $e');
      }
      if (attempt < _httpMaxAttempts) {
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
    lastError.value =
        'Upload failed after $_httpMaxAttempts attempts '
        '(chunk $chunkNo/$chunkCount)';
    return false;
  }

  @override
  void dispose() {
    _cancelled = true;
    _storageSub?.cancel();
    progress.dispose();
    isSyncing.dispose();
    lastError.dispose();
    transferredBytes.dispose();
    isRescue.dispose();
    currentActivity.dispose();
    activityProgress.dispose();
    _activityTicker?.cancel();
    sacrificedFiles.dispose();
    debugLog.dispose();
    super.dispose();
  }
}

class _FileReadResult {
  final List<Uint8List> frames;
  final bool complete;
  final bool endReceived;
  final bool deviceReportedEmpty;
  final int audioBytes;
  final int? epochSeconds;

  const _FileReadResult({
    required this.frames,
    required this.complete,
    required this.endReceived,
    required this.deviceReportedEmpty,
    required this.audioBytes,
    this.epochSeconds,
  });
}
