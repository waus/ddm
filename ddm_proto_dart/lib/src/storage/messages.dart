import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/address.dart';
import 'package:ddm_proto_dart/src/proto/message_types.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/storage/constants.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class MessageId {
  MessageId(Uint8List bytes) : _bytes = copyFixed(bytes, 16, 'message id');

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
    return other is MessageId && bytesEqual(other._bytes, _bytes);
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
    DateTime? updatedAt,
    required DateTime expiresAt,
    required this.isRead,
    required this.ttlSeconds,
    required this.payloadType,
    required Uint8List payload,
    required this.state,
    required this.reliableDelivery,
    this.streamId,
    this.powDifficulty,
  })  : payload = Uint8List.fromList(payload),
        createdAt = createdAt.toUtc(),
        updatedAt = (updatedAt ?? createdAt).toUtc(),
        expiresAt = expiresAt.toUtc();

  final MessageId id;
  final String senderAddress;
  final String recipientAddress;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime expiresAt;
  final bool isRead;
  final int ttlSeconds;
  final MessageType payloadType;
  final Uint8List payload;
  final String state;
  final bool reliableDelivery;
  final StreamId? streamId;
  final int? powDifficulty;
}

final class MessagesRepository {
  MessagesRepository(this._db);

  final Database _db;

  void insertMessage(MessageRecord message) {
    _db.execute(
      '''
INSERT INTO messages(
  id, sender_address, recipient_address, created_at, updated_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state, reliable_delivery
)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''',
      <Object?>[
        message.id.toBytes(),
        message.senderAddress,
        message.recipientAddress,
        formatStoredTime(message.createdAt),
        formatStoredTime(message.updatedAt),
        formatStoredTime(message.expiresAt),
        message.isRead ? 1 : 0,
        message.ttlSeconds,
        message.payloadType.code,
        Uint8List.fromList(message.payload),
        message.state,
        message.reliableDelivery ? 1 : 0,
      ],
    );
  }

  void updateMessageState(MessageId messageId, String state) {
    _db.execute(
      'UPDATE messages SET state = ?, updated_at = ? WHERE id = ?;',
      <Object?>[
        state,
        formatStoredTime(DateTime.now().toUtc()),
        messageId.toBytes()
      ],
    );
  }

  void updateMessageExpiry(
    MessageId messageId, {
    required DateTime expiresAt,
    required DateTime updatedAt,
  }) {
    _db.execute(
      'UPDATE messages SET expires_at = ?, updated_at = ? WHERE id = ?;',
      <Object?>[
        formatStoredTime(expiresAt.toUtc()),
        formatStoredTime(updatedAt.toUtc()),
        messageId.toBytes(),
      ],
    );
  }

  void markMessageReliableDelivery(MessageId messageId) {
    _db.execute(
      'UPDATE messages SET reliable_delivery = 1 WHERE id = ?;',
      <Object?>[messageId.toBytes()],
    );
  }

  void markMessageRead(MessageId messageId) {
    _db.execute(
      'UPDATE messages SET is_read = 1 WHERE id = ?;',
      <Object?>[messageId.toBytes()],
    );
  }

  bool deleteMessageById(MessageId messageId) {
    _db.execute(
      'DELETE FROM messages WHERE id = ?;',
      <Object?>[messageId.toBytes()],
    );
    final changed = _db.select('SELECT changes() AS n;');
    return asInt(changed.first['n'], 'deleted messages count') > 0;
  }

  MessageRecord? getMessageById(MessageId messageId) {
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, updated_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state, reliable_delivery
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
  id, sender_address, recipient_address, created_at, updated_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state, reliable_delivery
FROM messages
WHERE state = ?
ORDER BY created_at ASC, id ASC;
''',
      <Object?>[state],
    );
    return rows.map(_scanMessage).toList(growable: false);
  }

  List<MessageRecord> listExpiredReliablePowSyncedMessages(DateTime now) {
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, updated_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state, reliable_delivery
FROM messages
WHERE state = ? AND reliable_delivery != 0 AND expires_at < ?
ORDER BY updated_at ASC, id ASC;
''',
      <Object?>[messageStatePowSynced, formatStoredTime(now.toUtc())],
    );
    return rows.map(_scanMessage).toList(growable: false);
  }

  List<MessageRecord> listMessages() {
    final rows = _db.select(
      '''
SELECT
  id, sender_address, recipient_address, created_at, updated_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state, reliable_delivery
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
  id, sender_address, recipient_address, created_at, updated_at, expires_at, is_read, ttl_seconds,
  payload_type, payload, state, reliable_delivery
FROM messages
WHERE $columnName = ?
ORDER BY updated_at DESC, id DESC;
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
    return asInt(rows.first['total'], 'messages count');
  }

  MessageRecord _scanMessage(Row row) {
    final id = MessageId(asBytes(row['id'], 'message id'));
    final payloadType = _parseMessageType(row['payload_type']);
    final recipientAddress = asString(
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
      senderAddress: asString(row['sender_address'], 'message sender_address'),
      recipientAddress: recipientAddress,
      createdAt: parseStoredTime(
        asString(row['created_at'], 'message created_at'),
        'message created_at',
      ),
      updatedAt: parseStoredTime(
        asString(row['updated_at'], 'message updated_at'),
        'message updated_at',
      ),
      expiresAt: parseStoredTime(
        asString(row['expires_at'], 'message expires_at'),
        'message expires_at',
      ),
      isRead: asInt(row['is_read'], 'message is_read') != 0,
      ttlSeconds: asInt(row['ttl_seconds'], 'message ttl_seconds'),
      payloadType: payloadType,
      payload: asBytes(row['payload'], 'message payload'),
      state: asString(row['state'], 'message state'),
      reliableDelivery:
          asInt(row['reliable_delivery'], 'message reliable_delivery') != 0,
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
