import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';
import 'package:ddm_proto_dart/src/proto/message_types.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';

final class EncryptedMessage {
  EncryptedMessage({
    required this.version,
    required this.ttl,
    required this.expiresTime,
    required this.streamNumber,
    required Uint8List payload,
  }) : payload = copyBytes(payload);

  final int version;
  final int ttl;
  final int expiresTime;
  final StreamId streamNumber;
  final Uint8List payload;

  Uint8List toBytes() {
    return ddmCborCodec.encode(<Object?>[
      version,
      ttl,
      expiresTime,
      streamNumber.toUint32(),
      copyBytes(payload),
    ]);
  }

  Uint8List powInputHash() => sha256Bytes(toBytes());

  static EncryptedMessage fromBytes(Uint8List data) {
    if (data.length > maxEncryptedMessageBytes) {
      throw FormatException(
        'encrypted message exceeds limit: got ${data.length} bytes, max $maxEncryptedMessageBytes',
      );
    }
    final decoded = ddmCborCodec.decode(data);
    if (decoded is! List<Object?> || decoded.length != 5) {
      throw const FormatException('decode encrypted message');
    }
    final version = decoded[0];
    final ttl = decoded[1];
    final expiresTime = decoded[2];
    final streamNumber = decoded[3];
    final payload = decoded[4];
    if (version is! int ||
        ttl is! int ||
        expiresTime is! int ||
        streamNumber is! int ||
        payload is! Uint8List) {
      throw const FormatException('decode encrypted message');
    }

    return EncryptedMessage(
      version: version,
      ttl: ttl,
      expiresTime: expiresTime,
      streamNumber: StreamId(streamNumber),
      payload: payload,
    );
  }
}

final class PowEnvelope {
  PowEnvelope({
    required this.version,
    required this.algorithm,
    required Uint8List y,
    required Uint8List pi,
    required Uint8List object,
  })  : y = _fixed(y, powProofComponentSize, 'pow y'),
        pi = _fixed(pi, powProofComponentSize, 'pow pi'),
        object = copyBytes(object);

  final int version;
  final PowAlgorithm algorithm;
  final Uint8List y;
  final Uint8List pi;
  final Uint8List object;

  Uint8List toBytes() {
    return ddmCborCodec.encode(<Object?>[
      version,
      algorithm.code,
      copyBytes(y),
      copyBytes(pi),
      copyBytes(object),
    ]);
  }

  static PowEnvelope fromBytes(Uint8List data) {
    if (data.length > maxPowEnvelopeBytes) {
      throw FormatException(
        'pow envelope exceeds limit: got ${data.length} bytes, max $maxPowEnvelopeBytes',
      );
    }
    final decoded = ddmCborCodec.decode(data);
    if (decoded is! List<Object?> || decoded.length != 5) {
      throw const FormatException('decode pow envelope');
    }

    final version = decoded[0];
    final algorithm = decoded[1];
    final y = decoded[2];
    final pi = decoded[3];
    final object = decoded[4];
    if (version is! int ||
        algorithm is! int ||
        y is! Uint8List ||
        pi is! Uint8List ||
        object is! Uint8List) {
      throw const FormatException('decode pow envelope');
    }

    return PowEnvelope(
      version: version,
      algorithm: PowAlgorithm.fromCode(algorithm),
      y: y,
      pi: pi,
      object: object,
    );
  }
}

Uint8List _fixed(Uint8List value, int expected, String label) {
  if (value.length != expected) {
    throw FormatException(
      '$label must be $expected bytes, got ${value.length}',
    );
  }
  return copyBytes(value);
}
