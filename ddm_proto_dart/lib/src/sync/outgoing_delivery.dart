import '../proto/stream.dart';
import '../proto/sync_blob.dart';
import '../proto/sync_source.dart';
import '../proto/sync_errors.dart';
import '../storage/sync_blob_store.dart';
import '../storage/storage_clock.dart';
import 'sync/sync_options.dart';
import 'constants.dart';

final class OutgoingDelivery {
  OutgoingDelivery(
      {required this.queue,
      required this.blobs,
      required this.discovery,
      required this.nowUtc});
  final SyncDeliveryStore queue;
  final SyncBlobStore blobs;
  final ShardDiscovery discovery;
  final UtcNow nowUtc;
  Future<void> run({bool Function()? isCancelled}) async {
    final now = nowUtc().millisecondsSinceEpoch ~/ 1000;
    for (final id in queue.pendingOutgoing(
        now, outgoingBatchSize, outgoingReplicaTarget)) {
      if (isCancelled?.call() ?? false) return;
      queue.markOutgoingAttempt(id, now + outgoingRetryInterval.inSeconds);
      final receipts = queue.outgoingPeers(id).toSet();
      final blob = blobs.getSyncBlobById(id);
      if (blob == null) continue;
      final stream = StreamId.parseHex(id.toHex().substring(0, 8));
      final peers = await discovery.findShardPeers(stream);
      try {
        for (final peer in peers) {
          if (isCancelled?.call() ?? false) return;
          final key = peer is PeerIdentitySource
              ? (peer as PeerIdentitySource).peerIdentity
              : peer.id;
          if (receipts.contains(key)) continue;
          try {
            final state = await readSyncState(peer);
            if (!state.coverage.any((p) => p.matches(stream))) continue;
            final existing = await peer.getSyncBlobs([id]);
            if (existing.length != 1) {
              throw SyncSourceException.invalidResponse('expected one blob');
            }
            if (existing.single == null) {
              await peer.push(SyncBlob(id: id, payload: blob.blob));
            } else if (existing.single!.id != id ||
                deriveSyncBlobId(
                        streamId: stream,
                        blobPayload: existing.single!.payload) !=
                    id) {
              throw SyncSourceException.invalidResponse(
                  'invalid existing blob');
            }
            if (isCancelled?.call() ?? false) return;
            queue.confirmOutgoing(id, key);
            receipts.add(key);
            if (receipts.length >= outgoingReplicaTarget) break;
          } on SyncSourceException {
            continue;
          }
        }
      } finally {
        for (final peer in peers) {
          peer.stop();
        }
      }
    }
  }
}
