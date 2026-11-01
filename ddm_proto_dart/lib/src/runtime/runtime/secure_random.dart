import 'dart:math';
import 'dart:typed_data';

final Random _secureRandom = Random.secure();

Uint8List secureRandomBytes(int length) {
  if (length < 0) {
    throw FormatException('random byte length must be non-negative');
  }
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

int secureRandomBigInt(BigInt exclusiveMax) {
  if (exclusiveMax <= BigInt.zero) {
    throw const FormatException('exclusive max must be positive');
  }

  final byteLength = (exclusiveMax.bitLength + 7) >> 3;
  while (true) {
    var value = BigInt.zero;
    for (var i = 0; i < byteLength; i++) {
      value = (value << 8) | BigInt.from(_secureRandom.nextInt(256));
    }
    if (value < exclusiveMax) {
      return value.toInt();
    }
  }
}
