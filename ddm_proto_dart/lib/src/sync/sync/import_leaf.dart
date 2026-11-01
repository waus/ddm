part of '../sync.dart';

Future<void> importLeaf({
  required MessageIndexLeaf leaf,
  required SyncSource from,
  required SyncSource to,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
}) async {
  final results = await from.getSyncBlobs(<SyncBlobId>[leaf.syncBlobId]);
  if (results.length != 1) {
    throw FormatException(
      'sync source ${from.id} returned ${results.length} sync blobs, want 1',
    );
  }
  final blob = results.single;
  if (blob == null) {
    throw FormatException(
      'sync source ${from.id} returned nil sync blob ${leaf.syncBlobId.toHex()}',
    );
  }
  if (blob.id != leaf.syncBlobId) {
    throw FormatException(
      'sync source ${from.id} returned sync blob ${blob.id.toHex()}, want ${leaf.syncBlobId.toHex()}',
    );
  }

  final configTime = _syncBlobConfigTime(blob.payload);
  final validated = await parseAndValidateBlob(
    blobPayload: blob.payload,
    currentConfig: configs.configAtUnix(configTime),
    currentUnixSeconds: configTime,
    verifyPow: verifyPow,
  );
  if (validated.id != leaf.syncBlobId) {
    throw FormatException(
      'validated sync blob id ${validated.id.toHex()} does not match tree leaf ${leaf.syncBlobId.toHex()}',
    );
  }
  if (validated.encrypted.expiresTime != leaf.ttl) {
    throw FormatException(
      'sync blob ${validated.id.toHex()} ttl mismatch: tree=${leaf.ttl} blob=${validated.encrypted.expiresTime}',
    );
  }
  await to.push(
    blob,
    validationContext: ImportValidationContext(
      configs: configs,
      verifyPow: verifyPow,
    ),
  );
}

EncryptedMessage encryptedMessageFromPowEnvelope(Uint8List blobPayload) {
  final envelope = PowEnvelope.fromBytes(blobPayload);
  return EncryptedMessage.fromBytes(envelope.object);
}

int _syncBlobConfigTime(Uint8List blobPayload) {
  return encryptedConfigTimeUnix(parseSyncBlobPayload(blobPayload).encrypted);
}
