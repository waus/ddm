import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ddm_proto_dart/src/runtime/runtime/runtime_options.dart';
import 'package:ddm_proto_dart/src/storage/messages.dart';

MessageId generateRuntimeMessageId({
  required String sender,
  required String recipient,
  required DateTime createdAt,
  required RandomBytes randomBytes,
}) {
  final input = <int>[
    ...sender.codeUnits,
    ...recipient.codeUnits,
    ...createdAt.toUtc().toIso8601String().codeUnits,
    ...randomBytes(16),
  ];
  final digest = crypto.sha256.convert(input).bytes;
  return MessageId(Uint8List.fromList(digest.sublist(0, 16)));
}

int drawRandomIntInclusive(
  int min,
  int max,
  RandomBytes randomBytes,
) {
  if (min > max) {
    throw FormatException('min $min must be <= max $max');
  }
  final span = BigInt.from(max - min + 1);
  final byteLength = (span.bitLength + 7) >> 3;
  while (true) {
    var value = BigInt.zero;
    final bytes = randomBytes(byteLength);
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    if (value < span) {
      return min + value.toInt();
    }
  }
}
