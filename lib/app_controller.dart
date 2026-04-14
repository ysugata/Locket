import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'models/transcript_segment.dart';
import 'services/background_service.dart';
import 'services/ios_audio_session.dart';
import 'services/omi_device_service.dart';
import 'services/settings_service.dart';
import 'services/whisper_streamer.dart';

/// Wires the BLE, WebSocket, and foreground-service layers together
/// and exposes a single surface the UI can watch.
class AppController extends ChangeNotifier {
  static const int _maxTranscriptHistory = 50;

  final SettingsService settings;
  final OmiDeviceService device;
  final BackgroundService background;

  WhisperStreamer? _streamer;
  StreamSubscription<TranscriptSegment>? _transcriptSub;
  Timer? _byteRefresh;

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
  });

  WhisperStreamer? get streamer => _streamer;

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

  /// Starts BLE + WebSocket relay and the foreground service.
  /// Requires a paired BLE device id and a non-empty auth token.
  Future<void> start() async {
    if (_running) return;
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

      final streamer = WhisperStreamer(
        baseUrl: settings.baseUrl,
        authToken: settings.authToken,
        deviceId: settings.deviceId,
        language: settings.language,
      );
      // Forward streamer state changes so the HomePage AnimatedBuilder
      // (which only watches `this`) rebuilds when WS state or errors
      // change. bytesSent is updated ~100 Hz from the BLE notify
      // stream, so it's throttled to a periodic refresh instead of
      // rebuilding the home page on every audio packet.
      streamer.connectionState.addListener(notifyListeners);
      streamer.lastError.addListener(notifyListeners);
      streamer.messagesReceived.addListener(notifyListeners);
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

      _running = true;
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      await stop();
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _running = false;
    _byteRefresh?.cancel();
    _byteRefresh = null;
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _streamer?.disconnect();
    _streamer?.dispose();
    _streamer = null;
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
    stop();
    super.dispose();
  }
}
