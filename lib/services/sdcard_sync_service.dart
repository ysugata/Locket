import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'omi_device_service.dart';

/// Syncs OPUS audio stored on the Omi CV1's SD card to the server.
///
/// Supports both legacy (single-file) and new multi-file protocols.
/// The protocol is auto-detected from storageInfo: if field[1] < 1000,
/// it's the new multi-file protocol (field[1] = fileCount); if >= 1000,
/// it's the legacy protocol (field[1] = byte offset).
///
/// New multi-file protocol commands:
///   0x10 = CMD_LIST_FILES
///   0x11 = CMD_READ_FILE(fileIndex)
///   0x12 = CMD_DELETE_FILE(fileIndex)
///   0x03 = CMD_STOP
///
/// Data notification shapes:
///   len == 1: command response (0=OK, 4=empty, 0x64=END)
///   len == 83: single frame [header:3][amount:1][frame:amount]
///   len >= 2 (other): batch of [size:1][frame:size]...
class SDCardSyncService extends ChangeNotifier {
  final OmiDeviceService device;
  final String uploadUrl;
  final String authToken;
  final String deviceId;

  final ValueNotifier<double> progress = ValueNotifier(0.0);
  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  int totalBytesOnCard = 0;

  StreamSubscription<List<int>>? _storageSub;
  bool _cancelled = false;

  SDCardSyncService({
    required this.device,
    required this.uploadUrl,
    required this.authToken,
    required this.deviceId,
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
    notifyListeners();

    try {
      // Stop any in-progress storage operation.
      await device.stopStorageSync();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Read storage info.
      final storageInfo = await device.getStorageList();
      debugPrint('[SDSync] storageInfo: $storageInfo');
      if (storageInfo.isEmpty) {
        lastError.value = 'ストレージ情報が取得できません';
        return;
      }
      totalBytesOnCard = storageInfo[0];
      final field1 = storageInfo.length > 1 ? storageInfo[1] : 0;
      notifyListeners();

      if (totalBytesOnCard < 100) {
        debugPrint('[SDSync] No meaningful data ($totalBytesOnCard B)');
        return;
      }

      // CV1 firmware uses the new multi-file protocol (CMD_READ_FILE
      // 0x11, CMD_DELETE_FILE 0x12). Legacy command 0x00 returns 0x06.
      // field1 < 1000 → new firmware (field1 = fileCount).
      // field1 >= 1000 → old firmware (field1 = byte offset, use legacy).
      if (field1 < 1000) {
        debugPrint('[SDSync] multi-file: $field1 files, $totalBytesOnCard B');
        await _syncMultiFile(field1);
      } else {
        debugPrint('[SDSync] legacy: offset=$field1');
        await _syncLegacy(field1);
      }
    } catch (e) {
      lastError.value = e.toString();
      debugPrint('[SDSync] error: $e');
    } finally {
      await _storageSub?.cancel();
      _storageSub = null;
      // (audio notifications are left running during SD sync)
      isSyncing.value = false;
      notifyListeners();
    }
  }

  /// New multi-file protocol: list files, read each non-empty file,
  /// upload, then delete.
  Future<void> _syncMultiFile(int fileCount) async {
    if (fileCount == 0) {
      debugPrint('[SDSync] No files to sync');
      return;
    }

    // Get actual file list with sizes.
    final files = await device.listStorageFiles();
    debugPrint('[SDSync] listStorageFiles: ${files.length} files');
    for (final f in files) {
      debugPrint('[SDSync]   index=${f['index']} ts=${f['timestamp']} size=${f['size']}');
    }

    if (files.isEmpty) {
      debugPrint('[SDSync] No files returned by CMD_LIST_FILES');
      return;
    }

    // Filter to non-empty files only and recalculate total.
    final nonEmpty = files.where((f) => (f['size'] ?? 0) > 0).toList();
    int actualTotal = 0;
    for (final f in nonEmpty) {
      actualTotal += f['size'] ?? 0;
    }
    totalBytesOnCard = actualTotal;
    debugPrint('[SDSync] ${nonEmpty.length} non-empty files, $actualTotal B');

    int filesProcessed = 0;
    final totalFiles = nonEmpty.length;
    for (final file in nonEmpty) {
      if (_cancelled) break;
      final idx = file['index'] ?? 0;
      final size = file['size'] ?? 0;
      debugPrint('[SDSync] Reading file $idx (${size}B)');
      // File-based progress: each file is an equal slice.
      progress.value = (filesProcessed / totalFiles).clamp(0.0, 0.99);
      notifyListeners();

      final frames = await _readFile(idx);
      if (_cancelled) break;
      if (frames.isEmpty) {
        debugPrint('[SDSync] File $idx: 0 frames, skipping');
        continue;
      }

      final ok = await _uploadFrames(frames);
      if (!ok) return;

      // Delete file from device after successful upload.
      try {
        await device.deleteStorageFile(idx);
        debugPrint('[SDSync] Deleted file $idx');
      } catch (e) {
        debugPrint('[SDSync] Delete file $idx failed: $e');
      }
      filesProcessed++;
      progress.value = (filesProcessed / totalFiles).clamp(0.0, 0.99);
      notifyListeners();
    }

    totalBytesOnCard = 0;
    progress.value = 1.0;
    notifyListeners();
    debugPrint('[SDSync] multi-file complete: $filesProcessed files');
  }

  /// Read one file using CMD_READ_FILE (0x11, fileIndex, offset=0).
  Future<List<Uint8List>> _readFile(int index) async {
    final frames = <Uint8List>[];
    final completer = Completer<void>();
    _activeCompleter = completer;

    _storageSub = device.storageStream.listen((value) {
      if (_cancelled) return;
      _parseNotification(value, frames, completer);
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    void onBleState() {
      if (device.connectionState.value == OmiConnectionState.disconnected) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('BLE disconnected'));
        }
      }
    }

    device.connectionState.addListener(onBleState);

    try {
      await device.readStorageFile(index, offset: 0);
      await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      debugPrint('[SDSync] Read file $index timed out');
    } finally {
      device.connectionState.removeListener(onBleState);
      await _storageSub?.cancel();
      _storageSub = null;
    }

    debugPrint('[SDSync] File $index: ${frames.length} frames');
    return frames;
  }

  /// Legacy single-file protocol: command 0x00 with offset.
  Future<void> _syncLegacy(int storageOffset) async {
    debugPrint('[SDSync] legacy: offset=$storageOffset');
    final frames = <Uint8List>[];
    final completer = Completer<void>();

    _storageSub = device.storageStream.listen((value) {
      if (_cancelled) return;
      _parseNotification(value, frames, completer);
      if (totalBytesOnCard > 0) {
        int receivedBytes = 0;
        for (final f in frames) {
          receivedBytes += f.length;
        }
        progress.value =
            (receivedBytes / totalBytesOnCard).clamp(0.0, 1.0);
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

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
      await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      lastError.value = 'SD sync timed out';
      return;
    } finally {
      device.connectionState.removeListener(onBleState);
      await _storageSub?.cancel();
      _storageSub = null;
    }

    if (_cancelled) {
      try {
        await device.stopStorageSync();
      } catch (_) {}
      lastError.value = 'Sync cancelled';
      return;
    }

    if (frames.isEmpty) {
      debugPrint('[SDSync] No frames received');
      return;
    }

    final ok = await _uploadFrames(frames);
    if (!ok) return;

    // Clear SD card on success.
    await device.writeStorageCommand(0x01, 1, 0);
    totalBytesOnCard = 0;
    progress.value = 1.0;
    notifyListeners();
  }

  /// Parse a BLE notification and extract OPUS frames.
  ///
  /// New multi-file protocol notifications have a 4-byte BE timestamp
  /// prefix followed by a batch of [size:1][frame:size]... entries.
  /// Typical notification size is 444 bytes (4 ts + 440 batch).
  ///
  /// 1-byte notifications are command responses (0=OK, 4=empty, 0x64=END).
  /// 6-byte notifications matching our write echo are ignored.
  void _parseNotification(
      List<int> value, List<Uint8List> frames, Completer<void> completer) {
    if (value.length == 1) {
      final code = value[0];
      if (code == 0x64) {
        // END
        debugPrint('[SDSync] END received');
        if (!completer.isCompleted) completer.complete();
      } else if (code == 4) {
        // Empty
        debugPrint('[SDSync] Empty file');
        if (!completer.isCompleted) completer.complete();
      } else if (code != 0) {
        debugPrint(
            '[SDSync] response code: 0x${code.toRadixString(16)}');
        if (!completer.isCompleted) completer.complete();
      }
      return;
    }

    // Skip write echoes (our own CMD_READ_FILE echoed back).
    if (value.length == 6 && value[0] == 0x11) return;

    // New protocol: [timestamp:4 BE][batch of [size:1][frame:size]...]
    if (value.length > 4) {
      // Skip 4-byte timestamp prefix.
      var pos = 4;
      while (pos < value.length) {
        final size = value[pos];
        pos++;
        if (size == 0 || pos + size > value.length) break;
        frames.add(Uint8List.fromList(value.sublist(pos, pos + size)));
        pos += size;
      }
    }
  }

  /// Upload frames via HTTP POST to /sdcard/upload.
  /// Chunks large payloads to stay under Cloudflare Tunnel limits.
  static const int _maxChunkBytes = 500 * 1024;

  Future<bool> _uploadFrames(List<Uint8List> frames) async {
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

    debugPrint(
        '[SDSync] Uploading ${frames.length} frames in ${chunks.length} chunks');

    for (var i = 0; i < chunks.length; i++) {
      if (_cancelled) return false;
      final chunk = chunks[i];
      final body = _encodeLengthPrefixed(chunk);
      debugPrint('[SDSync] Chunk ${i + 1}/${chunks.length}: '
          '${chunk.length} frames (${body.length} B)');

      final timestampStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final uri = Uri.parse('$uploadUrl?token=$authToken');
      final response = await http.post(
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
      );

      if (response.statusCode != 200) {
        lastError.value =
            'Upload failed: HTTP ${response.statusCode} (chunk ${i + 1})';
        debugPrint(
            '[SDSync] Upload error: ${response.statusCode} ${response.body}');
        return false;
      }
    }

    debugPrint('[SDSync] All ${chunks.length} chunks uploaded');
    return true;
  }

  Uint8List _encodeLengthPrefixed(List<Uint8List> frames) {
    var totalSize = 0;
    for (final f in frames) {
      totalSize += 4 + f.length;
    }
    final result = Uint8List(totalSize);
    var offset = 0;
    for (final f in frames) {
      final len = f.length;
      result[offset] = len & 0xFF;
      result[offset + 1] = (len >> 8) & 0xFF;
      result[offset + 2] = (len >> 16) & 0xFF;
      result[offset + 3] = (len >> 24) & 0xFF;
      result.setRange(offset + 4, offset + 4 + len, f);
      offset += 4 + len;
    }
    return result;
  }


  @override
  void dispose() {
    _cancelled = true;
    _storageSub?.cancel();
    progress.dispose();
    isSyncing.dispose();
    lastError.dispose();
    super.dispose();
  }
}
