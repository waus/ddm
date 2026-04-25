import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ddm_proto_dart/src/proto/constants.dart';

Uint8List copyBytes(Uint8List input) => Uint8List.fromList(input);

bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

Uint8List parseHexBytes(
  String value, {
  required int expectedBytes,
  required String label,
}) {
  final normalized = value.trim().toLowerCase();
  if (normalized.length != expectedBytes * 2) {
    throw FormatException(
      '$label hex must be exactly ${expectedBytes * 2} chars',
    );
  }
  final out = Uint8List(expectedBytes);
  for (var i = 0; i < normalized.length; i += 2) {
    final hi = _hexNibble(normalized.codeUnitAt(i));
    final lo = _hexNibble(normalized.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) {
      throw FormatException('decode $label hex');
    }
    out[i ~/ 2] = (hi << 4) | lo;
  }
  return out;
}

String bytesToHex(Uint8List value) {
  final sb = StringBuffer();
  for (final b in value) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List sha256Bytes(Uint8List value) =>
    Uint8List.fromList(crypto.sha256.convert(value).bytes);

int _hexNibble(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  return -1;
}

String base32NoPaddingEncode(Uint8List bytes) {
  final sb = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      sb.write(base32Alphabet[(buffer >> bits) & 0x1f]);
    }
  }
  if (bits > 0) {
    sb.write(base32Alphabet[(buffer << (5 - bits)) & 0x1f]);
  }
  return sb.toString();
}

Uint8List base32NoPaddingDecode(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) {
    return Uint8List(0);
  }

  var buffer = 0;
  var bits = 0;
  final out = <int>[];
  for (final code in normalized.codeUnits) {
    final idx = base32Alphabet.indexOf(String.fromCharCode(code));
    if (idx < 0) {
      throw const FormatException('invalid base32 value');
    }
    buffer = (buffer << 5) | idx;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }

  if (bits > 0 && ((buffer & ((1 << bits) - 1)) != 0)) {
    throw const FormatException('invalid base32 trailing bits');
  }

  return Uint8List.fromList(out);
}
