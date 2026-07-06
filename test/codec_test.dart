import 'package:flutter_test/flutter_test.dart';
import 'package:locket/services/omi_device_service.dart';

void main() {
  group('isOpusCodec', () {
    test('accepts both OPUS ids (20 and FS320 21)', () {
      expect(isOpusCodec(omiCodecOpus), isTrue);
      expect(isOpusCodec(omiCodecOpusFS320), isTrue);
    });

    test('rejects non-OPUS codecs', () {
      expect(isOpusCodec(0), isFalse); // pcm16
      expect(isOpusCodec(1), isFalse); // pcm8
      expect(isOpusCodec(-1), isFalse); // unread
    });
  });
}
