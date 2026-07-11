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
  }

  Future<void> syncAll() async {
    if (isSyncing.value) return;
    _cancelled = false;
    isSyncing.value = true;
    lastError.value = null;
    progress.value = 0.0;
    transferredBytes.value = 0;
    notifyListeners();

    try {
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

      // CV1 firmware uses the new multi-file protocol (CMD_READ_FILE
      // 0x11, CMD_DELETE_FILE 0x12). field1 < 1000 → new firmware
      // (field1 = fileCount). field1 >= 1000 → old firmware (field1 =
      // byte offset, use legacy).
      if (field1 < 1000) {
        _log('multi-file: $field1 files, $totalBytesOnCard B');
        await _syncMultiFile(field1);
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
      isSyncing.value = false;
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
  /// - Client-side CMD_DELETE is never sent — after the firmware's
  ///   auto-delete it would hit a re-indexed, unsynced file.
  /// - Because the device deletes on its own, an upload failure must
  ///   not lose audio: failed uploads are spilled to the disk WAL and
  ///   recovered later via the same /sdcard/upload endpoint.
  Future<void> _syncMultiFile(int fileCountFromStats) async {
    if (fileCountFromStats <= 0) {
      _log('stats report no files');
      return;
    }

    var base = 0;
    var uploaded = 0;
    var spilled = 0;
    var skipped = 0;
    var processed = 0;

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
        _log(
          'File[$base]: no data '
          '(end=${result.endReceived} empty=${result.deviceReportedEmpty})',
        );
      }

      // Advance rule: if the firmware auto-deleted the file we just
      // drained, the count drops and the next file is at [base] again.
      // If the count is unchanged (zero-size entry, error response, or
      // the recording file), move past it.
      final statsAfter = await device.getStorageList();
      final countAfter = statsAfter.length > 1 ? statsAfter[1] : 0;
      if (countAfter >= countBefore) {
        base++;
      } else {
        _log('firmware auto-deleted file (count $countBefore→$countAfter)');
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
