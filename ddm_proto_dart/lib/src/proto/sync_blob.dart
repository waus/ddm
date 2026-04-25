import 'dart:async';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/envelope.dart';
import 'package:ddm_proto_dart/src/proto/message_types.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';

typedef PowProofVerifier = FutureOr<bool> Function({
  required Uint8List modulus,
  required Uint8List input,
  required int difficulty,
  required Uint8List y,
  required Uint8List pi,
});

SyncBlobId deriveSyncBlobId({
  required StreamId streamId,
  required Uint8List blobPayload,
}) {
  final sum = sha256Bytes(blobPayload);
  final out = Uint8List(syncBlobIdSize);
  final stream = streamId.toBytes();
  out.setRange(0, 4, stream);
  out.setRange(4, syncBlobIdSize, sum);
  return SyncBlobId(out);
}

Future<({SyncBlobId id, EncryptedMessage encrypted})> parseAndValidateBlob({
  required Uint8List blobPayload,
  required ConfigV1Core currentConfig,
  required int currentUnixSeconds,
  required PowProofVerifier verifyPow,
}) async {
  if (blobPayload.length > maxPowEnvelopeBytes) {
    throw FormatException(
      'pow envelope exceeds limit: got ${blobPayload.length} bytes, max $maxPowEnvelopeBytes',
    );
  }

  final envelope = PowEnvelope.fromBytes(blobPayload);
  if (!bytesEqual(envelope.toBytes(), blobPayload)) {
    throw const FormatException(
      'pow envelope must use canonical cbor encoding',
    );
  }
  if (envelope.version != powEnvelopeVersionV1) {
    throw FormatException(
      'unsupported pow envelope version: ${envelope.version}',
    );
  }
  if (envelope.algorithm != PowAlgorithm.vdfRsa) {
    throw FormatException(
      'unsupported pow algorithm: ${envelope.algorithm.code}',
    );
  }
  if (envelope.object.isEmpty) {
    throw const FormatException('pow envelope object must not be empty');
  }

  final encrypted = EncryptedMessage.fromBytes(envelope.object);
  if (!bytesEqual(encrypted.toBytes(), envelope.object)) {
    throw const FormatException(
      'encrypted message object must use canonical cbor encoding',
    );
  }
  if (encrypted.version != encryptedMessageVersionV1) {
    throw FormatException(
      'unsupported encrypted message version: ${encrypted.version}',
    );
  }
  if (encrypted.payload.isEmpty) {
    throw const FormatException('encrypted payload must not be empty');
  }
  if (encrypted.ttl <= 0) {
    throw const FormatException('encrypted ttl must be positive');
  }
  if (encrypted.expiresTime < currentUnixSeconds) {
    throw const FormatException('encrypted messages is expired');
  }
  final maxExpiresAt = currentUnixSeconds + encrypted.ttl + 2;
  if (encrypted.expiresTime > maxExpiresAt) {
    throw const FormatException('expires_time exceeds ttl-bound lifetime');
  }

  final expectedDifficulty = calculateDifficulty(
    base: currentConfig.powBaseTarget,
    scaleDivisor: currentConfig.powScaleDivisor,
    ttlSeconds: encrypted.ttl,
    payloadBytes: envelope.object.length,
  );

  final valid = await verifyPow(
    modulus: currentConfig.powModulus,
    input: encrypted.powInputHash(),
    difficulty: expectedDifficulty,
    y: envelope.y,
    pi: envelope.pi,
  );
  if (!valid) {
    throw FormatException(
      'vdf proof does not satisfy difficulty $expectedDifficulty',
    );
  }

  final id = deriveSyncBlobId(
    streamId: encrypted.streamNumber,
    blobPayload: blobPayload,
  );
  return (id: id, encrypted: encrypted);
}

int calculateDifficulty({
  required int base,
  required int scaleDivisor,
  required int ttlSeconds,
  required int payloadBytes,
}) {
  const int minTtlSeconds = 3600;
  const int perObjectOverheadByte = 1024;
  const int maxDifficulty = 0x7fffffffffffffff;

  final effectiveTtl = ttlSeconds < minTtlSeconds ? minTtlSeconds : ttlSeconds;
  final effectiveLength =
      (payloadBytes < 0 ? 0 : payloadBytes) + perObjectOverheadByte;

  final rawA = _mulClamp(base, effectiveTtl, maxDifficulty);
  final raw = _mulClamp(rawA, effectiveLength, maxDifficulty);

  if (raw == 0) {
    return 0;
  }
  if (scaleDivisor <= 1) {
    return raw;
  }
  final scaled = raw ~/ scaleDivisor;
  return scaled == 0 ? 1 : scaled;
}

int _mulClamp(int x, int y, int max) {
  if (x == 0 || y == 0) {
    return 0;
  }
  if (x > max ~/ y) {
    return max;
  }
  return x * y;
}
