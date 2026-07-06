import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Disk-backed WAL for audio that could not be delivered live.
///
/// Each segment file contains `[len:4 LE][OPUS frame]...` — exactly the
/// body `POST /sdcard/upload` expects (frames carry no BLE header), so
/// recovery is: read file, POST it, delete on HTTP 200. Segment start
/// time is encoded in the filename and sent as `X-Timestamp-Start`.
///
/// Files survive app kills and crashes; they are only deleted after the
/// server accepted them (or when the total size cap evicts the oldest).
class WalStore {
  static const Duration _httpTimeout = Duration(seconds: 60);
  static const int _httpMaxAttempts = 3;
  static const Duration _retryDelay = Duration(minutes: 5);

  final String uploadUrl;
  final String authToken;
  final String deviceId;

  /// Total disk budget; oldest segments are evicted beyond this.
  final int maxTotalBytes;

  final http.Client _client;
  final Directory? _overrideDir;

  Directory? _dir;
  bool _uploading = false;
  bool _disposed = false;
  Timer? _retryTimer;

  final ValueNotifier<int> pendingBytes = ValueNotifier<int>(0);
  final ValueNotifier<int> pendingSegments = ValueNotifier<int>(0);

  WalStore({
    required this.uploadUrl,
    required this.authToken,
    required this.deviceId,
    this.maxTotalBytes = 500 * 1024 * 1024,
    http.Client? client,
    Directory? directory,
  }) : _client = client ?? http.Client(),
       _overrideDir = directory;

  Future<void> init() async {
    final dir =
        _overrideDir ??
        Directory('${(await getApplicationDocumentsDirectory()).path}/wal');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    await _enforceCap();
    await _refreshStats();
  }

  /// Persist one upload-ready segment body. Returns false when the
  /// write failed (disk full etc.) so the caller can fall back to its
  /// in-memory buffer.
  Future<bool> writeSegment(Uint8List body, int startEpochSeconds) async {
    final dir = _dir;
    if (dir == null || _disposed || body.isEmpty) return false;
    try {
      final epoch = startEpochSeconds.toString().padLeft(12, '0');
      var counter = DateTime.now().millisecondsSinceEpoch;
      File file;
      do {
        file = File('${dir.path}/wal_${epoch}_$counter.bin');
        counter++;
      } while (await file.exists());
      await file.writeAsBytes(body, flush: true);
      await _enforceCap();
      await _refreshStats();
      debugPrint('[WAL] wrote segment ${file.path} (${body.length}B)');
      return true;
    } catch (e) {
      debugPrint('[WAL] segment write failed: $e');
      return false;
    }
  }

  /// Upload all pending segments oldest-first; delete each after the
  /// server accepted it. Safe to call from anywhere — concurrent calls
  /// and repeat triggers are no-ops while an upload is running.
  Future<void> uploadPending() async {
    if (_uploading || _disposed || _dir == null) return;
    _uploading = true;
    try {
      final files = await _segmentFiles();
      if (files.isEmpty) return;
      debugPrint('[WAL] uploading ${files.length} pending segments');
      for (final file in files) {
        if (_disposed) return;
        final ok = await _postSegment(file);
        if (!ok) {
          _scheduleRetry();
          return;
        }
        try {
          await file.delete();
        } catch (_) {}
        await _refreshStats();
      }
      debugPrint('[WAL] all segments uploaded');
    } finally {
      _uploading = false;
    }
  }

  Future<bool> _postSegment(File file) async {
    final Uint8List body;
    try {
      body = await file.readAsBytes();
    } catch (e) {
      debugPrint('[WAL] unreadable segment ${file.path}: $e');
      try {
        await file.delete();
      } catch (_) {}
      return true; // nothing recoverable here — move on
    }
    if (body.isEmpty) {
      try {
        await file.delete();
      } catch (_) {}
      return true;
    }

    final timestampStart =
        _epochFromName(file.path) ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse('$uploadUrl?token=$authToken');

    for (var attempt = 1; attempt <= _httpMaxAttempts; attempt++) {
      if (_disposed) return false;
      try {
        final response = await _client
            .post(
              uri,
              headers: {
                'Content-Type': 'application/octet-stream',
                'X-Codec': 'opus',
                'X-Sample-Rate': '16000',
                'X-Channels': '1',
                'X-Frame-Format': 'length-prefixed',
                'X-Frame-Header': 'none',
                'X-Device-Id': deviceId,
                'X-Timestamp-Start': '$timestampStart',
                'X-Sync-Method': 'wal',
                'Authorization': 'Bearer $authToken',
              },
              body: body,
            )
            .timeout(_httpTimeout);
        if (response.statusCode == 200) return true;
        debugPrint('[WAL] upload ${file.path}: HTTP ${response.statusCode}');
        if (response.statusCode >= 400 && response.statusCode < 500) {
          // Auth/config problem — keep the file, stop for now.
          return false;
        }
      } catch (e) {
        debugPrint('[WAL] upload attempt $attempt failed: $e');
      }
      if (attempt < _httpMaxAttempts) {
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
    return false;
  }

  Future<List<File>> _segmentFiles() async {
    final dir = _dir;
    if (dir == null) return [];
    final files = <File>[];
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.bin')) {
        files.add(entry);
      }
    }
    // Epoch in the name is zero-padded, so lexicographic == chronological.
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  int? _epochFromName(String path) {
    final match = RegExp(r'wal_(\d+)_\d+\.bin$').firstMatch(path);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<void> _enforceCap() async {
    final files = await _segmentFiles();
    var total = 0;
    final sizes = <File, int>{};
    for (final f in files) {
      try {
        sizes[f] = await f.length();
        total += sizes[f]!;
      } catch (_) {}
    }
    for (final f in files) {
      if (total <= maxTotalBytes) break;
      try {
        await f.delete();
        total -= sizes[f] ?? 0;
        debugPrint('[WAL] cap eviction: ${f.path}');
      } catch (_) {}
    }
  }

  Future<void> _refreshStats() async {
    final files = await _segmentFiles();
    var total = 0;
    for (final f in files) {
      try {
        total += await f.length();
      } catch (_) {}
    }
    pendingSegments.value = files.length;
    pendingBytes.value = total;
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, uploadPending);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _client.close();
    pendingBytes.dispose();
    pendingSegments.dispose();
  }
}
