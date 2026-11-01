part of '../runtime.dart';

final class ReceiveService {
  ReceiveService({
    required DdmSqliteStorage storage,
    required BlobIndex index,
    required AccountManager accountManager,
    required UtcNow nowUtc,
  })  : _storage = storage,
        _index = index,
        _accountManager = accountManager,
        _nowUtc = nowUtc;

  final DdmSqliteStorage _storage;
  final AccountManager _accountManager;
  final UtcNow _nowUtc;
  final BlobIndex _index;

  Future<bool> materializeImportedEncrypted(
    EncryptedMessage encrypted, {
    ImportValidationContext? validationContext,
    RecipientPayloadDecryptor decrypt = decryptForRecipientWithDage,
  }) async {
    final candidate = await _accountManager._decryptImportedMessage(
      encrypted,
      decrypt: decrypt,
    );
    if (candidate == null) {
      return false;
    }
    return materializeDecodedInbound(
      recipient: candidate.account,
      encrypted: encrypted,
      decrypted: candidate.decrypted,
      validationContext: validationContext,
    );
  }

  Future<bool> materializeDecodedInbound({
    required AccountRecord recipient,
    required EncryptedMessage encrypted,
    required UnencryptedMessage decrypted,
    ImportValidationContext? validationContext,
  }) async {
    final localRecipient = _requireLocalRecipient(recipient, encrypted);
    try {
      await decrypted.validate();
    } on FormatException {
      return false;
    }

    if (decrypted.messageType == MessageType.ack) {
      await _processAckMessage(recipient: localRecipient, decrypted: decrypted);
      return true;
    }

    final messageId = MessageId(decrypted.messageId);
    final existing = _storage.messages.getMessageById(messageId);
    if (existing != null) {
      if (decrypted.ackData.isNotEmpty) {
        _storage.messages.markMessageReliableDelivery(messageId);
      }
      await _publishEmbeddedAckForStoredMessage(
        decrypted.ackData,
        stored: existing,
        sender: decrypted.sender,
        recipient: localRecipient,
        validationContext: validationContext,
      );
      return true;
    }

    final receivedAt = _nowUtc().toUtc();
    final recipientAddress = Address.fromText(localRecipient.address);
    final inbound = MessageRecord(
      id: messageId,
      senderAddress: decrypted.sender.toText(),
      recipientAddress: localRecipient.address,
      createdAt: receivedAt,
      updatedAt: receivedAt,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        encrypted.expiresTime * 1000,
        isUtc: true,
      ),
      isRead: false,
      ttlSeconds: encrypted.ttl,
      payloadType: decrypted.messageType,
      payload: decrypted.message,
      state: messageStateReceived,
      reliableDelivery:
          decrypted.ackData.isNotEmpty || recipientAddress.requiresAck,
      streamId: encrypted.streamNumber,
    );
    _storage.messages.insertMessage(inbound);
    _storage.contacts.upsertContact(
      ContactInsert(
        address: decrypted.sender.toText(),
        account: localRecipient.address,
      ),
    );
    await _publishEmbeddedAckForStoredMessage(
      decrypted.ackData,
      stored: inbound,
      sender: decrypted.sender,
      recipient: localRecipient,
      validationContext: validationContext,
    );
    return true;
  }

  Future<void> _processAckMessage({
    required AccountRecord recipient,
    required UnencryptedMessage decrypted,
  }) async {
    if (decrypted.sender.toText() != recipient.address) {
      return;
    }
    final ackedMessageId = MessageId(decrypted.message);
    final ackedMessage = _storage.messages.getMessageById(ackedMessageId);
    if (ackedMessage == null ||
        ackedMessage.senderAddress != recipient.address) {
      return;
    }
    _storage.messages.markMessageReliableDelivery(ackedMessageId);
    _storage.messages.updateMessageState(
      ackedMessageId,
      messageStateDelivered,
    );
  }

  Future<void> _publishEmbeddedAckForStoredMessage(
    Uint8List ackData, {
    required MessageRecord stored,
    required Address sender,
    required AccountRecord recipient,
    required ImportValidationContext? validationContext,
  }) async {
    if (ackData.isEmpty || validationContext == null) {
      return;
    }
    if (stored.senderAddress != sender.toText() ||
        stored.recipientAddress != recipient.address ||
        stored.payloadType == MessageType.ack) {
      return;
    }

    final parsedAck = parseSyncBlobPayload(ackData);
    final configTime = encryptedConfigTimeUnix(parsedAck.encrypted);
    final validated = await parseAndValidateBlob(
      blobPayload: ackData,
      currentConfig: validationContext.configs.configAtUnix(configTime),
      currentUnixSeconds: configTime,
      verifyPow: validationContext.verifyPow,
    );
    final record = SyncBlobRecord(
      blobId: validated.id,
      blob: ackData,
      source: syncBlobSourceLocal,
      expiresAt: validated.encrypted.expiresTime,
    );
    final inserted = _storage.syncBlobs.insertSyncBlob(record);
    if (!inserted) {
      return;
    }
    _index.add(record.blobId, record.expiresAt);
  }

  AccountRecord _requireLocalRecipient(
    AccountRecord recipient,
    EncryptedMessage encrypted,
  ) {
    final local = _requireLocalAccount(recipient);
    if (local.streamId.toUint32() != encrypted.streamNumber.toUint32()) {
      throw FormatException(
        'encrypted stream ${encrypted.streamNumber.toHex()} does not match recipient stream ${local.streamId.toHex()}',
      );
    }
    return local;
  }

  AccountRecord _requireLocalAccount(AccountRecord account) {
    final parsed = Address.fromText(account.address);
    final local = _accountManager.accountByAddress(parsed.toText());
    if (local == null) {
      throw FormatException(
        'account address ${parsed.toText()} not found in local db',
      );
    }
    return local;
  }
}
