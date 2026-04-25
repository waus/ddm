import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';

final class StreamId {
  const StreamId(this.value);

  final int value;

  int toUint32() => value & 0xffffffff;

  String toHex() => toUint32().toRadixString(16).padLeft(8, '0');

  bool matchesPrefix(String prefix) {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    return toHex().startsWith(trimmed.toLowerCase());
  }

  Uint8List toBytes() {
    final out = Uint8List(4);
    out[0] = (toUint32() >> 24) & 0xff;
    out[1] = (toUint32() >> 16) & 0xff;
    out[2] = (toUint32() >> 8) & 0xff;
    out[3] = toUint32() & 0xff;
    return out;
  }

  static StreamId parseHex(String value) {
    final raw = parseHexBytes(
      value.trim(),
      expectedBytes: 4,
      label: 'stream id',
    );
    final number = (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
    return StreamId(number);
  }

  static String normalizePrefix(String prefix) {
    final normalized = prefix.trim().toLowerCase();
    if (normalized.isEmpty) {
      return normalized;
    }
    if (normalized.length > streamPrefixMaxLength) {
      throw const FormatException('stream prefix must be at most 8 hex chars');
    }
    final valid = streamHexPrefixRe.hasMatch(normalized);
    if (!valid) {
      throw const FormatException(
        'stream prefix must contain only hex chars [0-9a-f]',
      );
    }
    return normalized;
  }
}
