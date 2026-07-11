import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'models/transcript_segment.dart';
import 'services/background_service.dart';
import 'services/firmware_service.dart';
import 'services/ios_audio_session.dart';
import 'services/omi_device_service.dart';
import 'services/sdcard_sync_service.dart';
import 'services/settings_service.dart';
import 'services/wal_store.dart';
import 'services/whisper_streamer.dart';
import 'services/wifi_sync_service.dart';

/// Wires the BLE, WebSocket, and foreground-service layers together
/// and exposes a single surface the UI can watch.
class AppController extends ChangeNotifier {
  static const int _maxTranscriptHistory = 50;
  static const Duration _startRetryDelay = Duration(seconds: 30);

  final SettingsService settings;
  final OmiDeviceService device;
  final BackgroundService background;

  WhisperStreamer? _streamer;
  WalStore? _walStore;
  SDCardSyncService? _sdCardSync;
  WifiSyncService? _wifiSync;
  FirmwareService? _firmwareService;
  StreamSubscription<TranscriptSegment>? _transcriptSub;
  Timer? _byteRefresh;
  Timer? _startRetryTimer;

  final Queue<TranscriptSegment> _transcripts = Queue<TranscriptSegment>();
  List<TranscriptSegment> get transcripts => List.unmodifiable(_transcripts);

  bool _running = false;
  bool get running => _running;

  String? _lastError;
  String? get lastError => _lastError;

  AppController({
    required this.settings,
    required this.device,
    required this.background,
  }) {
    // Reflect settings changes (token, paired device, language) into
    // the live relay automatically — the user no longer has a manual
    // start/stop control, so a settings save is the only signal that
    // we should reconnect.
    settings.addListener(_onSettingsChanged);
  }

  WhisperStreamer? get streamer => _streamer;
  SDCardSyncService? get sdCardSync => _sdCardSync;
  WifiSyncService? get wifiSync => _wifiSync;
  FirmwareService? get firmwareService => _firmwareService;
  WalStore? get walStore => _walStore;

  /// Returns true when the user has provided everything required for
  /// `start()` to do real work.
  bool get isConfigured =>
      settings.authToken.isNotEmpty &&
      (settings.pairedBleId?.isNotEmpty ?? false);

  /// Starts the relay only when settings are complete. Used at app
  /// launch so a configured user does not need to tap a button.
  Future<void> tryAutoStart() async {
    if (!isConfigured || _running) return;
    await start();
  }

  String? _lastSettingsFingerprint;
  bool _settingsRestartInFlight = false;

  /// Triggered whenever any settings field changes. If the relay is
  /// already running with stale settings, we tear it down and bring
  /// it back up with the new values. If it isn't running yet but is
  /// now configured, we kick it off.
  void _onSettingsChanged() {
    final fp = _settingsFingerprint();
    if (fp == _lastSettingsFingerprint) return;
    _lastSettingsFingerprint = fp;
    if (_settingsRestartInFlight) return;
    _settingsRestartInFlight = true;
    Future(() async {
      try {
        if (_running) {
          await stop();
        }
        await tryAutoStart();
      } finally {
        _settingsRestartInFlight = false;
      }
    });
  }

  String _settingsFingerprint() => [
    settings.baseUrl,
    settings.authToken,
    settings.language,
    settings.pairedBleId ?? '',
    settings.autoReconnect.toString(),
  ].join('|');

  /// Starts BLE + WebSocket relay and the foreground service.
  /// Requires a paired BLE device id and a non-empty auth token.
  Future<void> start() async {
    if (_running) return;
    _startRetryTimer?.cancel();
    _startRetryTimer = null;
    _lastError = null;

    final bleId = settings.pairedBleId;
    if (bleId == null || bleId.isEmpty) {
      _lastError = 'デバイスが未ペアリングです';
      notifyListeners();
      return;
    }
    if (settings.authToken.isEmpty) {
      _lastError = '認証トークンが未設定です';
      notifyListeners();
      return;
    }

    try {
      // Activate AVAudioSession before foreground service starts so
      // iOS credits the app for both audio and BLE background work.
      await IOSAudioSession.configureForBluetooth();
      await background.start();
      device.enableAutoReconnect(settings.autoReconnect);
      await device.connect(bleId);

      // The relay assumes OPUS; anything else would be transcribed as
      // garbage server-side, so surface it prominently. Both OPUS ids
      // (20 and FS320's 21) are fine — the frames self-describe their
      // size to the decoder.
      final codec = device.codecId.value;
      if (codec >= 0 && !isOpusCodec(codec)) {
        _lastError =
            'デバイスのコーデックがOPUSではありません (id=$codec)。'
            '文字起こしが正しく動作しない可能性があります';
      }

      // Disk-backed WAL: offline audio is spilled here and recovered
      // via POST /sdcard/upload. Survives app kills and crashes.
      final walStore = WalStore(
        uploadUrl: _buildUploadUrl(),
        authToken: settings.authToken,
        deviceId: settings.deviceId,
      );
      await walStore.init();
      _walStore?.dispose();
      _walStore = walStore;

      final streamer = WhisperStreamer(
        baseUrl: settings.baseUrl,
        authToken: settings.authToken,
        deviceId: settings.deviceId,
        language: settings.language,
        walStore: walStore,
      );
      // Forward streamer state changes so the HomePage AnimatedBuilder
      // (which only watches `this`) rebuilds when WS state or errors
      // change. bytesSent is updated ~100 Hz from the BLE notify
      // stream, so it's throttled to a periodic refresh instead of
      // rebuilding the home page on every audio packet.
      streamer.connectionState.addListener(notifyListeners);
      streamer.lastError.addListener(notifyListeners);
      streamer.messagesReceived.addListener(notifyListeners);
      streamer.debugLog.addListener(notifyListeners);
      _byteRefresh?.cancel();
      _byteRefresh = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => notifyListeners(),
      );
      _streamer = streamer;

      await streamer.connect();
      streamer.streamAudio(device.audioStream);

      _transcriptSub?.cancel();
      _transcriptSub = streamer.transcripts.listen(_onTranscript);

      // Create firmware update service.
      _firmwareService?.dispose();
      _firmwareService = FirmwareService()
        ..currentVersion = device.firmwareVersion.value
        ..addListener(notifyListeners);

      // Create SD card sync service.
      _sdCardSync?.dispose();
      _sdCardSync = SDCardSyncService(
        device: device,
        uploadUrl: _buildUploadUrl(),
        authToken: settings.authToken,
        deviceId: settings.deviceId,
        walStore: walStore,
      );
      _sdCardSync!.addListener(notifyListeners);

      // Create WiFi sync service (only usable if device has WiFi char).
      _wifiSync?.dispose();
      _wifiSync = WifiSyncService(
        device: device,
        uploadUrl: _buildUploadUrl(),
        authToken: settings.authToken,
        deviceId: settings.deviceId,
      );
      _wifiSync!.addListener(notifyListeners);

      _running = true;
      notifyListeners();

      // Resume an interrupted SD sync whenever the BLE link comes back
      // — without this, a mid-sync disconnect leaves the SD card only
      // partially drained until the next app launch.
      _prevBleState = device.connectionState.value;
      device.connectionState.addListener(_onBleReconnected);

      // Recover WAL segments left over from a previous run or crash.
      walStore.uploadPending();

      // Auto-sync SD card in the background after connection is ready.
      _autoSyncSDCard();
    } catch (e) {
      _lastError = e.toString();
      await stop();
      // The device may simply be out of range or powered off right
      // now (e.g. app launched before putting the wearable on).
      // Keep retrying instead of staying dead until a settings change.
      _scheduleStartRetry();
      notifyListeners();
    }
  }

  OmiConnectionState? _prevBleState;

  void _onBleReconnected() {
    final state = device.connectionState.value;
    final prev = _prevBleState;
    _prevBleState = state;
    if (!_running) return;
    if (state == OmiConnectionState.connected &&
        prev != OmiConnectionState.connected) {
      debugPrint('[App] BLE reconnected — resuming SD sync + WAL upload');
      _walStore?.uploadPending();
      _autoSyncSDCard(); // syncAll() is a no-op while already syncing
    }
  }

  void _scheduleStartRetry() {
    _startRetryTimer?.cancel();
    if (!isConfigured) return;
    _startRetryTimer = Timer(_startRetryDelay, () {
      if (_running) return;
      debugPrint('[App] retrying start() after failure');
      start();
    });
  }

  /// Manual retry from the UI: restarts the relay when stopped, or
  /// kicks an immediate BLE reconnect when the relay is running but
  /// the device link is down.
  Future<void> retryConnect() async {
    _startRetryTimer?.cancel();
    _startRetryTimer = null;
    if (!_running) {
      await start();
      return;
    }
    final bleId = settings.pairedBleId;
    if (bleId == null || bleId.isEmpty) return;
    if (device.connectionState.value == OmiConnectionState.disconnected ||
        device.connectionState.value == OmiConnectionState.reconnecting) {
      try {
        await device.connect(bleId);
      } catch (e) {
        _lastError = e.toString();
        notifyListeners();
      }
    }
  }

  /// Build the SD card upload URL from baseUrl.
  String _buildUploadUrl() {
    var base = settings.baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    // Replace http:// with https:// for upload endpoint.
    if (base.startsWith('http://')) {
      base = 'https://${base.substring(7)}';
    }
    return '$base/sdcard/upload';
  }

  /// Auto-sync SD card after BLE connection is established.
  void _autoSyncSDCard() {
    final sync = _sdCardSync;
    if (sync == null) return;
    Future(() async {
      try {
        await sync.syncAll();
      } catch (e) {
        debugPrint('[SDSync] auto-sync error: $e');
      }
    });
  }

  /// Manually trigger SD card sync.
  Future<void> syncSDCard() async {
    final sync = _sdCardSync;
    if (sync == null) return;
    await sync.syncAll();
  }

  /// Rescue sync for a wedged/full card: pauses live transcription,
  /// sacrifices up to 5 unreadable files to free LittleFS headroom,
  /// then drains everything readable.
  Future<void> rescueSDCard() async {
    final sync = _sdCardSync;
    if (sync == null) return;
    await sync.rescueSync();
  }

  /// Manually trigger WiFi sync.
  Future<void> syncWifi() async {
    final sync = _wifiSync;
    if (sync == null) return;
    await sync.sync();
  }

  Future<void> stop() async {
    _running = false;
    device.connectionState.removeListener(_onBleReconnected);
    _startRetryTimer?.cancel();
    _startRetryTimer = null;
    _byteRefresh?.cancel();
    _byteRefresh = null;
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    _sdCardSync?.cancel();
    _sdCardSync?.dispose();
    _sdCardSync = null;
    await _wifiSync?.cancel();
    _wifiSync?.dispose();
    _wifiSync = null;
    _firmwareService?.dispose();
    _firmwareService = null;
    await _streamer?.disconnect();
    _streamer?.dispose();
    _streamer = null;
    // Segment files stay on disk; only the handle is released. They
    // are recovered by uploadPending() on the next start.
    _walStore?.dispose();
    _walStore = null;
    await device.disconnect();
    await background.stop();
    await IOSAudioSession.deactivate();
    notifyListeners();
  }

  void _onTranscript(TranscriptSegment seg) {
    _transcripts.addLast(seg);
    while (_transcripts.length > _maxTranscriptHistory) {
      _transcripts.removeFirst();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    stop();
    super.dispose();
  }
}
