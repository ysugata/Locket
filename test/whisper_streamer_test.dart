import 'package:flutter_test/flutter_test.dart';
import 'package:locket/models/transcript_segment.dart';
import 'package:locket/services/whisper_streamer.dart';

void main() {
  group('buildWhisperUri', () {
    test('https base → wss /v4/listen with Omi query params', () {
      final uri = buildWhisperUri(
        baseUrl: 'https://whisper.localai.loan',
        authToken: 'secret',
        deviceId: 'dev-1',
        language: 'ja',
      );
      expect(uri.scheme, 'wss');
      expect(uri.host, 'whisper.localai.loan');
      expect(uri.path, '/v4/listen');
      expect(uri.queryParameters['language'], 'ja');
      expect(uri.queryParameters['sample_rate'], '16000');
      expect(uri.queryParameters['codec'], 'opus');
      expect(uri.queryParameters['uid'], 'dev-1');
      expect(uri.queryParameters['include_speech_profile'], 'false');
      expect(uri.queryParameters['conversation_timeout'], '120');
      expect(uri.queryParameters['speaker_auto_assign'], 'enabled');
      // Auth is via Authorization: Bearer header, not query.
      expect(uri.queryParameters.containsKey('token'), false);
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
      expect(uri.path, '/v4/listen');
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
      expect(uri.path, '/v4/listen');
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
