import 'dart:typed_data';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';

final class SyncBlobRecord {
  SyncBlobRecord({
    required this.blobId,
    required Uint8List blob,
    required this.source,
    required this.expiresAt,
  }) : blob = Uint8List.fromList(blob) {
    if (source.trim().isEmpty) {
      throw FormatException('sync blob source must not be empty');
    }
    if (expiresAt < 0 || expiresAt > 0xffffffff) {
      throw FormatException(
        'sync blob expires_at must fit uint32, got $expiresAt',
      );
    }
  }

  final SyncBlobId blobId;
  final Uint8List blob;
  final String source;
  final int expiresAt;
}

final class SyncBlobIndexRecord {
  const SyncBlobIndexRecord({required this.blobId, required this.expiresAt});

  final SyncBlobId blobId;
  final int expiresAt;
}

abstract interface class SyncBlobStore {
  bool insertSyncBlob(SyncBlobRecord blob);
  SyncBlobRecord? getSyncBlobById(SyncBlobId id);
  List<SyncBlobIndexRecord> listSyncBlobIndexRecords();
  int deleteExpiredSyncBlobs(int now);
  void deleteSyncBlobById(SyncBlobId id);
}

abstract interface class SyncDeliveryStore {
  List<SyncBlobId> pendingOutgoing(int now, int limit, int replicas);
  List<String> outgoingPeers(SyncBlobId id);
  void markOutgoingAttempt(SyncBlobId id, int nextAttempt);
  void confirmOutgoing(SyncBlobId id, String peer);
}
