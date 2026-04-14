import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/transcript_segment.dart';

/// Builds the Whisper WebSocket URI from a user-facing base URL plus
/// the fixed query parameters the bridge expects.
///
/// The server authenticates on `?token=` only — Bearer headers are
/// not supported. `frame_header=3byte` tells it that each binary
/// message still carries Omi's `[packet_no:2][fragment_idx:1]` prefix.
Uri buildWhisperUri({
  required String baseUrl,
  required String authToken,
  required String deviceId,
  required String language,
}) {
  final base = Uri.parse(baseUrl);
  final scheme = switch (base.scheme) {
    'https' || 'wss' => 'wss',
    'http' || 'ws' => 'ws',
    _ => 'wss',
  };
  return base.replace(
    scheme: scheme,
    path: base.path.isEmpty ? '/' : base.path,
    queryParameters: {
      'token': authToken,
      'codec': 'opus',
      'sample_rate': '16000',
      'channels': '1',
      'language': language,
      'device_id': deviceId,
      'frame_header': '3byte',
    },
  );
}

enum WhisperConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Relays raw Omi OPUS bytes (3-byte packet header intact) to the
/// self-hosted Whisper server over a WebSocket.
///
/// The app never decodes audio: bytes received from BLE are forwarded
/// verbatim. Frame header stripping, fragment reassembly, and OPUS
/// decoding all happen server-side.
class WhisperStreamer extends ChangeNotifier {
  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _initialBackoff = Duration(seconds: 5);
  static const Duration _maxBackoff = Duration(seconds: 60);

  /// In-memory offline buffer cap (~12 minutes of 16 kHz mono OPUS at
  /// ~80 bytes / 10 ms). Old packets are dropped oldest-first when the
  /// buffer is full.
  static const int _walMaxBytes = 10 * 1024 * 1024;

  final String baseUrl;
  final String authToken;
  final String deviceId;
  final String language;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  StreamSubscription<Uint8List>? _audioSub;

  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Duration _currentBackoff = _initialBackoff;

  bool _shouldBeConnected = false;
  bool _disposed = false;

  final ValueNotifier<WhisperConnectionState> connectionState =
      ValueNotifier(WhisperConnectionState.disconnected);

  final _transcriptController =
      StreamController<TranscriptSegment>.broadcast();
  Stream<TranscriptSegment> get transcripts => _transcriptController.stream;

  final Queue<Uint8List> _walBuffer = Queue<Uint8List>();
  int _walBufferBytes = 0;

  WhisperStreamer({
    required this.baseUrl,
    required this.authToken,
    required this.deviceId,
    this.language = 'ja',
  });

  Uri _buildUri() => buildWhisperUri(
        baseUrl: baseUrl,
        authToken: authToken,
        deviceId: deviceId,
        language: language,
      );

  Future<void> connect() async {
    if (_disposed) return;
    _shouldBeConnected = true;
    await _openChannel();
  }

  Future<void> _openChannel() async {
    if (_disposed || !_shouldBeConnected) return;
    connectionState.value = WhisperConnectionState.connecting;
    notifyListeners();

    try {
      final channel = WebSocketChannel.connect(_buildUri());
      await channel.ready;
      _channel = channel;

      _channelSub = channel.stream.listen(
        _onMessage,
        onDone: _onChannelDone,
        onError: (Object error, StackTrace _) => _onChannelDone(),
        cancelOnError: true,
      );

      connectionState.value = WhisperConnectionState.connected;
      _currentBackoff = _initialBackoff;
      notifyListeners();

      _startHeartbeat();
      _flushWalBuffer();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic message) {
    if (message is String) {
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map<String, dynamic>) {
          final segments = decoded['segments'];
          if (segments is List) {
            for (final seg in segments) {
              if (seg is Map<String, dynamic>) {
                _transcriptController.add(TranscriptSegment.fromJson(seg));
              }
            }
          }
        }
      } catch (_) {
        // Malformed JSON from server — ignore, keep stream alive.
      }
    }
  }

  void _onChannelDone() {
    _stopHeartbeat();
    _channelSub?.cancel();
    _channelSub = null;
    _channel = null;
    if (_disposed || !_shouldBeConnected) {
      connectionState.value = WhisperConnectionState.disconnected;
      notifyListeners();
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !_shouldBeConnected) return;
    _reconnectTimer?.cancel();
    connectionState.value = WhisperConnectionState.reconnecting;
    notifyListeners();

    final delay = _currentBackoff;
    _currentBackoff = Duration(
      seconds: (delay.inSeconds * 2).clamp(
        _initialBackoff.inSeconds,
        _maxBackoff.inSeconds,
      ),
    );

    _reconnectTimer = Timer(delay, _openChannel);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      final channel = _channel;
      if (channel == null) return;
      try {
        // Server ignores binary messages of length <= 2 bytes.
        channel.sink.add(Uint8List.fromList([0xFF, 0xFF]));
      } catch (_) {
        _onChannelDone();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Forwards raw BLE bytes to the WebSocket. Bytes keep Omi's 3-byte
  /// header — decoding is the server's job. Packets that arrive while
  /// the socket is down are queued in a bounded in-memory WAL and
  /// flushed on reconnect.
  void streamAudio(Stream<Uint8List> audioStream) {
    _audioSub?.cancel();
    _audioSub = audioStream.listen(_sendOrBuffer);
  }

  void _sendOrBuffer(Uint8List bytes) {
    final channel = _channel;
    if (channel != null &&
        connectionState.value == WhisperConnectionState.connected) {
      try {
        channel.sink.add(bytes);
        return;
      } catch (_) {
        _onChannelDone();
      }
    }
    _appendToWal(bytes);
  }

  void _appendToWal(Uint8List bytes) {
    _walBuffer.add(bytes);
    _walBufferBytes += bytes.length;
    while (_walBufferBytes > _walMaxBytes && _walBuffer.isNotEmpty) {
      final dropped = _walBuffer.removeFirst();
      _walBufferBytes -= dropped.length;
    }
  }

  void _flushWalBuffer() {
    final channel = _channel;
    if (channel == null ||
        connectionState.value != WhisperConnectionState.connected) {
      return;
    }
    while (_walBuffer.isNotEmpty) {
      final bytes = _walBuffer.removeFirst();
      _walBufferBytes -= bytes.length;
      try {
        channel.sink.add(bytes);
      } catch (_) {
        // Put it back and stop draining; reconnection will retry.
        _walBuffer.addFirst(bytes);
        _walBufferBytes += bytes.length;
        _onChannelDone();
        return;
      }
    }
  }

  int get walBufferedBytes => _walBufferBytes;

  Future<void> disconnect() async {
    _shouldBeConnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHeartbeat();
    await _audioSub?.cancel();
    _audioSub = null;
    await _channelSub?.cancel();
    _channelSub = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await channel.sink.close(ws_status.normalClosure);
      } catch (_) {
        // already closed
      }
    }
    connectionState.value = WhisperConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _shouldBeConnected = false;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    _audioSub?.cancel();
    _channelSub?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        channel.sink.close(ws_status.normalClosure);
      } catch (_) {}
    }
    _transcriptController.close();
    connectionState.dispose();
    super.dispose();
  }
}
