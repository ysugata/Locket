import 'package:flutter_test/flutter_test.dart';
import 'package:locket/models/transcript_segment.dart';
import 'package:locket/services/whisper_streamer.dart';

void main() {
  group('buildWhisperUri', () {
    test('https base → wss with all query params', () {
      final uri = buildWhisperUri(
        baseUrl: 'https://whisper.localai.loan',
        authToken: 'abc123',
        deviceId: 'dev-1',
        language: 'ja',
      );
      expect(uri.scheme, 'wss');
      expect(uri.host, 'whisper.localai.loan');
      expect(uri.path, '/');
      expect(uri.queryParameters['token'], 'abc123');
      expect(uri.queryParameters['codec'], 'opus');
      expect(uri.queryParameters['sample_rate'], '16000');
      expect(uri.queryParameters['channels'], '1');
      expect(uri.queryParameters['language'], 'ja');
      expect(uri.queryParameters['device_id'], 'dev-1');
      expect(uri.queryParameters.containsKey('frame_header'), false);
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

    test('empty path becomes "/"', () {
      final uri = buildWhisperUri(
        baseUrl: 'https://example.com',
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
