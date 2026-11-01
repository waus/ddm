import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class PeerRecord {
  PeerRecord({
    required this.id,
    required DateTime createdAt,
    required DateTime? lastOnlineAt,
    required this.rating,
  })  : createdAt = createdAt.toUtc(),
        lastOnlineAt = lastOnlineAt?.toUtc() {
    if (id.trim().isEmpty) {
      throw FormatException('peer id must not be empty');
    }
  }

  final String id;
  final DateTime createdAt;
  final DateTime? lastOnlineAt;
  final double rating;
}

final class PeersRepository {
  PeersRepository(this._db);

  final Database _db;

  void upsertPeers(List<PeerRecord> peers) {
    if (peers.isEmpty) {
      return;
    }

    _db.execute('BEGIN;');
    try {
      for (final peer in peers) {
        _db.execute(
          '''
INSERT INTO peers(id, created_at, last_online_at, rating)
VALUES (?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  last_online_at = excluded.last_online_at,
  rating = excluded.rating;
''',
          <Object?>[
            peer.id,
            formatStoredTime(peer.createdAt),
            peer.lastOnlineAt == null
                ? null
                : formatStoredTime(peer.lastOnlineAt!),
            peer.rating,
          ],
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  List<PeerRecord> listPeers() {
    final rows = _db.select(
      '''
SELECT id, created_at, last_online_at, rating
FROM peers
ORDER BY id ASC;
''',
    );
    return rows.map(_scanPeer).toList(growable: false);
  }

  int deletePeersLastOnlineBefore(DateTime cutoff) {
    _db.execute(
      '''
DELETE FROM peers
WHERE unixepoch(last_online_at) < unixepoch(?);
''',
      <Object?>[formatStoredTime(cutoff)],
    );
    final changed = _db.select('SELECT changes() AS n;');
    return asInt(changed.first['n'], 'stale peer rows affected');
  }

  PeerRecord _scanPeer(Row row) {
    final rawLastOnlineAt = row['last_online_at'];
    return PeerRecord(
      id: asString(row['id'], 'peer id'),
      createdAt: parseStoredTime(
        asString(row['created_at'], 'peer created_at'),
        'peer created_at',
      ),
      lastOnlineAt: rawLastOnlineAt == null
          ? null
          : parseStoredTime(
              asString(rawLastOnlineAt, 'peer last_online_at'),
              'peer last_online_at',
            ),
      rating: asDouble(row['rating'], 'peer rating'),
    );
  }
}
