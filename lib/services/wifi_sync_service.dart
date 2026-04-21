import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ios_wifi_helper.dart';
import 'omi_device_service.dart';

/// States for the WiFi sync flow.
enum WifiSyncState {
  idle,
  settingUp,
  connecting,
  transferring,
  uploading,
  done,
  error,
}

/// Syncs OPUS audio from the Omi CV1 over WiFi (TCP) instead of BLE.
///
/// WiFi sync is ~10x faster than BLE for large SD card transfers.
/// The flow:
/// 1. Generate random SSID/password for a temporary SoftAP
/// 2. BLE: configure the device with the AP credentials
/// 3. BLE: tell the device to start the SoftAP
/// 4. Phone connects to the device's SoftAP
/// 5. Phone opens a TCP server on port 12345
/// 6. Device connects to the TCP server and streams audio data
/// 7. Upload received frames to server via HTTP POST
/// 8. Cleanup: stop the AP, restore phone WiFi
class WifiSyncService extends ChangeNotifier {
  final OmiDeviceService device;
  final String uploadUrl;
  final String authToken;
  final String deviceId;

  static const int _tcpPort = 12345;
  static const Duration _apStartDelay = Duration(seconds: 8);
  static const Duration _tcpAcceptTimeout = Duration(seconds: 60);
  static const int _maxChunkBytes = 500 * 1024;

  final ValueNotifier<WifiSyncState> state = ValueNotifier(WifiSyncState.idle);
  final ValueNotifier<double> progress = ValueNotifier(0.0);
  final ValueNotifier<double> speedKBps = ValueNotifier(0.0);
  final ValueNotifier<String?> error = ValueNotifier(null);

  bool _cancelled = false;
  ServerSocket? _server;
  String? _activeSsid;

  WifiSyncService({
    required this.device,
    required this.uploadUrl,
    required this.authToken,
    required this.deviceId,
  });

  /// Whether WiFi sync is available (device has the WiFi characteristic).
  bool get isAvailable => device.hasWifiCharacteristic;

  /// Whether a sync is currently in progress.
  bool get isSyncing {
    final s = state.value;
    return s != WifiSyncState.idle &&
        s != WifiSyncState.done &&
        s != WifiSyncState.error;
  }

  /// Cancel an in-progress WiFi sync.
  Future<void> cancel() async {
    _cancelled = true;
    await _cleanup();
    state.value = WifiSyncState.idle;
    notifyListeners();
  }

  /// Run the full WiFi sync flow.
  Future<void> sync() async {
    if (isSyncing) return;
    _cancelled = false;
    error.value = null;
    progress.value = 0.0;
    speedKBps.value = 0.0;
    notifyListeners();

    final ssid = _generateSsid();
    final password = _generatePassword();
    _activeSsid = ssid;

    try {
      // Step 1: Setup WiFi AP credentials on device via BLE.
      state.value = WifiSyncState.settingUp;
      notifyListeners();
      debugPrint('[WiFiSync] Setting up AP: $ssid');

      final setupOk = await device.setupWifiSync(ssid, password);
      if (_cancelled) return;
      if (!setupOk) {
        _setError('Device rejected WiFi AP setup');
        return;
      }

      // Step 2: Start WiFi AP on device.
      final startOk = await device.startWifiSync();
      if (_cancelled) return;
      if (!startOk) {
        _setError('Device failed to start WiFi AP');
        return;
      }

      // Step 3: Wait for device AP to come up.
      debugPrint('[WiFiSync] Waiting ${_apStartDelay.inSeconds}s for AP...');
      await Future<void>.delayed(_apStartDelay);
      if (_cancelled) return;

      // Step 4: Connect phone to device SoftAP.
      state.value = WifiSyncState.connecting;
      notifyListeners();
      debugPrint('[WiFiSync] Connecting phone to AP: $ssid');

      final connected = await IOSWifiHelper.connectToAp(ssid, password);
      if (_cancelled) return;
      if (!connected) {
        _setError('Failed to connect to device WiFi AP');
        return;
      }

      // Step 5: Start TCP server and wait for device to connect.
      state.value = WifiSyncState.transferring;
      notifyListeners();
      debugPrint('[WiFiSync] Starting TCP server on port $_tcpPort');

      final frames = await _receiveTcpData();
      if (_cancelled) return;

      if (frames.isEmpty) {
        debugPrint('[WiFiSync] No frames received');
        state.value = WifiSyncState.done;
        notifyListeners();
        await _cleanup();
        return;
      }

      // Step 6: Upload frames.
      state.value = WifiSyncState.uploading;
      progress.value = 0.9;
      notifyListeners();
      debugPrint('[WiFiSync] Uploading ${frames.length} frames');

      final ok = await _uploadFrames(frames);
      if (!ok) {
        _setError('Upload failed');
        return;
      }

      // Done.
      progress.value = 1.0;
      state.value = WifiSyncState.done;
      notifyListeners();
      debugPrint('[WiFiSync] Sync complete: ${frames.length} frames');
    } catch (e) {
      _setError(e.toString());
    } finally {
      await _cleanup();
    }
  }

  /// Receive audio data from the device over TCP.
  Future<List<Uint8List>> _receiveTcpData() async {
    final frames = <Uint8List>[];
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _tcpPort);
    } catch (e) {
      throw StateError('Failed to bind TCP port $_tcpPort: $e');
    }

    try {
      debugPrint('[WiFiSync] Waiting for device TCP connection...');
      final client = await _server!.first.timeout(_tcpAcceptTimeout);
      debugPrint('[WiFiSync] Device connected from ${client.remoteAddress}');

      final buffer = <int>[];
      int totalBytes = 0;
      final startTime = DateTime.now();

      final completer = Completer<void>();

      client.listen(
        (data) {
          if (_cancelled) return;
          buffer.addAll(data);
          totalBytes += data.length;

          // Parse frames: [size:1][frame:size]...
          while (buffer.isNotEmpty) {
            final size = buffer[0];
            if (size == 0) {
              // Zero-size marker means end of stream.
              buffer.removeAt(0);
              break;
            }
            if (buffer.length < 1 + size) break;
            frames.add(Uint8List.fromList(buffer.sublist(1, 1 + size)));
            buffer.removeRange(0, 1 + size);
          }

          // Update progress/speed.
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          if (elapsed > 0) {
            speedKBps.value = (totalBytes / 1024) / (elapsed / 1000);
          }
          // Use 0.0-0.8 range for transfer, 0.8-0.9 for upload prep.
          progress.value = (totalBytes / max(totalBytes + 1024, 1)).clamp(
            0.0,
            0.8,
          );
          notifyListeners();
        },
        onDone: () {
          debugPrint(
            '[WiFiSync] TCP stream done: $totalBytes bytes, '
            '${frames.length} frames',
          );
          if (!completer.isCompleted) completer.complete();
        },
        onError: (Object e) {
          debugPrint('[WiFiSync] TCP error: $e');
          if (!completer.isCompleted) completer.completeError(e);
        },
      );

      // Wait for transfer to complete or timeout after 5 minutes.
      await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          debugPrint('[WiFiSync] TCP transfer timeout');
        },
      );
    } on TimeoutException {
      debugPrint('[WiFiSync] No device connected within timeout');
    } finally {
      await _server?.close();
      _server = null;
    }

    return frames;
  }

  /// Upload frames via HTTP POST, same format as SD card sync.
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
      '[WiFiSync] Uploading ${frames.length} frames '
      'in ${chunks.length} chunks',
    );

    for (var i = 0; i < chunks.length; i++) {
      if (_cancelled) return false;
      final chunk = chunks[i];
      final body = _encodeLengthPrefixed(chunk);

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
          'X-Sync-Method': 'wifi',
          'Authorization': 'Bearer $authToken',
        },
        body: body,
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[WiFiSync] Upload error: ${response.statusCode} ${response.body}',
        );
        return false;
      }
    }

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

  /// Cleanup: stop WiFi AP, disconnect from SoftAP, close TCP server.
  Future<void> _cleanup() async {
    await _server?.close();
    _server = null;

    // Stop device WiFi AP via BLE (best-effort).
    try {
      await device.stopWifiSync();
    } catch (_) {}

    // Disconnect phone from the SoftAP.
    final ssid = _activeSsid;
    if (ssid != null) {
      try {
        await IOSWifiHelper.disconnectFromAp(ssid);
      } catch (_) {}
      _activeSsid = null;
    }
  }

  void _setError(String msg) {
    debugPrint('[WiFiSync] Error: $msg');
    error.value = msg;
    state.value = WifiSyncState.error;
    notifyListeners();
  }

  /// Generate a random SSID like "Omi_A1B2".
  static String _generateSsid() {
    final rnd = Random.secure();
    final hex = List.generate(
      4,
      (_) => rnd.nextInt(16).toRadixString(16).toUpperCase(),
    ).join();
    return 'Omi_$hex';
  }

  /// Generate a random 8-character alphanumeric password.
  static String _generatePassword() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(8, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  @override
  void dispose() {
    _cancelled = true;
    _server?.close();
    state.dispose();
    progress.dispose();
    speedKBps.dispose();
    error.dispose();
    super.dispose();
  }
}
