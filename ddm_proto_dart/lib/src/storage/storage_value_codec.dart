import 'dart:typed_data';

String formatStoredTime(DateTime value) => value.toUtc().toIso8601String();

DateTime parseStoredTime(String raw, String label) {
  try {
    return DateTime.parse(raw).toUtc();
  } on FormatException catch (error) {
    throw FormatException('parse $label: ${error.message}');
  }
}

String asString(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be string');
  }
  return value;
}

int asInt(Object? value, String label) {
  if (value is int) {
    return value;
  }
  if (value is BigInt) {
    return value.toInt();
  }
  throw FormatException('$label must be integer');
}

double asDouble(Object? value, String label) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  throw FormatException('$label must be number');
}

Uint8List asBytes(Object? value, String label) {
  if (value is Uint8List) {
    return Uint8List.fromList(value);
  }
  if (value is List<int>) {
    return Uint8List.fromList(value);
  }
  throw FormatException('$label must be bytes');
}

Uint8List copyFixed(Uint8List bytes, int expected, String label) {
  if (bytes.length != expected) {
    throw FormatException(
        '$label must be $expected bytes, got ${bytes.length}');
  }
  return Uint8List.fromList(bytes);
}

Uint8List decodeHex(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.length.isOdd) {
    throw const FormatException('hex string length must be even');
  }
  final out = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < normalized.length; i += 2) {
    final byte = int.tryParse(normalized.substring(i, i + 2), radix: 16);
    if (byte == null) {
      throw FormatException('invalid hex at offset $i');
    }
    out[i ~/ 2] = byte;
  }
  return out;
}

bool bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}
