part of '../sync.dart';

Future<bool> importLeaf({
  required MessageIndexLeaf leaf,
  required SyncSource from,
  required SyncSource to,
  required BlobValidator validateBlob,
}) async {
  final results = await from.getSyncBlobs(<SyncBlobId>[leaf.syncBlobId]);
  if (results.length != 1) {
    throw FormatException(
      'sync source ${from.id} returned ${results.length} sync blobs, want 1',
    );
  }
  final blob = results.single;
  if (blob == null) {
    throw SyncSourceException.unavailable(
      'sync source ${from.id} returned nil sync blob ${leaf.syncBlobId.toHex()}',
    );
  }
  if (blob.id != leaf.syncBlobId) {
    throw FormatException(
      'sync source ${from.id} returned sync blob ${blob.id.toHex()}, want ${leaf.syncBlobId.toHex()}',
    );
  }

  ValidatedBlob validated;
  try {
    validated = await validateBlob(blob.payload);
  } on ExpiredSyncBlob {
    return false;
  }
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
  if (to is _ValidatedBlobSink) {
    final inserted = await (to as _ValidatedBlobSink)
        ._storeValidatedBlob(blob, validated.encrypted);
    if (inserted && from is RegisteredSource) {
      from.increaseRatingConst(ratingGoodBlobReceived);
    }
    return inserted;
  } else {
    await to.push(blob);
  }
  return true;
}

abstract interface class _ValidatedBlobSink {
  Future<bool> _storeValidatedBlob(SyncBlob blob, EncryptedMessage encrypted);
}
