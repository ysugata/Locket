import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:locket/services/wal_store.dart';

void main() {
  late Directory tmp;
  WalStore? store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wal_store_test');
  });

  tearDown(() async {
    store?.dispose();
    store = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  WalStore makeStore({http.Client? client, int maxTotalBytes = 1 << 30}) {
    return WalStore(
      uploadUrl: 'https://example.com/sdcard/upload',
      authToken: 'secret',
      deviceId: 'dev-1',
      maxTotalBytes: maxTotalBytes,
      client: client ?? MockClient((_) async => http.Response('', 200)),
      directory: Directory('${tmp.path}/wal'),
    );
  }

  Uint8List body(int filler, [int size = 16]) =>
      Uint8List.fromList(List.filled(size, filler));

  test('writeSegment persists a file and updates stats', () async {
    final s = store = makeStore();
    await s.init();

    final ok = await s.writeSegment(body(0xAB), 1751800000);
    expect(ok, isTrue);
    expect(s.pendingSegments.value, 1);
    expect(s.pendingBytes.value, 16);

    final files = Directory('${tmp.path}/wal').listSync().whereType<File>();
    expect(files.length, 1);
    expect(files.first.path, contains('wal_001751800000_'));
    expect(await files.first.readAsBytes(), body(0xAB));
  });

  test('uploadPending posts the body with the filename epoch and '
      'deletes on 200', () async {
    final requests = <http.Request>[];
    final s = store = makeStore(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('', 200);
      }),
    );
    await s.init();
    await s.writeSegment(body(0x01), 1751800000);
    await s.writeSegment(body(0x02), 1751800100);

    await s.uploadPending();

    expect(requests.length, 2);
    // Oldest first.
    expect(requests[0].headers['X-Timestamp-Start'], '1751800000');
    expect(requests[1].headers['X-Timestamp-Start'], '1751800100');
    expect(requests[0].bodyBytes, body(0x01));
    expect(requests[0].url.queryParameters['token'], 'secret');
    expect(requests[0].headers['X-Frame-Format'], 'length-prefixed');
    expect(requests[0].headers['X-Frame-Header'], 'none');
    expect(s.pendingSegments.value, 0);
    expect(s.pendingBytes.value, 0);
  });

  test('uploadPending keeps the file when the server rejects it', () async {
    final s = store = makeStore(
      client: MockClient((_) async => http.Response('nope', 401)),
    );
    await s.init();
    await s.writeSegment(body(0x01), 1751800000);

    await s.uploadPending();

    // 4xx is permanent for this payload right now (bad token etc.) —
    // the segment must stay on disk for a later retry.
    expect(s.pendingSegments.value, 1);
  });

  test('cap evicts oldest segments first', () async {
    final s = store = makeStore(maxTotalBytes: 40);
    await s.init();
    await s.writeSegment(body(0x01), 1751800000); // 16 B
    await s.writeSegment(body(0x02), 1751800100); // 32 B
    await s.writeSegment(body(0x03), 1751800200); // 48 B → evict oldest

    expect(s.pendingSegments.value, 2);
    final names = Directory(
      '${tmp.path}/wal',
    ).listSync().whereType<File>().map((f) => f.path).toList();
    expect(names.any((p) => p.contains('001751800000')), isFalse);
    expect(names.any((p) => p.contains('001751800200')), isTrue);
  });

  test('init on a fresh directory reports leftover segments', () async {
    final s1 = makeStore();
    await s1.init();
    await s1.writeSegment(body(0x01), 1751800000);
    s1.dispose();

    final s2 = store = makeStore();
    await s2.init();
    expect(s2.pendingSegments.value, 1);
    expect(s2.pendingBytes.value, 16);
  });
}
