import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:locket/services/ring_protocol.dart';

Uint8List _be64(int v) {
  final b = ByteData(8)..setUint64(0, v, Endian.big);
  return b.buffer.asUint8List();
}

void main() {
  group('parseStatus (16B LE)', () {
    test('parses the four u32 little-endian fields', () {
      final bd = ByteData(16)
        ..setUint32(0, 12345, Endian.little)
        ..setUint32(4, 42, Endian.little)
        ..setUint32(8, 999999, Endian.little)
        ..setUint32(12, 1, Endian.little);
      final s = RingProtocol.parseStatus(bd.buffer.asUint8List())!;
      expect(s.usedBytes, 12345);
      expect(s.unreadPackets, 42);
      expect(s.freeBytes, 999999);
      expect(s.isRtcValid, isTrue);
    });

    test('returns null when short', () {
      expect(RingProtocol.parseStatus([1, 2, 3]), isNull);
    });
  });

  group('parseInfoNotification (0x02)', () {
    test('parses seq/capacity/dropped/pktsize', () {
      final b = <int>[
        RingProtocol.notifyInfo,
        ..._be64(100), // read
        ..._be64(150), // write
        ...(ByteData(4)..setUint32(0, 8000, Endian.big)).buffer.asUint8List(),
        ..._be64(0), // dropped
        ...(ByteData(2)..setUint16(0, 444, Endian.big)).buffer.asUint8List(),
      ];
      final info = RingProtocol.parseInfoNotification(b)!;
      expect(info.readSeq, 100);
      expect(info.writeSeq, 150);
      expect(info.unreadPackets, 50);
      expect(info.capacityPackets, 8000);
      expect(info.packetSize, 444);
    });

    test('rejects wrong opcode', () {
      expect(RingProtocol.parseInfoNotification([0x03, 0, 0]), isNull);
    });
  });

  group('parseDoneNotification (0x04)', () {
    test('ok status + next seq', () {
      final b = <int>[RingProtocol.notifyDone, 0, ..._be64(150)];
      final d = RingProtocol.parseDoneNotification(b)!;
      expect(d.isOk, isTrue);
      expect(d.nextSeq, 150);
    });
    test('non-zero status is not ok', () {
      final b = <int>[RingProtocol.notifyDone, 7, ..._be64(150)];
      expect(RingProtocol.parseDoneNotification(b)!.isOk, isFalse);
    });
  });

  group('encodeReadCommand / encodeAdvanceCommand', () {
    test('read without count is 9 bytes', () {
      final c = RingProtocol.encodeReadCommand(0x0102030405060708);
      expect(c.length, 9);
      expect(c[0], RingProtocol.cmdRead);
      expect(c.sublist(1), [1, 2, 3, 4, 5, 6, 7, 8]);
    });
    test('read with count is 13 bytes', () {
      final c = RingProtocol.encodeReadCommand(1, packetCount: 5);
      expect(c.length, 13);
      expect(c[0], RingProtocol.cmdRead);
    });
    test('advance encodes opcode + seq', () {
      final c = RingProtocol.encodeAdvanceCommand(0x1122);
      expect(c[0], RingProtocol.cmdAdvance);
      expect(c.length, 9);
    });
  });

  group('parseAudioPayload', () {
    test('extracts packed [size][frame] entries', () {
      final audio = <int>[3, 0xAA, 0xBB, 0xCC, 2, 0x01, 0x02, 0, 0, 0];
      final frames = RingProtocol.parseAudioPayload(audio);
      expect(frames.length, 2);
      expect(frames[0], [0xAA, 0xBB, 0xCC]);
      expect(frames[1], [0x01, 0x02]);
    });

    test('stops at a boundary size byte with no full frame', () {
      // size says 5 but only 2 bytes remain → dropped (stale).
      final audio = <int>[2, 0x01, 0x02, 5, 0x09, 0x09];
      final frames = RingProtocol.parseAudioPayload(audio);
      expect(frames.length, 1);
      expect(frames[0], [0x01, 0x02]);
    });
  });

  group('RingRecordReassembler', () {
    test('emits complete 444B records, buffers the remainder', () {
      final r = RingRecordReassembler();
      r.append(List.filled(400, 1));
      expect(r.drainRecords(), isEmpty);
      expect(r.pendingBytes, 400);
      r.append(List.filled(100, 2)); // now 500 bytes → one 444 record
      final recs = r.drainRecords();
      expect(recs.length, 1);
      expect(recs[0].length, 444);
      expect(r.pendingBytes, 56);
    });
  });
}
