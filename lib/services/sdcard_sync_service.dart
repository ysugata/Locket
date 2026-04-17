import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'omi_device_service.dart';

/// Syncs OPUS audio stored on the Omi CV1's SD card to the server.
///
/// The storage BLE protocol uses three response shapes:
/// - len == 1: command response (0=OK, 4=empty, 0x64=END, other=error)
/// - len == 83: single frame [3-byte header][amount:1][frame:amount]
/// - len == 440: batch of frames, each [size:1][frame:size]
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

  /// Cancel an in-progress sync.
  void cancel() {
    _cancelled = true;
  }

  /// Sync all SD card data: read frames via BLE, upload, then clear.
  Future<void> syncAll() async {
    if (isSyncing.value) return;
    _cancelled = false;
    isSyncing.value = true;
    lastError.value = null;
    progress.value = 0.0;
    notifyListeners();

    try {
      // 1. Read storage list to determine total bytes.
      final storageInfo = await device.getStorageList();
      if (storageInfo.isEmpty) {
        lastError.value = 'Storage info not available';
        return;
      }
      totalBytesOnCard = storageInfo[0];
      notifyListeners();

      // 2. Skip if essentially empty (< 100 bytes).
      if (totalBytesOnCard < 100) {
        debugPrint('[SDSync] No meaningful data on card ($totalBytesOnCard B)');
        return;
      }

      final storageOffset = storageInfo.length > 1 ? storageInfo[1] : 0;
      final timestampStart =
          DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // 3. Accumulate frames from storage stream notifications.
      final frames = <Uint8List>[];
      int receivedBytes = 0;
      final completer = Completer<void>();

      _storageSub = device.storageStream.listen((value) {
        if (_cancelled) return;

        if (value.length == 1) {
          // Command response byte.
          final code = value[0];
          if (code == 0x64) {
            // END — all frames received.
            if (!completer.isCompleted) completer.complete();
          } else if (code == 4) {
            // Empty storage.
            if (!completer.isCompleted) completer.complete();
          } else if (code != 0) {
            // Error.
            if (!completer.isCompleted) {
              completer.completeError(
                  StateError('Storage read error: 0x${code.toRadixString(16)}'));
            }
          }
          // code == 0 means OK, continue reading.
        } else if (value.length == 83) {
          // Single frame: value[3] = amount, value[4..4+amount] = frame.
          final amount = value[3];
          if (amount > 0 && 4 + amount <= value.length) {
            final frame =
                Uint8List.fromList(value.sublist(4, 4 + amount));
            frames.add(frame);
            receivedBytes += frame.length;
            if (totalBytesOnCard > 0) {
              progress.value =
                  (receivedBytes / totalBytesOnCard).clamp(0.0, 1.0);
            }
          }
        } else if (value.length >= 2) {
          // Batch: sequence of [size:1][frame:size] entries.
          var pos = 0;
          while (pos < value.length) {
            final size = value[pos];
            pos++;
            if (size == 0 || pos + size > value.length) break;
            final frame =
                Uint8List.fromList(value.sublist(pos, pos + size));
            frames.add(frame);
            receivedBytes += frame.length;
            pos += size;
          }
          if (totalBytesOnCard > 0) {
            progress.value =
                (receivedBytes / totalBytesOnCard).clamp(0.0, 1.0);
          }
        }
      }, onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      });

      // Also abort if BLE disconnects.
      void onBleState() {
        if (device.connectionState.value == OmiConnectionState.disconnected) {
          if (!completer.isCompleted) {
            completer
                .completeError(StateError('BLE disconnected during SD sync'));
          }
        }
      }

      device.connectionState.addListener(onBleState);

      // 4. Send read command.
      await device.writeStorageCommand(0x00, 1, storageOffset);

      // 5. Wait for END or error (timeout after 5 minutes).
      try {
        await completer.future.timeout(const Duration(minutes: 5));
      } on TimeoutException {
        lastError.value = 'SD sync timed out';
        return;
      } finally {
        device.connectionState.removeListener(onBleState);
        await _storageSub?.cancel();
        _storageSub = null;
      }

      if (_cancelled) {
        // Send stop command.
        try {
          await device.writeStorageCommand(0x03, 1, 0);
        } catch (_) {}
        lastError.value = 'Sync cancelled';
        return;
      }

      if (frames.isEmpty) {
        debugPrint('[SDSync] No frames received from SD card');
        return;
      }

      // 6. Encode as length-prefixed binary.
      progress.value = 0.95;
      final body = _encodeLengthPrefixed(frames);

      // 7. HTTP POST upload.
      final uri =
          Uri.parse('$uploadUrl?token=${Uri.encodeQueryComponent(authToken)}');
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
            'Upload failed: HTTP ${response.statusCode} ${response.body}';
        return;
      }

      // 8. Clear SD card on success.
      await device.writeStorageCommand(0x01, 1, 0);
      totalBytesOnCard = 0;
      progress.value = 1.0;
      notifyListeners();
    } catch (e) {
      lastError.value = e.toString();
    } finally {
      await _storageSub?.cancel();
      _storageSub = null;
      isSyncing.value = false;
      notifyListeners();
    }
  }

  /// Encode frames as [4-byte LE length][frame] sequences.
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
