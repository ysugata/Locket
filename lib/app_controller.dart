import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'models/transcript_segment.dart';
import 'services/background_service.dart';
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
      await background.start();
      device.enableAutoReconnect(settings.autoReconnect);
      await device.connect(bleId);

      _streamer = WhisperStreamer(
        baseUrl: settings.baseUrl,
        authToken: settings.authToken,
        deviceId: settings.deviceId,
        language: settings.language,
      );
      await _streamer!.connect();
      _streamer!.streamAudio(device.audioStream);

      _transcriptSub?.cancel();
      _transcriptSub = _streamer!.transcripts.listen(_onTranscript);

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
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _streamer?.disconnect();
    _streamer?.dispose();
    _streamer = null;
    await device.disconnect();
    await background.stop();
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
