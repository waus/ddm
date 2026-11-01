part of '../runtime.dart';

final class MessagingService {
  MessagingService({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    required RandomBytes randomBytes,
  })  : _storage = storage,
        _nowUtc = nowUtc,
        _randomBytes = randomBytes;

  final DdmSqliteStorage _storage;
  final UtcNow _nowUtc;
  final RandomBytes _randomBytes;

  MessageRecord sendTextMessage({
    required AccountRecord sender,
    required Address recipient,
    required String text,
    required Duration ttl,
  }) {
    if (text.trim().isEmpty) {
      throw const FormatException('message text must not be empty');
    }
    return _sendMessage(
      sender: sender,
      recipient: recipient,
      payload: Uint8List.fromList(utf8.encode(text)),
      payloadType: MessageType.plain,
      ttl: ttl,
    );
  }

  MessageRecord sendMarkdownMessage({
    required AccountRecord sender,
    required Address recipient,
    required String markdown,
    required Duration ttl,
  }) {
    if (markdown.trim().isEmpty) {
      throw const FormatException('message markdown must not be empty');
    }
    return _sendMessage(
      sender: sender,
      recipient: recipient,
      payload: Uint8List.fromList(utf8.encode(markdown)),
      payloadType: MessageType.markdown,
      ttl: ttl,
    );
  }

  MessageRecord _sendMessage({
    required AccountRecord sender,
    required Address recipient,
    required Uint8List payload,
    required MessageType payloadType,
    required Duration ttl,
  }) {
    if (ttl <= Duration.zero) {
      throw const FormatException('ttl must be positive');
    }
    if (payload.isEmpty) {
      throw const FormatException('message payload must not be empty');
    }
    if (payload.length > maxMessagePayloadBytes) {
      throw FormatException(
        'message too large: max $maxMessagePayloadBytes bytes',
      );
    }
    switch (payloadType) {
      case MessageType.plain:
      case MessageType.markdown:
        break;
      case MessageType.binary:
      case MessageType.ack:
        throw FormatException('unsupported payload type ${payloadType.code}');
    }

    final createdAt = _nowUtc().toUtc();
    var ttlSeconds = ttl.inSeconds;
    if (ttlSeconds <= 0) {
      ttlSeconds = 1;
    }
    final expiresAt = createdAt.add(Duration(seconds: ttlSeconds));
    final recipientAddress = recipient.toText();
    final id = generateRuntimeMessageId(
      sender: sender.address,
      recipient: recipientAddress,
      createdAt: createdAt,
      randomBytes: _randomBytes,
    );
    final localMessage = MessageRecord(
      id: id,
      senderAddress: sender.address,
      recipientAddress: recipientAddress,
      createdAt: createdAt,
      updatedAt: createdAt,
      expiresAt: expiresAt,
      isRead: true,
      ttlSeconds: ttlSeconds,
      payloadType: payloadType,
      payload: payload,
      state: messageStateCreated,
      reliableDelivery: recipient.requiresAck,
      streamId: recipient.streamId(),
    );
    _storage.messages.insertMessage(localMessage);
    _storage.contacts.upsertContact(
      ContactInsert(
        address: recipientAddress,
        account: sender.address,
      ),
    );
    return localMessage;
  }
}
