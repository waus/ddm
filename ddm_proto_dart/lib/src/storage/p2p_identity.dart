import 'dart:typed_data';

import 'package:ddm_proto_dart/src/storage/storage_clock.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class P2pIdentityRepository {
  P2pIdentityRepository(this._db, this._nowUtc);

  final Database _db;
  final UtcNow _nowUtc;

  Uint8List? getPrivateKey() {
    final rows = _db.select(
      '''
SELECT private_key
FROM p2p_identity
WHERE singleton = 1;
''',
    );

    if (rows.isEmpty) {
      return null;
    }

    final privateKey = asBytes(rows.first['private_key'], 'p2p private key');
    if (privateKey.isEmpty) {
      throw FormatException('p2p private key must not be empty');
    }
    return privateKey;
  }

  void upsertPrivateKey(Uint8List privateKey) {
    if (privateKey.isEmpty) {
      throw FormatException('p2p private key must not be empty');
    }

    final now = formatStoredTime(_nowUtc());
    _db.execute(
      '''
INSERT INTO p2p_identity(singleton, private_key, created_at, updated_at)
VALUES(1, ?, ?, ?)
ON CONFLICT(singleton) DO UPDATE SET
  private_key = excluded.private_key,
  updated_at = excluded.updated_at;
''',
      <Object?>[Uint8List.fromList(privateKey), now, now],
    );
  }
}
