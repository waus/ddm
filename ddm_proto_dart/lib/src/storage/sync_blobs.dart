import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

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

final class SyncBlobsRepository {
  SyncBlobsRepository(this._db);

  final Database _db;

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
