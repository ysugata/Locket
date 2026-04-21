import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/transcript_segment.dart';

/// Builds the WebSocket URL in the exact shape BasedHardware/omi's Flutter
/// client builds, plus the `&token=` query the user's custom bridge
/// requires for authentication (the bridge does not read
/// `Authorization: Bearer`, so Omi's header-based auth is not enough).
///
/// Reference: `omi/app/lib/services/sockets/transcription_service.dart`
/// lines 100-125.
/// Builds the URL exactly as the user's modified Omi app constructs it:
/// `wss://<host>/?token=<TOKEN>&codec=opus&frame_header=3byte`.
/// Path is `/` (the bridge does not care about path, only query).
Uri buildWhisperUri({
  required String baseUrl,
  required String authToken,
  required String deviceId,
  required String language,
  int sampleRate = 16000,
}) {
  var base = baseUrl.trim();
  if (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final scheme = base.startsWith('https://')
      ? 'wss'
      : (base.startsWith('http://') ? 'ws' : 'wss');
  final hostPart = base
      .replaceFirst('https://', '')
      .replaceFirst('http://', '')
      .replaceFirst('wss://', '')
      .replaceFirst('ws://', '');

  // Build the query as a raw string so characters like `+` / `=` /
  // `/` in the token pass through unchanged.
  final query = 'token=$authToken&codec=opus&frame_header=3byte';
  return Uri.parse('$scheme://$hostPart/?$query');
}

/// Omi firmware prepends 3 bytes to every BLE audio notification:
/// `[packet_id_low, packet_id_high, fragment_index]`. Omi's Flutter
/// client strips this before sending on the socket — see
/// `app/lib/services/audio_sources/ble_device_source.dart::getSocketPayload`.
/// Locket does the same.
const int omiBleHeaderSize = 3;

enum WhisperConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Relays Omi BLE audio to the self-hosted Whisper bridge, speaking the
/// exact protocol Omi's Flutter client speaks so the bridge can treat
/// Locket as a drop-in Omi client.
///
/// Wire-level layout matches `omi/app/lib/services/sockets/pure_socket.dart`:
/// - `IOWebSocketChannel.connect(url, headers: ..., pingInterval: 20s,
///   connectTimeout: 15s)`.
/// - `Authorization: Bearer <token>` header carries auth (Omi backend
///   and compatible bridges read the header; Locket drops the legacy
///   `?token=` query since Omi never sends one).
/// - On incoming text `"ping"`, reply with a hand-crafted 2-byte
///   WebSocket pong frame `[0x8A, 0x00]`.
/// - Audio frames are sent via `channel.sink.add(payload)` after the
///   3-byte BLE header is stripped.
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

  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);
  final ValueNotifier<int> bytesSent = ValueNotifier<int>(0);
  final ValueNotifier<int> messagesReceived = ValueNotifier<int>(0);

  final ValueNotifier<List<String>> debugLog =
      ValueNotifier<List<String>>(const []);
  static const int _debugLogMax = 50;

  void _log(String entry) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final line = '$ts $entry';
    debugPrint('[WS] $line');
    final next = [line, ...debugLog.value];
    if (next.length > _debugLogMax) {
      next.removeRange(_debugLogMax, next.length);
    }
    debugLog.value = next;
  }

  final _transcriptController =
      StreamController<TranscriptSegment>.broadcast();
  Stream<TranscriptSegment> get transcripts => _transcriptController.stream;

  final Queue<Uint8List> _walBuffer = Queue<Uint8List>();
  int _walBufferBytes = 0;

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
    _log('connecting → ${uri.scheme}://${uri.host}${uri.path}');

    try {
      // Matches pure_socket.dart:72-79 — same headers Omi sends, same
      // pingInterval, same connectTimeout.
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {
          'Authorization': 'Bearer $authToken',
          'X-App-Platform': 'ios',
          'X-App-Version': '1.0.0',
          'X-Device-Id-Hash': deviceId,
          'X-Request-Start-Time':
              (DateTime.now().millisecondsSinceEpoch / 1000).toString(),
        },
        pingInterval: _pingInterval,
        connectTimeout: _connectTimeout,
      );
      await channel.ready;
      _channel = channel;
      _log('connected');

      _channelSub = channel.stream.listen(
        _onMessage,
        onDone: () {
          final code = channel.closeCode;
          final reason = channel.closeReason;
          _log(
              'closed code=$code reason=${(reason == null || reason.isEmpty) ? '(none)' : reason}');
          if (code != null || (reason != null && reason.isNotEmpty)) {
            lastError.value =
                'WebSocket closed (code=$code${reason == null || reason.isEmpty ? '' : ', $reason'})';
          }
          _onChannelDone();
        },
        onError: (Object error, StackTrace _) {
          _log('error $error');
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
      _log('connect failed: $e');
      lastError.value = e.toString();
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic message) {
    messagesReceived.value = messagesReceived.value + 1;

    // Application-level keepalive: Omi backend sends text "ping"
    // roughly every 10s and expects a 2-byte binary pong frame
    // [0x8A, 0x00] back. See pure_socket.dart:111-115.
    if (message == 'ping') {
      try {
        _channel?.sink.add(Uint8List.fromList(const [0x8A, 0x00]));
      } catch (_) {
        // sink may already be closing
      }
      return;
    }

    if (message is String) {
      final preview =
          message.length > 120 ? '${message.substring(0, 120)}…' : message;
      _log('recv text: $preview');

      try {
        final decoded = jsonDecode(message);
        // Omi backend sends either a bare list of segments or a
        // {"type": "..."} message event (transcription_service.dart:205-242).
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
        // Ignore malformed JSON — keep stream alive.
      }
    } else if (message is List<int>) {
      _log('recv bin: ${message.length}B');
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

  /// Send raw bytes directly on the WebSocket (used by SD sync to
  /// stream stored OPUS frames through the same WS connection).
  void sendRaw(Uint8List bytes) {
    final channel = _channel;
    if (channel != null &&
        connectionState.value == WhisperConnectionState.connected) {
      try {
        channel.sink.add(bytes);
      } catch (_) {}
    }
  }

  /// Forwards BLE bytes verbatim — the user's bridge URL has
  /// `frame_header=3byte` and strips the 3-byte Omi packet header
  /// server-side, so Locket must NOT strip it on the client.
  void streamAudio(Stream<Uint8List> audioStream) {
    _audioSub?.cancel();
    _audioSub = audioStream.listen((bytes) {
      if (bytes.length <= omiBleHeaderSize) return;
      _sendOrBuffer(bytes);
    });
  }

  int _packetCount = 0;

  void _sendOrBuffer(Uint8List bytes) {
    final channel = _channel;
    if (channel != null &&
        connectionState.value == WhisperConnectionState.connected) {
      try {
        if (bytesSent.value == 0) {
          _log(
              'first audio packet ${bytes.length}B ${bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}…');
        }
        channel.sink.add(bytes);
        bytesSent.value = bytesSent.value + bytes.length;
        _packetCount++;
        if (_packetCount % 1000 == 0) {
          _log('sent #$_packetCount total=${bytesSent.value}B');
        }
        return;
      } catch (e) {
        _log('sink.add error $e');
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
    debugLog.dispose();
    super.dispose();
  }
}
