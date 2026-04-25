import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/address.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/message_types.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/storage/constants.dart';
import 'package:sqlite3/sqlite3.dart';

typedef UtcNow = DateTime Function();

final class DdmSqliteStorage {
  DdmSqliteStorage._(this._db, UtcNow nowUtc)
      : accounts = AccountsRepository._(_db, nowUtc),
        configs = ConfigRepository._(_db, nowUtc),
        messages = MessagesRepository._(_db),
        syncBlobs = SyncBlobsRepository._(_db),
        p2pIdentity = P2pIdentityRepository._(_db, nowUtc),
        peers = PeersRepository._(_db);

  final Database _db;
  bool _closed = false;

  final AccountsRepository accounts;
  final ConfigRepository configs;
  final MessagesRepository messages;
  final SyncBlobsRepository syncBlobs;
  final P2pIdentityRepository p2pIdentity;
  final PeersRepository peers;

  static DdmSqliteStorage open(String dbPath, {UtcNow? nowUtc}) {
    final dbFile = File(dbPath);
    dbFile.parent.createSync(recursive: true);

    final db = sqlite3.open(dbPath);
    final now = nowUtc ?? _defaultUtcNow;
    try {
      _initSchema(db);
      final storage = DdmSqliteStorage._(db, now);
      storage.configs._ensureDefaultConfigRecord();
      return storage;
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _db.dispose();
  }

  static void _initSchema(Database db) {
    for (final statement in schemaStatements) {
      db.execute(statement);
    }
  }
}

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
  AccountsRepository._(this._db, this._nowUtc);

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
          _formatStoredTime(createdAt),
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
    final streamId = _asInt(row['stream_id'], 'account stream_id');
    return AccountRecord(
      id: _asInt(row['id'], 'account id'),
      name: _asString(row['name'], 'account name'),
      address: _asString(row['address'], 'account address'),
      publicKey: _asBytes(row['public_key'], 'account public_key'),
      privateKey: _asBytes(row['private_key'], 'account private_key'),
      streamId: StreamId(streamId),
      createdAt: _parseStoredTime(
        _asString(row['created_at'], 'account created_at'),
        'account created_at',
      ),
    );
  }
}

final class ConfigStoredRecord {
  ConfigStoredRecord({
    required this.seqNo,
    required DateTime activeFrom,
    required this.record,
  }) : activeFrom = activeFrom.toUtc();

  final int seqNo;
  final DateTime activeFrom;
  final ConfigRecord record;
}

final class ConfigRepository {
  ConfigRepository._(this._db, this._nowUtc);

  final Database _db;
  final UtcNow _nowUtc;

  static final ConfigStoredRecord defaultConfigRecord =
      _buildDefaultConfigRecord();

  void _ensureDefaultConfigRecord() {
    final record = defaultConfigRecord;
    _db.execute(
      '''
INSERT INTO config(seqno, active_from, version, payload, created_at)
SELECT ?, ?, ?, ?, ?
WHERE NOT EXISTS (SELECT 1 FROM config);
''',
      <Object?>[
        record.seqNo,
        _formatStoredTime(record.activeFrom),
        record.record.version,
        Uint8List.fromList(record.record.payload),
        _formatStoredTime(_nowUtc()),
      ],
    );
  }

  Future<void> upsertConfigRecord(ConfigStoredRecord record) async {
    final validated = await _validateStoredConfigRecord(record);

    _db.execute(
      '''
INSERT INTO config(seqno, active_from, version, payload, created_at)
VALUES(?, ?, ?, ?, ?)
ON CONFLICT(seqno) DO UPDATE SET
  active_from = excluded.active_from,
  version = excluded.version,
  payload = excluded.payload;
''',
      <Object?>[
        validated.seqNo,
        _formatStoredTime(validated.activeFrom),
        validated.record.version,
        Uint8List.fromList(validated.record.payload),
        _formatStoredTime(_nowUtc()),
      ],
    );
  }

  List<ConfigStoredRecord> listConfigRecords() {
    final rows = _db.select(
      '''
SELECT seqno, active_from, version, payload
FROM config
ORDER BY seqno ASC;
''',
    );
    return rows.map(_scanConfigRecord).toList(growable: false);
  }

  ConfigStoredRecord? getActiveConfigRecord(DateTime now) {
    final rows = _db.select(
      '''
SELECT seqno, active_from, version, payload
FROM config
WHERE active_from <= ?
ORDER BY seqno DESC
LIMIT 1;
''',
      <Object?>[_formatStoredTime(now.toUtc())],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _scanConfigRecord(rows.first);
  }

  ConfigStoredRecord _scanConfigRecord(Row row) {
    final seqNo = _asInt(row['seqno'], 'config seqno');
    final version = _asInt(row['version'], 'config version');
    if (seqNo < 0) {
      throw FormatException('config seqno must be >= 0, got $seqNo');
    }
    if (version < 0 || version > 255) {
      throw FormatException('config version must be in [0..255], got $version');
    }

    return ConfigStoredRecord(
      seqNo: seqNo,
      activeFrom: _parseStoredTime(
        _asString(row['active_from'], 'config active_from'),
        'config active_from',
      ),
      record: ConfigRecord(
        version: version,
        payload: _asBytes(row['payload'], 'config payload'),
      ),
    );
  }

  Future<ConfigStoredRecord> _validateStoredConfigRecord(
    ConfigStoredRecord record,
  ) async {
    if (record.seqNo < 0) {
      throw FormatException('seqno must be >= 0, got ${record.seqNo}');
    }
    if (record.activeFrom.millisecondsSinceEpoch == 0) {
      throw FormatException('active_from must not be zero');
    }
    if (record.record.payload.isEmpty) {
      throw FormatException('config payload must not be empty');
    }
    if (record.record.version != configRecordVersionV1) {
      throw FormatException(
        'unknown config record version ${record.record.version}; please update the client',
      );
    }

    final payload = ConfigV1Payload.fromBytes(record.record.payload);
    await payload.verifySignature(_defaultConfigAdminPublicKey);

    final payloadSeqNo = payload.core.seqNo;
    final payloadActiveFrom = DateTime.fromMillisecondsSinceEpoch(
      payload.core.activeFromUnix * 1000,
      isUtc: true,
    );

    if (payloadSeqNo != record.seqNo) {
      throw FormatException(
        'config seqno mismatch: payload=$payloadSeqNo arg=${record.seqNo}',
      );
    }
    if (payloadActiveFrom != record.activeFrom.toUtc()) {
      throw FormatException(
        'config active_from mismatch: payload=${_formatStoredTime(payloadActiveFrom)} arg=${_formatStoredTime(record.activeFrom.toUtc())}',
      );
    }

    return ConfigStoredRecord(
      seqNo: record.seqNo,
      activeFrom: record.activeFrom.toUtc(),
      record: ConfigRecord(
        version: record.record.version,
        payload: record.record.payload,
      ),
    );
  }
}

final Uint8List _defaultConfigAdminPublicKey = _decodeHex(
  'd9bf2148748a85c89da5aad8ee0b0fc2d105fd39d41a4c796536354f0ae2900c',
);

ConfigStoredRecord _buildDefaultConfigRecord() {
  final payload = _decodeHex(
    'd28443a10127a058918519076f1a659431801903e8191ccd5880dff91e2d2fe04b05c94cd448db087c86c1e8a3aa27147cc6a6a29bfb3dad8d85b24e4a4cc2a1a06531603f15f5a41d52b63a53a6d60d647faeb169a12e78d900f22c14bb32e18ab9d99d37403c1860d5b84c6fc0b53b462b9ef193762a84efe6872f72348e210e0584d521a26ee9f983473e2feefe1ff5470abf0f13ea3e8bbd58409fa95a44b0ef9f2ba30a0f389896696ae602067f7f4235afd0e0ec9a269f6071b2e0fe5b01be5f9fd6ce1a29a86b65f45524c44c11d85fbf14609ee04c2cdc06',
  );
  final parsed = ConfigV1Payload.fromBytes(payload);

  return ConfigStoredRecord(
    seqNo: parsed.core.seqNo,
    activeFrom: DateTime.fromMillisecondsSinceEpoch(
      parsed.core.activeFromUnix * 1000,
      isUtc: true,
    ),
    record: ConfigRecord(version: configRecordVersionV1, payload: payload),
  );
}

final class MessageId {
  MessageId(Uint8List bytes) : _bytes = _copyFixed(bytes, 16, 'message id');

  final Uint8List _bytes;

  Uint8List toBytes() => Uint8List.fromList(_bytes);

  String toHex() {
    final out = StringBuffer();
    for (final b in _bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  @override
  bool operator ==(Object other) {
    return other is MessageId && _bytesEqual(other._bytes, _bytes);
  }

  @override
  int get hashCode {
    var hash = 17;
    for (final b in _bytes) {
      hash = 31 * hash + b;
    }
    return hash;
  }
}

final class MessageRecord {
  MessageRecord({
    required this.id,
    required this.senderAddress,
    required this.recipientAddress,
    required DateTime createdAt,
    required DateTime expiresAt,
    required this.isRead,
    required this.ttlSeconds,
    required this.payloadType,
    required Uint8List payload,
    required this.state,
    this.streamId,
    this.powDifficulty,
  })  : payload = Uint8List.fromList(payload),
        createdAt = createdAt.toUtc(),
        expiresAt = expiresAt.toUtc();

  final MessageId id;
  final String senderAddress;
  final String recipientAddress;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool isRead;
  final int ttlSeconds;
  final MessageType payloadType;
  final Uint8List payload;
  final String state;
  final StreamId? streamId;
  final int? powDifficulty;
}

final class MessagesRepository {
  MessagesRepository._(this._db);

  final Database _db;

  void insertMessage(MessageRecord message) {
    _db.execute(
      '''
INSERT INTO messages(
  id, sender_address, recipient_address, created_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state
)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''',
      <Object?>[
        message.id.toBytes(),
        message.senderAddress,
        message.recipientAddress,
        _formatStoredTime(message.createdAt),
        _formatStoredTime(message.expiresAt),
        message.isRead ? 1 : 0,
        message.ttlSeconds,
        message.payloadType.code,
        Uint8List.fromList(message.payload),
        message.state,
      ],
    );
  }

  void updateMessageState(MessageId messageId, String state) {
    _db.execute(
      'UPDATE messages SET state = ? WHERE id = ?;',
      <Object?>[state, messageId.toBytes()],
    );
  }

  void markMessageRead(MessageId messageId) {
    _db.execute(
      'UPDATE messages SET is_read = 1 WHERE id = ?;',
      <Object?>[messageId.toBytes()],
    );
  }

  MessageRecord? getMessageById(MessageId messageId) {
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state
FROM messages
WHERE id = ?;
''',
      <Object?>[messageId.toBytes()],
    );

    if (rows.isEmpty) {
      return null;
    }
    return _scanMessage(rows.first);
  }

  List<MessageRecord> listMessagesByState(String state) {
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state
FROM messages
WHERE state = ?
ORDER BY created_at ASC, id ASC;
''',
      <Object?>[state],
    );
    return rows.map(_scanMessage).toList(growable: false);
  }

  List<MessageRecord> listMessages() {
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state
FROM messages
ORDER BY created_at ASC, id ASC;
''',
    );
    return rows.map(_scanMessage).toList(growable: false);
  }

  List<MessageRecord> listMessagesByRecipientAddress(String address) {
    return _listMessagesByAddress('recipient_address', address.trim());
  }

  List<MessageRecord> listMessagesBySenderAddress(String address) {
    return _listMessagesByAddress('sender_address', address.trim());
  }

  int countMessagesByRecipientAddress(String address) {
    return _countMessagesByAddress('recipient_address', address.trim());
  }

  int countMessagesBySenderAddress(String address) {
    return _countMessagesByAddress('sender_address', address.trim());
  }

  List<MessageRecord> _listMessagesByAddress(String column, String address) {
    final columnName = _validateMessageAddressColumn(column);
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state
FROM messages
WHERE $columnName = ?
ORDER BY created_at DESC, id DESC;
''',
      <Object?>[address],
    );
    return rows.map(_scanMessage).toList(growable: false);
  }

  int _countMessagesByAddress(String column, String address) {
    final columnName = _validateMessageAddressColumn(column);
    final rows = _db.select(
      'SELECT COUNT(*) AS total FROM messages WHERE $columnName = ?;',
      <Object?>[address],
    );
    return _asInt(rows.first['total'], 'messages count');
  }

  MessageRecord _scanMessage(Row row) {
    final id = MessageId(_asBytes(row['id'], 'message id'));
    final payloadType = _parseMessageType(row['payload_type']);
    final recipientAddress = _asString(
      row['recipient_address'],
      'message recipient_address',
    );

    final StreamId streamId;
    try {
      streamId = Address.fromText(recipientAddress).streamId();
    } on FormatException catch (e) {
      throw FormatException('parse message recipient address: ${e.message}');
    }

    return MessageRecord(
      id: id,
      senderAddress: _asString(row['sender_address'], 'message sender_address'),
      recipientAddress: recipientAddress,
      createdAt: _parseStoredTime(
        _asString(row['created_at'], 'message created_at'),
        'message created_at',
      ),
      expiresAt: _parseStoredTime(
        _asString(row['expires_at'], 'message expires_at'),
        'message expires_at',
      ),
      isRead: _asInt(row['is_read'], 'message is_read') != 0,
      ttlSeconds: _asInt(row['ttl_seconds'], 'message ttl_seconds'),
      payloadType: payloadType,
      payload: _asBytes(row['payload'], 'message payload'),
      state: _asString(row['state'], 'message state'),
      streamId: streamId,
    );
  }

  MessageType _parseMessageType(Object? raw) {
    if (raw is int) {
      return MessageType.fromCode(raw);
    }
    if (raw is String) {
      final asInt = int.tryParse(raw);
      if (asInt != null) {
        return MessageType.fromCode(asInt);
      }
      for (final value in MessageType.values) {
        if (value.wireName == raw) {
          return value;
        }
      }
    }
    throw FormatException('message payload type out of range: $raw');
  }

  String _validateMessageAddressColumn(String column) {
    switch (column) {
      case 'sender_address':
      case 'recipient_address':
        return column;
      default:
        throw FormatException('unsupported message address column "$column"');
    }
  }
}

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
  SyncBlobsRepository._(this._db);

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
    return _asInt(changed.first['n'], 'sync blob rows affected') == 1;
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
      final rawBlobId = _asBytes(row['blob_id'], 'sync blob id');
      return SyncBlobIndexRecord(
        blobId: SyncBlobId(rawBlobId),
        expiresAt: _asInt(row['expires_at'], 'sync blob expires_at'),
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
    return _asInt(changed.first['n'], 'expired sync blob rows affected');
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
      blobId: SyncBlobId(_asBytes(row['blob_id'], 'sync blob id')),
      blob: _asBytes(row['blob'], 'sync blob blob'),
      source: _asString(row['source'], 'sync blob source'),
      expiresAt: _asInt(row['expires_at'], 'sync blob expires_at'),
    );
  }
}

final class P2pIdentityRepository {
  P2pIdentityRepository._(this._db, this._nowUtc);

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

    final privateKey = _asBytes(rows.first['private_key'], 'p2p private key');
    if (privateKey.isEmpty) {
      throw FormatException('p2p private key must not be empty');
    }
    return privateKey;
  }

  void upsertPrivateKey(Uint8List privateKey) {
    if (privateKey.isEmpty) {
      throw FormatException('p2p private key must not be empty');
    }

    final now = _formatStoredTime(_nowUtc());
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
  PeersRepository._(this._db);

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
            _formatStoredTime(peer.createdAt),
            peer.lastOnlineAt == null
                ? null
                : _formatStoredTime(peer.lastOnlineAt!),
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
      <Object?>[_formatStoredTime(cutoff)],
    );
    final changed = _db.select('SELECT changes() AS n;');
    return _asInt(changed.first['n'], 'stale peer rows affected');
  }

  PeerRecord _scanPeer(Row row) {
    final rawLastOnlineAt = row['last_online_at'];
    return PeerRecord(
      id: _asString(row['id'], 'peer id'),
      createdAt: _parseStoredTime(
        _asString(row['created_at'], 'peer created_at'),
        'peer created_at',
      ),
      lastOnlineAt: rawLastOnlineAt == null
          ? null
          : _parseStoredTime(
              _asString(rawLastOnlineAt, 'peer last_online_at'),
              'peer last_online_at',
            ),
      rating: _asDouble(row['rating'], 'peer rating'),
    );
  }
}

DateTime _defaultUtcNow() => DateTime.now().toUtc();

String _formatStoredTime(DateTime value) => value.toUtc().toIso8601String();

DateTime _parseStoredTime(String raw, String label) {
  try {
    return DateTime.parse(raw).toUtc();
  } on FormatException catch (error) {
    throw FormatException('parse $label: ${error.message}');
  }
}

String _asString(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be string');
  }
  return value;
}

int _asInt(Object? value, String label) {
  if (value is int) {
    return value;
  }
  if (value is BigInt) {
    return value.toInt();
  }
  throw FormatException('$label must be integer');
}

double _asDouble(Object? value, String label) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  throw FormatException('$label must be number');
}

Uint8List _asBytes(Object? value, String label) {
  if (value is Uint8List) {
    return Uint8List.fromList(value);
  }
  if (value is List<int>) {
    return Uint8List.fromList(value);
  }
  throw FormatException('$label must be bytes');
}

Uint8List _copyFixed(Uint8List bytes, int expected, String label) {
  if (bytes.length != expected) {
    throw FormatException(
        '$label must be $expected bytes, got ${bytes.length}');
  }
  return Uint8List.fromList(bytes);
}

Uint8List _decodeHex(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.length.isOdd) {
    throw const FormatException('hex string length must be even');
  }
  final out = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < normalized.length; i += 2) {
    final byte = int.tryParse(normalized.substring(i, i + 2), radix: 16);
    if (byte == null) {
      throw FormatException('invalid hex at offset $i');
    }
    out[i ~/ 2] = byte;
  }
  return out;
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}
