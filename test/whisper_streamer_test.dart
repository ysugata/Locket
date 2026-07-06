import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:locket/models/transcript_segment.dart';
import 'package:locket/services/whisper_streamer.dart';

/// Builds a fake Omi BLE notification: [id_low, id_high, frag] + payload.
Uint8List omiPacket(int packetId, {int payloadSize = 80}) {
  return Uint8List.fromList([
    packetId & 0xFF,
    (packetId >> 8) & 0xFF,
    0,
    ...List.filled(payloadSize, 0x42),
  ]);
}

void main() {
  group('buildWhisperUri', () {
    test('https base → wss with token + codec + frame_header', () {
      final uri = buildWhisperUri(
        baseUrl: 'https://whisper.localai.loan',
        authToken: 'secret',
        deviceId: 'dev-1',
        language: 'ja',
      );
      expect(uri.scheme, 'wss');
      expect(uri.host, 'whisper.localai.loan');
      expect(uri.path, '/');
      expect(uri.queryParameters['token'], 'secret');
      expect(uri.queryParameters['codec'], 'opus');
      expect(uri.queryParameters['frame_header'], '3byte');
    });

    test('http base → ws', () {
      final uri = buildWhisperUri(
        baseUrl: 'http://localhost:8080',
        authToken: 't',
        deviceId: 'd',
        language: 'en',
      );
      expect(uri.scheme, 'ws');
      expect(uri.host, 'localhost');
      expect(uri.port, 8080);
      expect(uri.path, '/');
    });

    test('wss base stays wss', () {
      final uri = buildWhisperUri(
        baseUrl: 'wss://whisper.localai.loan',
        authToken: 't',
        deviceId: 'd',
        language: 'ja',
      );
      expect(uri.scheme, 'wss');
    });

    test('trailing slash in base is tolerated', () {
      final uri = buildWhisperUri(
        baseUrl: 'https://example.com/',
        authToken: 't',
        deviceId: 'd',
        language: 'ja',
      );
      expect(uri.path, '/');
    });
  });

  group('omiBleHeaderSize', () {
    test('matches Omi firmware: 2 bytes packet id + 1 byte fragment idx', () {
      expect(omiBleHeaderSize, 3);
    });
  });

  group('packet gap detection', () {
    late WhisperStreamer streamer;
    late StreamController<Uint8List> audio;

    setUp(() {
      streamer = WhisperStreamer(
        baseUrl: 'https://example.com',
        authToken: 't',
        deviceId: 'd',
      );
      audio = StreamController<Uint8List>();
      streamer.streamAudio(audio.stream);
    });

    tearDown(() async {
      await audio.close();
      streamer.dispose();
    });

    test('consecutive packet ids report no gap', () async {
      for (var id = 0; id < 10; id++) {
        audio.add(omiPacket(id));
      }
      await Future<void>.delayed(Duration.zero);
      expect(streamer.gapCount, 0);
      expect(streamer.totalGapFrames, 0);
    });

    test('a missing packet id is counted as a gap', () async {
      audio.add(omiPacket(1));
      audio.add(omiPacket(2));
      audio.add(omiPacket(6)); // 3,4,5 missing
      await Future<void>.delayed(Duration.zero);
      expect(streamer.gapCount, 1);
      expect(streamer.totalGapFrames, 3);
    });

    test('16-bit packet id wraparound is not a gap', () async {
      audio.add(omiPacket(0xFFFE));
      audio.add(omiPacket(0xFFFF));
      audio.add(omiPacket(0x0000));
      audio.add(omiPacket(0x0001));
      await Future<void>.delayed(Duration.zero);
      expect(streamer.gapCount, 0);
    });

    test('huge jumps (device reboot) are ignored', () async {
      audio.add(omiPacket(10));
      audio.add(omiPacket(5000));
      await Future<void>.delayed(Duration.zero);
      expect(streamer.gapCount, 0);
    });

    test('offline frames land in the memory WAL buffer', () async {
      audio.add(omiPacket(1, payloadSize: 80));
      audio.add(omiPacket(2, payloadSize: 80));
      await Future<void>.delayed(Duration.zero);
      // 2 packets × (3B header + 80B payload), never sent — buffered.
      expect(streamer.walBufferedBytes, 2 * 83);
    });
  });

  group('TranscriptSegment.fromJson', () {
    test('full payload with optional fields', () {
      final seg = TranscriptSegment.fromJson({
        'start': 1.5,
        'end': 2.75,
        'text': 'hello',
        'speaker': 'SPEAKER_00',
        'avg_logprob': -0.2,
        'no_speech_prob': 0.01,
      });
      expect(seg.start, 1.5);
      expect(seg.end, 2.75);
      expect(seg.text, 'hello');
      expect(seg.speaker, 'SPEAKER_00');
      expect(seg.avgLogprob, -0.2);
      expect(seg.noSpeechProb, 0.01);
    });

    test('minimal payload with defaults', () {
      final seg = TranscriptSegment.fromJson({'text': 'こんにちは'});
      expect(seg.start, 0.0);
      expect(seg.end, 0.0);
      expect(seg.text, 'こんにちは');
      expect(seg.speaker, isNull);
      expect(seg.avgLogprob, isNull);
      expect(seg.noSpeechProb, isNull);
    });

    test('integer numerics are promoted to double', () {
      final seg = TranscriptSegment.fromJson({
        'start': 1,
        'end': 2,
        'text': 'x',
      });
      expect(seg.start, 1.0);
      expect(seg.end, 2.0);
    });
  });
}
