import 'dart:typed_data';

/// Single-byte storage response codes sent by the Omi firmware.
///
/// Mirrored from BasedHardware/omi `storage_sync.dart:443-468` and
/// `sdcard_wal_sync.dart:283-306`: 0 = ack ("good to go"), 3 = bad file
/// size, 4 = empty file, 100 (0x64) = end of file. No other codes are
/// defined by the firmware.
abstract final class SdResponseCode {
  static const int ok = 0;
  static const int badFileSize = 3;
  static const int emptyFile = 4;
  static const int endOfFile = 100;
}

/// Which storage read protocol the connected firmware speaks.
///
/// Multi-file (fw 3.0.17+): data notifications are
/// `[timestamp:4 BE][batch of [size:1][frame:size]...]`.
/// Legacy (fw < 3.0.17): either an 83-byte single-frame shape
/// `[header:3][amount:1][frame:amount]` or a packed batch
/// `[size:1][frame:size]...` that may embed `0xFF` timestamp markers
/// followed by a 4-byte little-endian epoch (fw >= 3.0.16).
enum SdProtocol { multiFile, legacy }

/// Parsed content of one storage-characteristic notification.
class SdNotification {
  /// Set when the notification is a 1-byte command response.
  final int? responseCode;

  /// OPUS frames extracted from a data notification (no BLE header).
  final List<Uint8List> frames;

  /// Bytes this notification contributes toward the device-reported file
  /// size. Matches the official client's offset accounting: multi-file
  /// counts `length - 4` (timestamp prefix excluded), legacy counts 80
  /// for the 83-byte shape and the full length for packed batches.
  final int audioBytes;

  /// Epoch seconds carried by the notification (multi-file timestamp
  /// prefix or legacy 0xFF marker), null when absent or implausible.
  final int? epochSeconds;

  /// True when the notification is an echo of our own command write.
  final bool isEcho;

  const SdNotification({
    this.responseCode,
    this.frames = const [],
    this.audioBytes = 0,
    this.epochSeconds,
    this.isEcho = false,
  });

  bool get isResponse => responseCode != null;
}

/// Epochs before 2020-01-01 mean the device RTC was never set.
const int sdMinPlausibleEpoch = 1577836800;

int? _plausibleEpoch(int epoch) => epoch >= sdMinPlausibleEpoch ? epoch : null;

/// Parse one notification from the storage data characteristic (30295781).
SdNotification parseSdNotification(List<int> value, SdProtocol protocol) {
  if (value.isEmpty) {
    return const SdNotification(isEcho: true);
  }
  if (value.length == 1) {
    return SdNotification(responseCode: value[0]);
  }

  if (protocol == SdProtocol.multiFile) {
    // Echo of our own CMD_READ_FILE write [0x11, idx, offset:4].
    if (value.length == 6 && value[0] == 0x11) {
      return const SdNotification(isEcho: true);
    }
    if (value.length <= 4) {
      return const SdNotification();
    }
    final epoch =
        (value[0] << 24) | (value[1] << 16) | (value[2] << 8) | value[3];
    final frames = _parsePackedFrames(value, 4).frames;
    return SdNotification(
      frames: frames,
      audioBytes: value.length - 4,
      epochSeconds: _plausibleEpoch(epoch),
    );
  }

  // Legacy protocol.
  // Echo of our own 6-byte command write [cmd, fileNum, offset:4].
  if (value.length == 6 &&
      (value[0] == 0x00 || value[0] == 0x01 || value[0] == 0x03)) {
    return const SdNotification(isEcho: true);
  }
  if (value.length == 83) {
    // [header:3][amount:1][frame:amount]
    final amount = value[3];
    if (amount == 0 || 4 + amount > value.length) {
      return const SdNotification();
    }
    return SdNotification(
      frames: [Uint8List.fromList(value.sublist(4, 4 + amount))],
      audioBytes: 80,
    );
  }
  final parsed = _parsePackedFrames(value, 0, legacyMarkers: true);
  return SdNotification(
    frames: parsed.frames,
    audioBytes: value.length,
    epochSeconds: parsed.epochSeconds == null
        ? null
        : _plausibleEpoch(parsed.epochSeconds!),
  );
}

class _PackedResult {
  final List<Uint8List> frames;
  final int? epochSeconds;
  const _PackedResult(this.frames, this.epochSeconds);
}

/// Parse a `[size:1][frame:size]...` batch starting at [start]. When
/// [legacyMarkers] is set, a `0xFF` size byte is a timestamp marker
/// followed by a 4-byte little-endian epoch (fw >= 3.0.16).
_PackedResult _parsePackedFrames(
  List<int> value,
  int start, {
  bool legacyMarkers = false,
}) {
  final frames = <Uint8List>[];
  int? epoch;
  var pos = start;
  while (pos < value.length) {
    final size = value[pos];
    if (legacyMarkers && size == 0xFF && pos + 4 < value.length) {
      epoch ??=
          value[pos + 1] |
          (value[pos + 2] << 8) |
          (value[pos + 3] << 16) |
          (value[pos + 4] << 24);
      pos += 5;
      continue;
    }
    pos++;
    if (size == 0 || pos + size > value.length) break;
    frames.add(Uint8List.fromList(value.sublist(pos, pos + size)));
    pos += size;
  }
  return _PackedResult(frames, epoch);
}

/// Encode frames as `[len:4 LE][frame]...` — the body format the
/// bridge's `POST /sdcard/upload` expects.
Uint8List encodeLengthPrefixedFrames(List<Uint8List> frames) {
  var totalSize = 0;
  for (final f in frames) {
    totalSize += 4 + f.length;
  }
  final result = Uint8List(totalSize);
  var offset = 0;
  for (final f in frames) {
    final len = f.length;
    result[offset] = len & 0xFF;
    result[offset + 1] = (len >> 8) & 0xFF;
    result[offset + 2] = (len >> 16) & 0xFF;
    result[offset + 3] = (len >> 24) & 0xFF;
    result.setRange(offset + 4, offset + 4 + len, f);
    offset += 4 + len;
  }
  return result;
}
