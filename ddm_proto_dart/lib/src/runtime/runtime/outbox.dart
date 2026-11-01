part of '../runtime.dart';

final class OutboxService {
  OutboxService({
    required DdmSqliteStorage storage,
    required AccountManager accountManager,
    required UtcNow nowUtc,
    required RandomBytes randomBytes,
    required DurationJitterDraw ttlJitterDraw,
    required DurationJitterDraw expiresJitterDraw,
    required ConfigManager configs,
    required BlobIndex index,
  })  : _storage = storage,
        _accountManager = accountManager,
        _nowUtc = nowUtc,
        _randomBytes = randomBytes,
        _ttlJitterDraw = ttlJitterDraw,
        _expiresJitterDraw = expiresJitterDraw,
        _configs = configs,
        _index = index;

  final DdmSqliteStorage _storage;
  final AccountManager _accountManager;
  final UtcNow _nowUtc;
  final RandomBytes _randomBytes;
  final DurationJitterDraw _ttlJitterDraw;
  final DurationJitterDraw _expiresJitterDraw;
  final ConfigManager _configs;
  final BlobIndex _index;

  List<MessageRecord> listPendingMessages() {
    return _storage.messages.listMessagesByState(messageStateCreated);
  }

  List<MessageRecord> listExpiredReliableDeliveryMessages(DateTime now) {
    return _storage.messages.listExpiredReliablePowSyncedMessages(now);
  }

  Future<List<PublishedOutboxMessage>> publishPendingMessages({
    required PowService pow,
    RecipientPayloadEncryptor encrypt = encryptForRecipientWithDage,
    void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    final out = <PublishedOutboxMessage>[];
    for (final message in listPendingMessages()) {
      out.add(
        await publishMessage(
          message.id,
          pow: pow,
          encrypt: encrypt,
          onPowProgress: onPowProgress,
        ),
      );
    }
    return out;
  }

  Future<PublishedOutboxMessage> publishMessage(
    MessageId messageId, {
    required PowService pow,
    RecipientPayloadEncryptor encrypt = encryptForRecipientWithDage,
    void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    final message = _requireMessage(messageId);
    if (message.state != messageStateCreated) {
      throw FormatException(
        'message ${message.id.toHex()} is ${message.state}, want $messageStateCreated',
      );
    }
    return _publishStoredMessage(
      message,
      pow: pow,
      encrypt: encrypt,
      onPowProgress: onPowProgress,
    );
  }

  Future<List<PublishedOutboxMessage>> retryExpiredReliableDelivery({
    required DateTime now,
    required PowService pow,
    RecipientPayloadEncryptor encrypt = encryptForRecipientWithDage,
    void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    final out = <PublishedOutboxMessage>[];
    for (final message in listExpiredReliableDeliveryMessages(now)) {
      try {
        out.add(
          await _publishStoredMessage(
            message,
            pow: pow,
            encrypt: encrypt,
            onPowProgress: onPowProgress,
          ),
        );
      } catch (error) {
        stderr.writeln(
          '${DateTime.now().toIso8601String()} [ddm:runtime] '
          'reliable delivery retry failed message_id=${message.id.toHex()} '
          'error=$error',
        );
      }
    }
    return out;
  }

  Future<PublishedOutboxMessage> _publishStoredMessage(
    MessageRecord message, {
    required PowService pow,
    required RecipientPayloadEncryptor encrypt,
    required void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    if (message.state != messageStateCreated &&
        message.state != messageStatePowSynced) {
      throw FormatException(
        'message ${message.id.toHex()} is ${message.state}, '
        'want $messageStateCreated or $messageStatePowSynced',
      );
    }

    final senderAddress = Address.fromText(message.senderAddress);
    final recipientAddress = Address.fromText(message.recipientAddress);
    final senderAccount = _accountManager.accountByAddress(
      senderAddress.toText(),
    );
    if (senderAccount == null) {
      throw FormatException(
        'sender account ${senderAddress.toText()} not found in local db',
      );
    }
    final publishNow = _nowUtc().toUtc();
    final publishTTL = _deriveMessagePublishTTL(
      now: publishNow,
      baseTTLSeconds: message.ttlSeconds,
    );

    Uint8List? ackData;
    if (recipientAddress.requiresAck) {
      final ackTTL = deriveAckJitteredTTLWith(
        createdAt: publishNow,
        baseTTLSeconds: publishTTL.ttlSeconds,
        baseExpiresAt: publishTTL.expiresAt,
        ttlDraw: _ttlJitterDraw,
        expiresDraw: _expiresJitterDraw,
      );
      final ackMessageId = generateRuntimeMessageId(
        sender: senderAddress.toText(),
        recipient: senderAddress.toText(),
        createdAt: _nowUtc(),
        randomBytes: _randomBytes,
      );
      final ackPayload = await _buildPowEnvelopePayload(
        pow: pow,
        encrypt: encrypt,
        messageId: ackMessageId,
        senderPrivateKey: senderAccount.privateKey,
        senderAddress: senderAddress,
        recipientAddress: senderAddress,
        messageType: MessageType.ack,
        message: message.id.toBytes(),
        ackData: null,
        ttlSeconds: ackTTL.ttlSeconds,
        expiresAt: ackTTL.expiresAt,
        onPowProgress: onPowProgress,
      );
      await _validatePreparedBlob(
        ackPayload.payload,
        pow: pow,
      );
      ackData = ackPayload.payload;
    }

    final payload = await _buildPowEnvelopePayload(
      pow: pow,
      encrypt: encrypt,
      messageId: message.id,
      senderPrivateKey: senderAccount.privateKey,
      senderAddress: senderAddress,
      recipientAddress: recipientAddress,
      messageType: message.payloadType,
      message: message.payload,
      ackData: ackData,
      ttlSeconds: publishTTL.ttlSeconds,
      expiresAt: publishTTL.expiresAt,
      onPowProgress: onPowProgress,
    );
    final record = _storePreparedBlob(
      blobPayload: payload.payload,
      recipientStreamId: recipientAddress.streamId(),
      expiresAt: publishTTL.expiresAt,
      difficulty: payload.difficulty,
      powElapsed: payload.powElapsed,
    );
    _storage.messages.updateMessageExpiry(
      message.id,
      expiresAt: publishTTL.expiresAt,
      updatedAt: _nowUtc().toUtc(),
    );
    if (message.state != messageStatePowSynced) {
      _storage.messages.updateMessageState(message.id, messageStatePowSynced);
    }
    return PublishedOutboxMessage(
      message: _requireMessage(message.id),
      syncBlob: record.syncBlob,
      difficulty: record.difficulty,
      powElapsed: record.powElapsed,
    );
  }

  Future<PublishedSyncBlob> publishEphemeralRandomMessage({
    required PowService pow,
    required Duration ttl,
    required int minPayloadBytes,
    required int maxPayloadBytes,
    RecipientPayloadEncryptor encrypt = encryptForRecipientWithDage,
    void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    if (ttl <= Duration.zero) {
      throw const FormatException('ttl must be positive');
    }
    if (minPayloadBytes <= 0) {
      throw const FormatException('min payload bytes must be positive');
    }
    if (maxPayloadBytes < minPayloadBytes) {
      throw FormatException(
        'max payload bytes $maxPayloadBytes must be >= min payload bytes $minPayloadBytes',
      );
    }
    if (maxPayloadBytes > maxMessagePayloadBytes) {
      throw FormatException(
        'max payload bytes $maxPayloadBytes exceeds limit $maxMessagePayloadBytes',
      );
    }

    final createdAt = _nowUtc().toUtc();
    final jittered = deriveJitteredTTLsWith(
      ttl,
      ttlDraw: _ttlJitterDraw,
      expiresDraw: _expiresJitterDraw,
    );
    var powTTLSeconds = jittered.powTTL.inSeconds;
    if (powTTLSeconds <= 0) {
      powTTLSeconds = 1;
    }
    final expiresAt = createdAt.add(jittered.expiresTTL);
    final senderKeys = await newAccountKeys(_randomBytes);
    final senderAddress = Address.newV1(senderKeys.publicKey, policy: 0);
    final recipientAddress = Address.newV1(_randomBytes(32), policy: 0);
    final messageId = generateRuntimeMessageId(
      sender: senderAddress.toText(),
      recipient: recipientAddress.toText(),
      createdAt: createdAt,
      randomBytes: _randomBytes,
    );
    final payloadLength = drawRandomIntInclusive(
      minPayloadBytes,
      maxPayloadBytes,
      _randomBytes,
    );
    final payload = _randomBytes(payloadLength);
    final prepared = await _buildPowEnvelopePayload(
      pow: pow,
      encrypt: encrypt,
      messageId: messageId,
      senderPrivateKey: senderKeys.privateKey,
      senderAddress: senderAddress,
      recipientAddress: recipientAddress,
      messageType: MessageType.binary,
      message: payload,
      ackData: null,
      ttlSeconds: powTTLSeconds,
      expiresAt: expiresAt,
      onPowProgress: onPowProgress,
    );
    await _validatePreparedBlob(
      prepared.payload,
      pow: pow,
    );
    return _storePreparedBlob(
      blobPayload: prepared.payload,
      recipientStreamId: recipientAddress.streamId(),
      expiresAt: expiresAt,
      difficulty: prepared.difficulty,
      powElapsed: prepared.powElapsed,
    );
  }

  void markPowSynced(MessageId messageId) {
    final message = _requireMessage(messageId);
    if (message.state != messageStateCreated) {
      throw FormatException(
        'message ${messageId.toHex()} is ${message.state}, want $messageStateCreated',
      );
    }
    _storage.messages.updateMessageState(messageId, messageStatePowSynced);
  }

  void markDelivered(MessageId messageId) {
    _requireMessage(messageId);
    _storage.messages.updateMessageState(messageId, messageStateDelivered);
  }

  MessageRecord _requireMessage(MessageId messageId) {
    final message = _storage.messages.getMessageById(messageId);
    if (message == null) {
      throw FormatException('message ${messageId.toHex()} not found');
    }
    return message;
  }

  ({int ttlSeconds, DateTime expiresAt}) _deriveMessagePublishTTL({
    required DateTime now,
    required int baseTTLSeconds,
  }) {
    var baseTTL = Duration(seconds: baseTTLSeconds);
    if (baseTTL <= Duration.zero) {
      baseTTL = const Duration(seconds: 1);
    }
    final jittered = deriveJitteredTTLsWith(
      baseTTL,
      ttlDraw: _ttlJitterDraw,
      expiresDraw: _expiresJitterDraw,
    );
    var ttlSeconds = jittered.powTTL.inSeconds;
    if (ttlSeconds <= 0) {
      ttlSeconds = 1;
    }
    return (
      ttlSeconds: ttlSeconds,
      expiresAt: now.toUtc().add(jittered.expiresTTL),
    );
  }

  Future<PreparedPowEnvelopePayload> _buildPowEnvelopePayload({
    required PowService pow,
    required RecipientPayloadEncryptor encrypt,
    required MessageId messageId,
    required Uint8List senderPrivateKey,
    required Address senderAddress,
    required Address recipientAddress,
    required MessageType messageType,
    required Uint8List message,
    required Uint8List? ackData,
    required int ttlSeconds,
    required DateTime expiresAt,
    required void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    if (ttlSeconds <= 0 || ttlSeconds > 0xffffffff) {
      throw FormatException('ttl_seconds must fit uint32, got $ttlSeconds');
    }
    final expiresTime = unixSecondsUint32(expiresAt);
    final unencrypted = await UnencryptedMessage.signed(
      privateKey: senderPrivateKey,
      messageId: messageId.toBytes(),
      sender: senderAddress,
      messageType: messageType,
      message: message,
      ackData: ackData,
    );
    final encryptedPayload = await encrypt(
      recipient: recipientAddress,
      plaintext: unencrypted.toBytes(),
    );
    final encrypted = EncryptedMessage(
      version: encryptedMessageVersionV1,
      ttl: ttlSeconds,
      expiresTime: expiresTime,
      streamNumber: recipientAddress.streamId(),
      payload: encryptedPayload,
    );
    final encryptedObject = encrypted.toBytes();
    final configTime = encryptedConfigTimeUnix(encrypted);
    final activeConfig = _configs.configAtUnix(configTime);
    final difficulty = calculateDifficulty(
      base: activeConfig.powBaseTarget,
      scaleDivisor: activeConfig.powScaleDivisor,
      ttlSeconds: ttlSeconds,
      payloadBytes: encryptedObject.length,
    );
    final proof = await pow.solve(
      modulus: activeConfig.powModulus,
      inputHash: encrypted.powInputHash(),
      difficulty: difficulty,
      onProgress: onPowProgress,
    );
    final envelope = PowEnvelope(
      version: powEnvelopeVersionV1,
      algorithm: PowAlgorithm.vdfRsa,
      y: proof.y,
      pi: proof.pi,
      object: encryptedObject,
    );
    return PreparedPowEnvelopePayload(
      payload: envelope.toBytes(),
      difficulty: difficulty,
      powElapsed: proof.elapsed,
    );
  }

  PublishedSyncBlob _storePreparedBlob({
    required Uint8List blobPayload,
    required StreamId recipientStreamId,
    required DateTime expiresAt,
    required int difficulty,
    required Duration powElapsed,
  }) {
    final blobId = deriveSyncBlobId(
      streamId: recipientStreamId,
      blobPayload: blobPayload,
    );
    final record = SyncBlobRecord(
      blobId: blobId,
      blob: blobPayload,
      source: syncBlobSourceLocal,
      expiresAt: unixSecondsUint32(expiresAt),
    );
    _storage.syncBlobs.insertSyncBlob(record);
    _index.add(record.blobId, record.expiresAt);
    return PublishedSyncBlob(
      syncBlob: record,
      difficulty: difficulty,
      powElapsed: powElapsed,
    );
  }

  Future<void> _validatePreparedBlob(
    Uint8List payload, {
    required PowService pow,
  }) async {
    final configTime = encryptedConfigTimeUnix(
      parseSyncBlobPayload(payload).encrypted,
    );
    await parseAndValidateBlob(
      blobPayload: payload,
      currentConfig: _configs.configAtUnix(configTime),
      currentUnixSeconds: configTime,
      verifyPow: ({
        required Uint8List modulus,
        required Uint8List input,
        required int difficulty,
        required Uint8List y,
        required Uint8List pi,
      }) {
        return pow.verify(
          modulus: modulus,
          inputHash: input,
          difficulty: difficulty,
          y: y,
          pi: pi,
        );
      },
    );
  }
}
