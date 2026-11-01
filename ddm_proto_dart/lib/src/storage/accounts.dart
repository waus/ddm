import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/storage/storage_clock.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class AccountInsert {
  AccountInsert({
    required this.name,
    required this.address,
    required this.publicKey,
    required this.privateKey,
    required this.streamId,
    this.createdAt,
  });

  final String name;
  final String address;
  final Uint8List publicKey;
  final Uint8List privateKey;
  final StreamId streamId;
  final DateTime? createdAt;
}

final class AccountRecord {
  AccountRecord({
    required this.id,
    required this.name,
    required this.address,
    required Uint8List publicKey,
    required Uint8List privateKey,
    required this.streamId,
    required DateTime createdAt,
  })  : publicKey = Uint8List.fromList(publicKey),
        privateKey = Uint8List.fromList(privateKey),
        createdAt = createdAt.toUtc();

  final int id;
  final String name;
  final String address;
  final Uint8List publicKey;
  final Uint8List privateKey;
  final StreamId streamId;
  final DateTime createdAt;
}

final class AccountNameExistsException implements Exception {
  const AccountNameExistsException();

  @override
  String toString() => 'account name already exists';
}

final class AccountsRepository {
  AccountsRepository(this._db, this._nowUtc);

  final Database _db;
  final UtcNow _nowUtc;

  AccountRecord createAccount(AccountInsert input) {
    final name = input.name.trim();
    if (name.isEmpty) {
      throw FormatException('account name must not be empty');
    }

    final address = input.address.trim();
    if (address.isEmpty) {
      throw FormatException('account address must not be empty');
    }
    if (input.publicKey.isEmpty) {
      throw FormatException('account public key must not be empty');
    }
    if (input.privateKey.isEmpty) {
      throw FormatException('account private key must not be empty');
    }
    if (input.streamId.toUint32() == 0) {
      throw FormatException('account stream id must not be empty');
    }

    final createdAt = (input.createdAt ?? _nowUtc()).toUtc();

    if (_accountNameExists(name)) {
      throw const AccountNameExistsException();
    }

    try {
      _db.execute(
        '''
INSERT INTO accounts(name, address, public_key, private_key, stream_id, created_at)
VALUES(?, ?, ?, ?, ?, ?);
''',
        <Object?>[
          name,
          address,
          Uint8List.fromList(input.publicKey),
          Uint8List.fromList(input.privateKey),
          input.streamId.toUint32(),
          formatStoredTime(createdAt),
        ],
      );
    } on SqliteException catch (error) {
      final lowered = error.message.toLowerCase();
      if (lowered.contains('unique constraint failed: accounts.name')) {
        throw const AccountNameExistsException();
      }
      rethrow;
    }

    final insertedId = _db.lastInsertRowId;
    return AccountRecord(
      id: insertedId,
      name: name,
      address: address,
      publicKey: input.publicKey,
      privateKey: input.privateKey,
      streamId: input.streamId,
      createdAt: createdAt,
    );
  }

  List<AccountRecord> listAccounts() {
    final rows = _db.select(
      '''
SELECT id, name, address, public_key, private_key, stream_id, created_at
FROM accounts
ORDER BY id ASC;
''',
    );
    return rows.map(_scanAccount).toList(growable: false);
  }

  AccountRecord? getAccountByAddress(String address) {
    final rows = _db.select(
      '''
SELECT id, name, address, public_key, private_key, stream_id, created_at
FROM accounts
WHERE address = ?;
''',
      <Object?>[address],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _scanAccount(rows.first);
  }

  AccountRecord? getAccountByName(String name) {
    final rows = _db.select(
      '''
SELECT id, name, address, public_key, private_key, stream_id, created_at
FROM accounts
WHERE name = ? COLLATE NOCASE;
''',
      <Object?>[name.trim()],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _scanAccount(rows.first);
  }

  List<AccountRecord> listAccountsByStreamId(StreamId streamId) {
    final rows = _db.select(
      '''
SELECT id, name, address, public_key, private_key, stream_id, created_at
FROM accounts
WHERE stream_id = ?
ORDER BY id ASC;
''',
      <Object?>[streamId.toUint32()],
    );
    return rows.map(_scanAccount).toList(growable: false);
  }

  bool _accountNameExists(String name) {
    final rows = _db.select(
      'SELECT 1 FROM accounts WHERE name = ? COLLATE NOCASE LIMIT 1;',
      <Object?>[name.trim()],
    );
    return rows.isNotEmpty;
  }

  AccountRecord _scanAccount(Row row) {
    final streamId = asInt(row['stream_id'], 'account stream_id');
    return AccountRecord(
      id: asInt(row['id'], 'account id'),
      name: asString(row['name'], 'account name'),
      address: asString(row['address'], 'account address'),
      publicKey: asBytes(row['public_key'], 'account public_key'),
      privateKey: asBytes(row['private_key'], 'account private_key'),
      streamId: StreamId(streamId),
      createdAt: parseStoredTime(
        asString(row['created_at'], 'account created_at'),
        'account created_at',
      ),
    );
  }
}
