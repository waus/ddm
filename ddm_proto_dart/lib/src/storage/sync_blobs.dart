import 'sync_blob_store.dart';
export 'sync_blob_store.dart';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class SyncBlobsRepository implements SyncBlobStore, SyncDeliveryStore {
  SyncBlobsRepository(this._db);

  final Database _db;
  @override
  List<SyncBlobId> pendingOutgoing(int now, int limit, int replicas) => _db
      .select(
          '''SELECT q.blob_id FROM sync_outgoing q JOIN sync_blobs b ON b.blob_id=q.blob_id
WHERE b.expires_at > ? AND q.next_attempt <= ?
AND (SELECT COUNT(*) FROM sync_deliveries d WHERE d.blob_id=q.blob_id) < ?
ORDER BY q.next_attempt, q.blob_id LIMIT ?''', [now, now, replicas, limit])
      .map((r) => SyncBlobId(r['blob_id'] as Uint8List))
      .toList();
  @override
  List<String> outgoingPeers(SyncBlobId id) => _db
      .select(
          'SELECT peer_id FROM sync_deliveries WHERE blob_id=? ORDER BY peer_id',
          [id.toBytes()])
      .map((r) => r['peer_id'] as String)
      .toList();
  @override
  void markOutgoingAttempt(SyncBlobId id, int nextAttempt) {
    _db.execute('UPDATE sync_outgoing SET next_attempt=? WHERE blob_id=?',
        [nextAttempt, id.toBytes()]);
  }

  @override
  void confirmOutgoing(SyncBlobId id, String peer) {
    _db.execute(
        'INSERT OR IGNORE INTO sync_deliveries(blob_id,peer_id) VALUES (?,?)',
        [id.toBytes(), peer]);
  }

  @override
  bool insertSyncBlob(SyncBlobRecord blob) {
    _db.execute(
      '''
INSERT OR IGNORE INTO sync_blobs(
  blob_id, blob, source, expires_at
)
VALUES (?, ?, ?, ?);
''',
      <Object?>[
        blob.blobId.toBytes(),
        Uint8List.fromList(blob.blob),
        blob.source,
        blob.expiresAt,
      ],
    );

    final changed = _db.select('SELECT changes() AS n;');
    return asInt(changed.first['n'], 'sync blob rows affected') == 1;
  }

  @override
  SyncBlobRecord? getSyncBlobById(SyncBlobId blobId) {
    final rows = _db.select(
      '''
SELECT blob_id, blob, source, expires_at
FROM sync_blobs
WHERE blob_id = ?;
''',
      <Object?>[blobId.toBytes()],
    );

    if (rows.isEmpty) {
      return null;
    }
    return _scanSyncBlob(rows.first);
  }

  List<SyncBlobRecord> listSyncBlobsByStreamPrefix(String prefix) {
    final normalizedPrefix = StreamId.normalizePrefix(prefix);
    final rows = _db.select(
      '''
SELECT blob_id, blob, source, expires_at
FROM sync_blobs
ORDER BY blob_id ASC;
''',
    );

    final out = <SyncBlobRecord>[];
    for (final row in rows) {
      final blob = _scanSyncBlob(row);
      final streamBytes = blob.blobId.toBytes();
      final stream = (streamBytes[0] << 24) |
          (streamBytes[1] << 16) |
          (streamBytes[2] << 8) |
          streamBytes[3];
      final streamId = StreamId(stream);
      if (streamId.matchesPrefix(normalizedPrefix)) {
        out.add(blob);
      }
    }
    return out;
  }

  @override
  List<SyncBlobIndexRecord> listSyncBlobIndexRecords() {
    final rows = _db.select(
      '''
SELECT blob_id, expires_at
FROM sync_blobs;
''',
    );

    return rows.map((row) {
      final rawBlobId = asBytes(row['blob_id'], 'sync blob id');
      return SyncBlobIndexRecord(
        blobId: SyncBlobId(rawBlobId),
        expiresAt: asInt(row['expires_at'], 'sync blob expires_at'),
      );
    }).toList(growable: false);
  }

  @override
  int deleteExpiredSyncBlobs(int now) {
    if (now < 0 || now > 0xffffffff) {
      throw FormatException('sync blob now must fit uint32, got $now');
    }

    _db.execute(
      '''
DELETE FROM sync_blobs
WHERE expires_at <= ?;
''',
      <Object?>[now],
    );
    final changed = _db.select('SELECT changes() AS n;');
    return asInt(changed.first['n'], 'expired sync blob rows affected');
  }

  @override
  void deleteSyncBlobById(SyncBlobId blobId) {
    _db.execute(
      '''
DELETE FROM sync_blobs
WHERE blob_id = ?;
''',
      <Object?>[blobId.toBytes()],
    );
  }

  SyncBlobRecord _scanSyncBlob(Row row) {
    return SyncBlobRecord(
      blobId: SyncBlobId(asBytes(row['blob_id'], 'sync blob id')),
      blob: asBytes(row['blob'], 'sync blob blob'),
      source: asString(row['source'], 'sync blob source'),
      expiresAt: asInt(row['expires_at'], 'sync blob expires_at'),
    );
  }
}
