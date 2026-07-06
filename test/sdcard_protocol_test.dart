import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:locket/services/sdcard_protocol.dart';

void main() {
  group('parseSdNotification — 1-byte responses', () {
    for (final (code, name) in [
      (SdResponseCode.ok, 'ok'),
      (SdResponseCode.badFileSize, 'badFileSize'),
      (SdResponseCode.emptyFile, 'emptyFile'),
      (SdResponseCode.endOfFile, 'endOfFile'),
    ]) {
      test('code $name ($code) is a response in both protocols', () {
        for (final protocol in SdProtocol.values) {
          final n = parseSdNotification([code], protocol);
          expect(n.isResponse, isTrue);
          expect(n.responseCode, code);
          expect(n.frames, isEmpty);
          expect(n.audioBytes, 0);
        }
      });
    }
  });

  group('parseSdNotification — multi-file protocol', () {
    test('CMD_READ_FILE write echo is flagged', () {
      final n = parseSdNotification([
        0x11,
        0x02,
        0x00,
        0x00,
        0x00,
        0x00,
      ], SdProtocol.multiFile);
      expect(n.isEcho, isTrue);
      expect(n.frames, isEmpty);
    });

    test('parses [ts:4 BE][size:1][frame]... batch', () {
      // Timestamp 0x69558180 = 1767211392 (2025-12-31T20:03:12Z).
      final value = <int>[
        0x69, 0x55, 0x81, 0x80, // ts BE
        3, 0xAA, 0xBB, 0xCC, // frame 1 (3 bytes)
        2, 0x01, 0x02, // frame 2 (2 bytes)
      ];
      final n = parseSdNotification(value, SdProtocol.multiFile);
      expect(n.isResponse, isFalse);
      expect(n.frames.length, 2);
      expect(n.frames[0], [0xAA, 0xBB, 0xCC]);
      expect(n.frames[1], [0x01, 0x02]);
      expect(n.audioBytes, value.length - 4);
      expect(n.epochSeconds, 1767211392);
    });

    test('zero size byte terminates the batch', () {
      final value = <int>[
        0x69, 0x55, 0x81, 0x80, // ts
        2, 0x01, 0x02, // frame
        0, // terminator
        3, 0xFF, 0xFF, 0xFF, // must not be parsed
      ];
      final n = parseSdNotification(value, SdProtocol.multiFile);
      expect(n.frames.length, 1);
    });

    test('truncated frame at the end is dropped, not mis-parsed', () {
      final value = <int>[
        0x69, 0x55, 0x81, 0x80,
        2, 0x01, 0x02,
        10, 0x01, 0x02, // claims 10 bytes but only 2 present
      ];
      final n = parseSdNotification(value, SdProtocol.multiFile);
      expect(n.frames.length, 1);
      expect(n.frames[0], [0x01, 0x02]);
    });

    test('implausible timestamp (RTC unset) becomes null', () {
      final value = <int>[
        0x00, 0x00, 0x00, 0x05, // epoch 5 — device RTC never set
        2, 0x01, 0x02,
      ];
      final n = parseSdNotification(value, SdProtocol.multiFile);
      expect(n.epochSeconds, isNull);
      expect(n.frames.length, 1);
    });
  });

  group('parseSdNotification — legacy protocol', () {
    test('6-byte command write echo is flagged (0x00/0x01/0x03)', () {
      for (final cmd in [0x00, 0x01, 0x03]) {
        final n = parseSdNotification([
          cmd,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
        ], SdProtocol.legacy);
        expect(n.isEcho, isTrue, reason: 'cmd 0x$cmd should be echo');
      }
    });

    test('83-byte single frame: [header:3][amount:1][frame:amount]', () {
      final frame = List<int>.generate(79, (i) => i & 0xFF);
      final value = <int>[
        0x01, 0x00, 0x00, // 3-byte header
        79, // amount
        ...frame,
      ];
      expect(value.length, 83);
      final n = parseSdNotification(value, SdProtocol.legacy);
      expect(n.frames.length, 1);
      expect(n.frames[0], frame);
      expect(n.audioBytes, 80);
    });

    test('packed batch: [size:1][frame:size]... from position 0', () {
      final value = <int>[3, 0xAA, 0xBB, 0xCC, 2, 0x01, 0x02];
      final n = parseSdNotification(value, SdProtocol.legacy);
      expect(n.frames.length, 2);
      expect(n.audioBytes, value.length);
    });

    test(
      '0xFF timestamp marker: [0xFF][epoch:4 LE] is skipped and captured',
      () {
        // Epoch 0x69558180 = 1767211392 → LE bytes 80 81 55 69.
        final value = <int>[
          2, 0x01, 0x02,
          0xFF, 0x80, 0x81, 0x55, 0x69, // marker
          3, 0xAA, 0xBB, 0xCC,
        ];
        final n = parseSdNotification(value, SdProtocol.legacy);
        expect(n.frames.length, 2);
        expect(n.frames[1], [0xAA, 0xBB, 0xCC]);
        expect(n.epochSeconds, 1767211392);
      },
    );
  });

  group('encodeLengthPrefixedFrames', () {
    test('encodes [len:4 LE][frame]...', () {
      final body = encodeLengthPrefixedFrames([
        Uint8List.fromList([0xAA, 0xBB]),
        Uint8List.fromList([0x01]),
      ]);
      expect(body, [
        2, 0, 0, 0, 0xAA, 0xBB, // frame 1
        1, 0, 0, 0, 0x01, // frame 2
      ]);
    });

    test('empty input produces empty body', () {
      expect(encodeLengthPrefixedFrames([]), isEmpty);
    });
  });
}
