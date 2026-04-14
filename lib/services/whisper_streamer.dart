import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/transcript_segment.dart';

/// Builds the Whisper WebSocket URI from a user-facing base URL plus
/// the query parameters the bridge expects.
///
/// Matches the Omi reference client (`v4/listen` style): `?token=<X>`
/// for auth on the user's self-hosted bridge, plus `codec=opus` and
/// the audio shape so the server doesn't have to guess.
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
    },
  );
}

/// Number of bytes Omi firmware prepends to every BLE notification:
/// `[packet_id_low, packet_id_high, fragment_index]`. The header is
/// only used by the device-side WAL for fragment ordering — it is
/// **not** part of the OPUS payload and must be removed before the
/// bytes hit any decoder. Matches `getSocketPayload` in the Omi
/// reference client (`app/lib/services/audio_sources/ble_device_source.dart`).
const int omiBleHeaderSize = 3;

enum WhisperConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Relays Omi BLE audio (OPUS, 16 kHz mono) to the self-hosted Whisper
/// server over a WebSocket.
///
/// The 3-byte Omi packet header is stripped before each binary message
/// is sent, matching the Omi reference Flutter app. Without this the
/// server tries to OPUS-decode a malformed first byte and closes the
/// connection cleanly, producing a reconnect loop with zero
/// transcripts. The app does **not** decode OPUS — only the header
/// strip happens here.
class WhisperStreamer extends ChangeNotifier {
  static const Duration _pingInterval = Duration(seconds: 20);
  static const Duration _connectTimeout = Duration(seconds: 15);
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

  Timer? _reconnectTimer;
  Duration _currentBackoff = _initialBackoff;

  bool _shouldBeConnected = false;
  bool _disposed = false;

  final ValueNotifier<WhisperConnectionState> connectionState =
      ValueNotifier(WhisperConnectionState.disconnected);

  /// Last connection failure or close reason, surfaced in the UI so
  /// the user can tell whether the relay is misconfigured (bad token,
  /// wrong URL, TLS error) versus genuinely offline.
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Cumulative number of audio bytes pushed to the socket since the
  /// streamer was created. Helpful debug signal — if BLE is connected
  /// and bytesSent stays at 0 the audio stream isn't being piped in.
  final ValueNotifier<int> bytesSent = ValueNotifier<int>(0);

  /// Number of JSON messages received from the server. If this is 0
  /// while audio is flowing, the server isn't accepting our payload.
  final ValueNotifier<int> messagesReceived = ValueNotifier<int>(0);

  final _transcriptController =
      StreamController<TranscriptSegment>.broadcast();
  Stream<TranscriptSegment> get transcripts => _transcriptController.stream;

  final Queue<Uint8List> _walBuffer = Queue<Uint8List>();
  int _walBufferBytes = 0;

  /// URI used for the most recent connection attempt. Exposed so the
  /// UI can show the user exactly what scheme/host/path is being hit
  /// (with the token redacted).
  Uri? _lastUri;
  Uri? get lastUri => _lastUri;

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

    final uri = _buildUri();
    _lastUri = uri;

    try {
      // IOWebSocketChannel exposes pingInterval which sends WebSocket
      // protocol-level ping frames. Those are control frames, not
      // delivered to the server's message handler — much safer than
      // a custom binary heartbeat that the server would otherwise try
      // to OPUS-decode.
      final channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: _pingInterval,
        connectTimeout: _connectTimeout,
      );
      await channel.ready;
      _channel = channel;

      _channelSub = channel.stream.listen(
        _onMessage,
        onDone: () {
          final code = channel.closeCode;
          final reason = channel.closeReason;
          if (code != null || (reason != null && reason.isNotEmpty)) {
            lastError.value =
                'WebSocket closed (code=$code${reason == null || reason.isEmpty ? '' : ', $reason'})';
          }
          _onChannelDone();
        },
        onError: (Object error, StackTrace _) {
          lastError.value = error.toString();
          _onChannelDone();
        },
        cancelOnError: true,
      );

      connectionState.value = WhisperConnectionState.connected;
      lastError.value = null;
      _currentBackoff = _initialBackoff;
      notifyListeners();

      _flushWalBuffer();
    } catch (e) {
      lastError.value = e.toString();
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic message) {
    messagesReceived.value = messagesReceived.value + 1;
    if (message is String) {
      try {
        final decoded = jsonDecode(message);
        // Server may send either a bare list of segments (Omi v4 style)
        // or a {"segments": [...]} envelope.
        if (decoded is List) {
          for (final seg in decoded) {
            if (seg is Map<String, dynamic>) {
              _transcriptController.add(TranscriptSegment.fromJson(seg));
            }
          }
        } else if (decoded is Map<String, dynamic>) {
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

  /// Forwards Omi BLE bytes to the WebSocket after stripping the
  /// 3-byte packet header. Packets that arrive while the socket is
  /// down are queued in a bounded in-memory WAL and flushed on
  /// reconnect.
  void streamAudio(Stream<Uint8List> audioStream) {
    _audioSub?.cancel();
    _audioSub = audioStream.listen((bytes) {
      if (bytes.length <= omiBleHeaderSize) return;
      final payload = Uint8List.sublistView(bytes, omiBleHeaderSize);
      _sendOrBuffer(payload);
    });
  }

  void _sendOrBuffer(Uint8List bytes) {
    final channel = _channel;
    if (channel != null &&
        connectionState.value == WhisperConnectionState.connected) {
      try {
        channel.sink.add(bytes);
        bytesSent.value = bytesSent.value + bytes.length;
        return;
      } catch (e) {
        lastError.value = e.toString();
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
    lastError.dispose();
    bytesSent.dispose();
    messagesReceived.dispose();
    super.dispose();
  }
}
