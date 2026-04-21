import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/omi_discovered_device.dart';

// Omi BLE UUIDs
final _audioServiceGuid = Guid('19b10000-e8f2-537e-4f6c-d104768a1214');
final _audioDataCharGuid = Guid('19b10001-e8f2-537e-4f6c-d104768a1214');
final _codecTypeCharGuid = Guid('19b10002-e8f2-537e-4f6c-d104768a1214');

// Omi Storage Service UUIDs
final _storageServiceGuid = Guid('30295780-4301-eabd-2904-2849adfeae43');
final _storageDataCharGuid = Guid('30295781-4301-eabd-2904-2849adfeae43');
final _storageReadCtrlCharGuid = Guid('30295782-4301-eabd-2904-2849adfeae43');
final _storageWifiCharGuid = Guid('30295783-4301-eabd-2904-2849adfeae43');

// SMP (Simple Management Protocol) service for MCUmgr DFU
final _smpServiceGuid = Guid('8d53dc1d-1db7-4cd3-868b-8a527460aa84');

// Standard BLE UUIDs (full 128-bit form, Bluetooth base UUID)
final _batteryServiceGuid = Guid('0000180f-0000-1000-8000-00805f9b34fb');
final _batteryLevelCharGuid = Guid('00002a19-0000-1000-8000-00805f9b34fb');
final _deviceInfoServiceGuid = Guid('0000180a-0000-1000-8000-00805f9b34fb');
final _firmwareRevisionCharGuid = Guid('00002a26-0000-1000-8000-00805f9b34fb');

/// OPUS codec identifier per Omi spec.
const int omiCodecOpus = 20;

enum OmiConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  reconnecting,
}

/// BLE connection and audio streaming service for Omi CV1.
///
/// Audio bytes are emitted raw from the BLE notify characteristic:
/// they still carry Omi's 3-byte `[packet_no:2][fragment_idx:1]` header
/// followed by the OPUS-encoded payload. Decoding and reassembly are
/// the server's responsibility — this service is a pass-through.
class OmiDeviceService extends ChangeNotifier {
  static const _scanTimeout = Duration(seconds: 10);
  static const _connectTimeout = Duration(seconds: 15);
  static const _reconnectDelay = Duration(seconds: 15);
  static const _maxReconnectAttempts = 10;

  final _audioStreamController = StreamController<Uint8List>.broadcast();
  final _storageStreamController = StreamController<List<int>>.broadcast();
  final _wifiStreamController = StreamController<List<int>>.broadcast();

  /// Raw BLE notifications from the Omi audio data characteristic.
  /// Bytes include the 3-byte Omi packet header — do not strip.
  Stream<Uint8List> get audioStream => _audioStreamController.stream;

  /// Notifications from the Omi storage data characteristic (30295781).
  Stream<List<int>> get storageStream => _storageStreamController.stream;

  /// Notifications from the WiFi control characteristic (30295783).
  Stream<List<int>> get wifiStream => _wifiStreamController.stream;

  final ValueNotifier<OmiConnectionState> connectionState = ValueNotifier(
    OmiConnectionState.disconnected,
  );
  final ValueNotifier<int> batteryLevel = ValueNotifier<int>(-1);
  final ValueNotifier<int> codecId = ValueNotifier<int>(-1);
  final ValueNotifier<String> firmwareVersion = ValueNotifier<String>('');
  final ValueNotifier<bool> hasSmpService = ValueNotifier<bool>(false);

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _storageSub;
  StreamSubscription<List<int>>? _wifiSub;
  StreamSubscription<List<int>>? _batterySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  BluetoothCharacteristic? _storageDataChar;
  BluetoothCharacteristic? _storageReadCtrlChar;
  BluetoothCharacteristic? _wifiChar;

  bool _autoReconnect = true;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  bool _disposed = false;

  Future<bool> _requestPermissions() async {
    // iOS: permission_handler's Permission.bluetooth is unreliable on
    // iOS 13+ — the actual system prompt is triggered by Core Bluetooth
    // itself when scanning starts, keyed on NSBluetoothAlwaysUsageDescription
    // in Info.plist. Let flutter_blue_plus handle it natively.
    if (Platform.isAndroid) {
      final results = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      return results.values.every(
        (s) => s.isGranted || s.isLimited || s.isRestricted,
      );
    }
    return true;
  }

  Future<List<OmiDiscoveredDevice>> scanForDevices({
    Duration timeout = _scanTimeout,
  }) async {
    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      throw StateError('このデバイスは BLE をサポートしていません');
    }
    final granted = await _requestPermissions();
    if (!granted) {
      throw StateError('BLE の権限が許可されていません');
    }

    // Read adapter state. On iOS this also forces the CBCentralManager
    // to initialize, which triggers the system permission prompt the
    // first time the app runs. After that, a non-`on` state is mapped
    // to a user-friendly Japanese message.
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
    switch (state) {
      case BluetoothAdapterState.unauthorized:
        throw StateError('Bluetooth の使用が許可されていません。設定アプリで許可してください');
      case BluetoothAdapterState.off:
        throw StateError('Bluetooth がオフになっています。オンにしてください');
      case BluetoothAdapterState.unavailable:
        throw StateError('この端末では Bluetooth が利用できません');
      case BluetoothAdapterState.on:
      case BluetoothAdapterState.turningOn:
      case BluetoothAdapterState.turningOff:
      case BluetoothAdapterState.unknown:
        break;
    }

    connectionState.value = OmiConnectionState.scanning;
    notifyListeners();

    final discovered = <String, OmiDiscoveredDevice>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final id = r.device.remoteId.str;
        final name = r.device.advName.isNotEmpty
            ? r.device.advName
            : (r.device.platformName.isNotEmpty
                  ? r.device.platformName
                  : 'Unknown');
        discovered[id] = OmiDiscoveredDevice(id: id, name: name, rssi: r.rssi);
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [_audioServiceGuid],
        timeout: timeout,
      );
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } finally {
      await sub.cancel();
      if (connectionState.value == OmiConnectionState.scanning) {
        connectionState.value = OmiConnectionState.disconnected;
        notifyListeners();
      }
    }
    return discovered.values.toList();
  }

  Future<void> connect(String deviceId) async {
    connectionState.value = OmiConnectionState.connecting;
    notifyListeners();

    final device = BluetoothDevice.fromId(deviceId);
    _device = device;
    _autoReconnect = true;

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _handleDisconnection();
      }
    });

    try {
      await device.connect(
        license: License.free,
        timeout: _connectTimeout,
        mtu: null,
      );
      try {
        await device.requestMtu(247);
      } catch (_) {
        // iOS negotiates MTU automatically; ignore errors there.
      }
      await _discoverAndSubscribe(device);
      connectionState.value = OmiConnectionState.connected;
      _reconnectAttempts = 0;
      notifyListeners();
    } catch (e) {
      connectionState.value = OmiConnectionState.disconnected;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    final services = await device.discoverServices();
    // Detect SMP service for MCUmgr DFU support.
    hasSmpService.value = services.any((s) => s.uuid == _smpServiceGuid);
    debugPrint('[BLE] SMP service present: ${hasSmpService.value}');
    for (final service in services) {
      if (service.uuid == _audioServiceGuid) {
        for (final ch in service.characteristics) {
          if (ch.uuid == _audioDataCharGuid) {
            _audioDataChar = ch;
            await ch.setNotifyValue(true);
            await _audioSub?.cancel();
            _audioSub = ch.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                _audioStreamController.add(Uint8List.fromList(value));
              }
            });
          } else if (ch.uuid == _codecTypeCharGuid) {
            final value = await ch.read();
            if (value.isNotEmpty) {
              codecId.value = value.first;
            }
          }
        }
      } else if (service.uuid == _batteryServiceGuid) {
        for (final ch in service.characteristics) {
          if (ch.uuid == _batteryLevelCharGuid) {
            try {
              final initial = await ch.read();
              if (initial.isNotEmpty) {
                batteryLevel.value = initial.first;
              }
            } catch (_) {
              // read may fail before notifications are enabled; ignore.
            }
            await ch.setNotifyValue(true);
            await _batterySub?.cancel();
            _batterySub = ch.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                batteryLevel.value = value.first;
              }
            });
          }
        }
      } else if (service.uuid == _deviceInfoServiceGuid) {
        for (final ch in service.characteristics) {
          if (ch.uuid == _firmwareRevisionCharGuid) {
            try {
              final value = await ch.read();
              firmwareVersion.value = String.fromCharCodes(value).trim();
            } catch (_) {
              // ignore read errors on optional characteristic
            }
          }
        }
      } else if (service.uuid == _storageServiceGuid) {
        for (final ch in service.characteristics) {
          if (ch.uuid == _storageDataCharGuid) {
            _storageDataChar = ch;
            await ch.setNotifyValue(true);
            await _storageSub?.cancel();
            _storageSub = ch.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                debugPrint('[BLE] storage raw notify len=${value.length}');
                _storageStreamController.add(value);
              }
            });
          } else if (ch.uuid == _storageReadCtrlCharGuid) {
            _storageReadCtrlChar = ch;
          } else if (ch.uuid == _storageWifiCharGuid) {
            _wifiChar = ch;
            await ch.setNotifyValue(true);
            await _wifiSub?.cancel();
            _wifiSub = ch.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                debugPrint('[BLE] wifi char notify len=${value.length}');
                _wifiStreamController.add(value);
              }
            });
            debugPrint('[BLE] WiFi characteristic discovered');
          }
        }
      }
    }
  }

  /// Read storage file list. Returns LE uint32 values from the read
  /// control characteristic (30295782), typically [totalBytes, offset].
  Future<List<int>> getStorageList() async {
    final ch = _storageReadCtrlChar;
    if (ch == null) return [];
    final raw = await ch.read();
    if (raw.length < 4) return [];
    final result = <int>[];
    for (var i = 0; i + 3 < raw.length; i += 4) {
      result.add(
        raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16) | (raw[i + 3] << 24),
      );
    }
    return result;
  }

  /// Write a legacy storage command to the data characteristic.
  /// [command]: 0x00 = start read, 0x01 = clear, 0x03 = stop.
  Future<void> writeStorageCommand(int command, int fileNum, int offset) async {
    final ch = _storageDataChar;
    if (ch == null) {
      throw StateError('Storage data characteristic not available');
    }
    final bytes = Uint8List(6);
    bytes[0] = command & 0xFF;
    bytes[1] = fileNum & 0xFF;
    bytes[2] = (offset >> 24) & 0xFF;
    bytes[3] = (offset >> 16) & 0xFF;
    bytes[4] = (offset >> 8) & 0xFF;
    bytes[5] = offset & 0xFF;
    await ch.write(bytes);
  }

  /// Send CMD_LIST_FILES (0x10) and return the file list.
  /// Response: [count:1][ts:4 BE][size:4 BE]... per file.
  Future<List<Map<String, int>>> listStorageFiles() async {
    final ch = _storageDataChar;
    if (ch == null) return [];

    final completer = Completer<List<Map<String, int>>>();
    StreamSubscription<List<int>>? sub;

    sub = storageStream.listen((value) {
      if (completer.isCompleted) return;
      if (value.isEmpty) return;

      final count = value[0];
      if (count == 0 && value.length == 1) {
        completer.complete([]);
        return;
      }

      final expectedLen = 1 + count * 8;
      if (value.length >= expectedLen && count > 0 && count <= 128) {
        final files = <Map<String, int>>[];
        for (var i = 0; i < count; i++) {
          final base = 1 + i * 8;
          if (base + 8 > value.length) break;
          final ts =
              (value[base] << 24) |
              (value[base + 1] << 16) |
              (value[base + 2] << 8) |
              value[base + 3];
          final size =
              (value[base + 4] << 24) |
              (value[base + 5] << 16) |
              (value[base + 6] << 8) |
              value[base + 7];
          files.add({'index': i, 'timestamp': ts, 'size': size});
        }
        debugPrint('[BLE] Listed ${files.length} storage files');
        completer.complete(files);
      }
    });

    try {
      await ch.write([0x10]);
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[BLE] listStorageFiles timeout');
          return <Map<String, int>>[];
        },
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Send CMD_STOP (0x03) to abort any in-progress storage operation.
  Future<void> stopStorageSync() async {
    final ch = _storageDataChar;
    if (ch == null) return;
    await ch.write([0x03]);
  }

  BluetoothCharacteristic? _audioDataChar;

  /// Pause audio notifications so the device can serve storage reads.
  /// CV1 can't do both simultaneously (returns 0x06 if audio is active).
  Future<void> pauseAudioNotifications() async {
    if (_audioDataChar != null) {
      await _audioSub?.cancel();
      _audioSub = null;
      try {
        await _audioDataChar!.setNotifyValue(false);
      } catch (_) {}
      debugPrint('[BLE] Audio notifications paused');
    }
  }

  /// Resume audio notifications after storage sync is done.
  Future<void> resumeAudioNotifications() async {
    if (_audioDataChar != null) {
      try {
        await _audioDataChar!.setNotifyValue(true);
        _audioSub = _audioDataChar!.lastValueStream.listen((value) {
          if (value.isNotEmpty) {
            _audioStreamController.add(Uint8List.fromList(value));
          }
        });
      } catch (_) {}
      debugPrint('[BLE] Audio notifications resumed');
    }
  }

  /// Send CMD_READ_FILE (0x11) — new multi-file protocol.
  /// Format: [0x11, file_index, offset(4 bytes BE)].
  /// Data frames arrive on [storageStream]. Listen before calling.
  Future<void> readStorageFile(int fileIndex, {int offset = 0}) async {
    final ch = _storageDataChar;
    if (ch == null) {
      throw StateError('Storage data characteristic not available');
    }
    final cmd = [
      0x11,
      fileIndex & 0xFF,
      (offset >> 24) & 0xFF,
      (offset >> 16) & 0xFF,
      (offset >> 8) & 0xFF,
      offset & 0xFF,
    ];
    debugPrint('[BLE] Writing CMD_READ_FILE: $cmd');
    try {
      await ch.write(cmd);
      debugPrint('[BLE] CMD_READ_FILE write OK');
    } catch (e) {
      debugPrint('[BLE] CMD_READ_FILE write FAILED: $e');
      rethrow;
    }
  }

  /// Send CMD_DELETE_FILE (0x12, fileIndex) — new multi-file protocol.
  /// Waits for a single-byte response (0x00 = success) with 5s timeout.
  Future<bool> deleteStorageFile(int fileIndex) async {
    final ch = _storageDataChar;
    if (ch == null) {
      throw StateError('Storage data characteristic not available');
    }

    final completer = Completer<bool>();
    StreamSubscription<List<int>>? sub;
    Timer? timeout;

    sub = storageStream.listen((value) {
      if (value.length == 1) {
        sub?.cancel();
        timeout?.cancel();
        completer.complete(value[0] == 0x00);
      }
    });

    timeout = Timer(const Duration(seconds: 5), () {
      sub?.cancel();
      if (!completer.isCompleted) {
        debugPrint('[BLE] CMD_DELETE_FILE timeout for index $fileIndex');
        completer.complete(false);
      }
    });

    await ch.write([0x12, fileIndex & 0xFF], withoutResponse: false);
    return completer.future;
  }

  /// Whether the WiFi control characteristic (30295783) was discovered.
  bool get hasWifiCharacteristic => _wifiChar != null;

  /// Setup WiFi AP on the device.
  /// Writes [0x01, ssid_len, ssid_bytes..., password_len, password_bytes...]
  /// to the WiFi characteristic (30295783).
  /// Returns true if the device responds with 0 (success).
  Future<bool> setupWifiSync(String ssid, String password) async {
    final ch = _wifiChar;
    if (ch == null) {
      throw StateError('WiFi characteristic not available');
    }
    final ssidBytes = ssid.codeUnits;
    final passwordBytes = password.codeUnits;
    final cmd = <int>[
      0x01,
      ssidBytes.length,
      ...ssidBytes,
      passwordBytes.length,
      ...passwordBytes,
    ];
    debugPrint('[BLE] setupWifiSync: ssid=$ssid cmd_len=${cmd.length}');

    final completer = Completer<bool>();
    StreamSubscription<List<int>>? sub;
    sub = wifiStream.listen((value) {
      if (completer.isCompleted) return;
      if (value.length == 1) {
        completer.complete(value[0] == 0);
      }
    });

    try {
      await ch.write(cmd);
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Start WiFi AP on the device. Writes [0x02].
  /// Returns true if the device responds with 0 (success).
  Future<bool> startWifiSync() async {
    final ch = _wifiChar;
    if (ch == null) {
      throw StateError('WiFi characteristic not available');
    }
    debugPrint('[BLE] startWifiSync');

    final completer = Completer<bool>();
    StreamSubscription<List<int>>? sub;
    sub = wifiStream.listen((value) {
      if (completer.isCompleted) return;
      if (value.length == 1) {
        completer.complete(value[0] == 0);
      }
    });

    try {
      await ch.write([0x02]);
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Stop WiFi AP on the device. Writes [0x03].
  /// Returns true if the device responds with 0 (success).
  Future<bool> stopWifiSync() async {
    final ch = _wifiChar;
    if (ch == null) return false;
    debugPrint('[BLE] stopWifiSync');

    final completer = Completer<bool>();
    StreamSubscription<List<int>>? sub;
    sub = wifiStream.listen((value) {
      if (completer.isCompleted) return;
      if (value.length == 1) {
        completer.complete(value[0] == 0);
      }
    });

    try {
      await ch.write([0x03]);
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } finally {
      await sub.cancel();
    }
  }

  void _handleDisconnection() {
    if (_disposed) return;
    if (connectionState.value == OmiConnectionState.disconnected) return;
    connectionState.value = OmiConnectionState.disconnected;
    notifyListeners();
    if (_autoReconnect &&
        _device != null &&
        _reconnectAttempts < _maxReconnectAttempts) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () async {
      if (_disposed || _device == null || !_autoReconnect) return;
      _reconnectAttempts++;
      connectionState.value = OmiConnectionState.reconnecting;
      notifyListeners();
      try {
        await connect(_device!.remoteId.str);
      } catch (_) {
        if (_autoReconnect && _reconnectAttempts < _maxReconnectAttempts) {
          _scheduleReconnect();
        }
      }
    });
  }

  Future<void> disconnect() async {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _storageSub?.cancel();
    _storageSub = null;
    await _wifiSub?.cancel();
    _wifiSub = null;
    _storageDataChar = null;
    _storageReadCtrlChar = null;
    _wifiChar = null;
    await _batterySub?.cancel();
    _batterySub = null;
    await _connSub?.cancel();
    _connSub = null;
    final device = _device;
    _device = null;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {
        // device may already be gone
      }
    }
    connectionState.value = OmiConnectionState.disconnected;
    notifyListeners();
  }

  void enableAutoReconnect(bool enabled) {
    _autoReconnect = enabled;
    if (!enabled) {
      _reconnectTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _audioSub?.cancel();
    _storageSub?.cancel();
    _wifiSub?.cancel();
    _batterySub?.cancel();
    _connSub?.cancel();
    _audioStreamController.close();
    _storageStreamController.close();
    _wifiStreamController.close();
    connectionState.dispose();
    batteryLevel.dispose();
    codecId.dispose();
    firmwareVersion.dispose();
    hasSmpService.dispose();
    super.dispose();
  }
}
