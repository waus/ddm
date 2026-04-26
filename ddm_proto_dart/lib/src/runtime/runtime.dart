import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:ddm_proto_dart/src/encryption/dage_ssh_ed25519.dart';
import 'package:ddm_proto_dart/src/pow/pow_service.dart';
import 'package:ddm_proto_dart/src/proto/address.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/envelope.dart';
import 'package:ddm_proto_dart/src/proto/message_types.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/proto/sync_blob.dart';
import 'package:ddm_proto_dart/src/proto/unencrypted_message.dart';
import 'package:ddm_proto_dart/src/runtime/constants.dart';
import 'package:ddm_proto_dart/src/storage/constants.dart';
import 'package:ddm_proto_dart/src/storage/storage.dart';
import 'package:ddm_proto_dart/src/sync/sync.dart';
import 'package:ddm_proto_dart/src/transport/constants.dart';
import 'package:ddm_proto_dart/src/transport/file.dart';
import 'package:ddm_proto_dart/src/transport/http.dart';
import 'package:ddm_proto_dart/src/transport/p2p.dart';
import 'package:ddm_proto_dart/src/transport/server.dart';

typedef RandomBytes = Uint8List Function(int length);
typedef DurationJitterDraw = Duration Function(Duration max);
typedef P2pPrivateKeyGenerator = FutureOr<Uint8List> Function();

final class RuntimeP2pOptions {
  const RuntimeP2pOptions({
    this.backend,
    this.listenAddrs = randomP2pListenAddr,
    this.publicRelay = false,
  });

  final P2pHostBackend? backend;
  final String listenAddrs;
  final bool publicRelay;
}

final class RuntimeTransportOptions {
  const RuntimeTransportOptions({
    this.backgroundSyncEnabled = true,
    this.backgroundSyncInterval = const Duration(seconds: 5),
    this.discoveryInterval = const Duration(seconds: 10),
    this.peerExchangeInterval = const Duration(minutes: 1),
  });

  final bool backgroundSyncEnabled;
  final Duration backgroundSyncInterval;
  final Duration discoveryInterval;
  final Duration peerExchangeInterval;
}

final class DdmCoreRuntimeOptions {
  const DdmCoreRuntimeOptions({
    this.p2p = const RuntimeP2pOptions(),
    this.transports = const RuntimeTransportOptions(),
  });

  final RuntimeP2pOptions p2p;
  final RuntimeTransportOptions transports;
}

enum Mailbox {
  inbox(mailboxInboxName),
  outbox(mailboxOutboxName);

  const Mailbox(this.name);

  final String name;
}

final class DdmCore {
  DdmCore._({
    required DdmSqliteStorage storage,
    required this.accounts,
    required this.config,
    required this.messaging,
    required this.receive,
    required this.outbox,
    required this.sync,
    required this.transports,
    required this.p2pIdentity,
    required this.runtimeOptions,
  }) : _storage = storage;

  final DdmSqliteStorage _storage;
  final AccountsService accounts;
  final ConfigService config;
  final MessagingService messaging;
  final ReceiveService receive;
  final OutboxService outbox;
  final SyncService sync;
  final RuntimeTransportService transports;
  final P2pIdentityService p2pIdentity;
  final DdmCoreRuntimeOptions runtimeOptions;

  static DdmCore open(
    String workdir, {
    UtcNow? nowUtc,
    RandomBytes? randomBytes,
    DurationJitterDraw? ttlJitterDraw,
    DurationJitterDraw? expiresJitterDraw,
    DdmCoreRuntimeOptions runtimeOptions = const DdmCoreRuntimeOptions(),
  }) {
    final clean = workdir.trim();
    if (clean.isEmpty) {
      throw const FormatException('workdir must not be empty');
    }

    final dir = Directory(clean);
    dir.createSync(recursive: true);
    final storage = DdmSqliteStorage.open(
      '${dir.path}/$defaultFileName',
      nowUtc: nowUtc,
    );
    try {
      return fromStorage(
        storage,
        nowUtc: nowUtc,
        randomBytes: randomBytes,
        ttlJitterDraw: ttlJitterDraw,
        expiresJitterDraw: expiresJitterDraw,
        runtimeOptions: runtimeOptions,
      );
    } catch (_) {
      storage.close();
      rethrow;
    }
  }

  static DdmCore fromStorage(
    DdmSqliteStorage storage, {
    UtcNow? nowUtc,
    RandomBytes? randomBytes,
    DurationJitterDraw? ttlJitterDraw,
    DurationJitterDraw? expiresJitterDraw,
    DdmCoreRuntimeOptions runtimeOptions = const DdmCoreRuntimeOptions(),
  }) {
    final now = nowUtc ?? _defaultUtcNow;
    final bytes = randomBytes ?? _secureRandomBytes;
    final ttlDraw = ttlJitterDraw ?? randomDurationUpToInclusive;
    final expiresDraw = expiresJitterDraw ?? randomDurationUpToInclusive;
    final config = ConfigService(storage: storage);
    final accounts = AccountsService(
      storage: storage,
      nowUtc: now,
      randomBytes: bytes,
    );
    final messaging = MessagingService(
      storage: storage,
      nowUtc: now,
      randomBytes: bytes,
    );
    final receive = ReceiveService(storage: storage, nowUtc: now);
    final sync = SyncService(
      storage: storage,
      nowUtc: now,
      onImportedBlob: receive.materializeImportedEncrypted,
    );
    receive.attachLocalSource(sync.localSource);
    final outbox = OutboxService(
      storage: storage,
      nowUtc: now,
      randomBytes: bytes,
      ttlJitterDraw: ttlDraw,
      expiresJitterDraw: expiresDraw,
      localSource: sync.localSource,
    );
    final p2pIdentity = P2pIdentityService(storage: storage);
    final transports = RuntimeTransportService(
      storage: storage,
      nowUtc: now,
      localSource: sync.localSource,
      loadP2pIdentity: () => p2pIdentity.loadOrCreatePrivateKey(),
      p2pBackend: runtimeOptions.p2p.backend,
      p2pListenAddrs: runtimeOptions.p2p.listenAddrs,
      p2pPublicRelay: runtimeOptions.p2p.publicRelay,
    );
    final core = DdmCore._(
      storage: storage,
      accounts: accounts,
      config: config,
      messaging: messaging,
      receive: receive,
      outbox: outbox,
      sync: sync,
      transports: transports,
      p2pIdentity: p2pIdentity,
      runtimeOptions: runtimeOptions,
    );
    core.config.loadActiveConfigCore(now());
    return core;
  }

  void close() {
    transports.close();
    sync.close();
    _storage.close();
  }
}

final class P2pIdentityService {
  P2pIdentityService({required DdmSqliteStorage storage}) : _storage = storage;

  final DdmSqliteStorage _storage;

  Uint8List? getPrivateKey() => _storage.p2pIdentity.getPrivateKey();

  Future<Uint8List> loadOrCreatePrivateKey({
    P2pPrivateKeyGenerator? generatePrivateKey,
  }) async {
    final existing = _storage.p2pIdentity.getPrivateKey();
    if (existing != null) {
      return Uint8List.fromList(existing);
    }
    final generated =
        await (generatePrivateKey ?? generateP2pPrivateKey).call();
    if (generated.isEmpty) {
      throw const FormatException('p2p private key must not be empty');
    }
    _storage.p2pIdentity.upsertPrivateKey(generated);
    return Uint8List.fromList(generated);
  }
}

final class RuntimeTransportService {
  RuntimeTransportService({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    required SyncSource localSource,
    required P2pIdentityLoader loadP2pIdentity,
    P2pHostBackend? p2pBackend,
    String p2pListenAddrs = randomP2pListenAddr,
    bool p2pPublicRelay = false,
  })  : _storage = storage,
        _localSource = localSource,
        sources = SourceRegistry(storage: storage, nowUtc: nowUtc) {
    _servers.add(newHttpProtocolServer());
    _servers.add(newFileProtocolServer());
    _servers.add(
      P2pSyncTransportServer(
        loadIdentity: loadP2pIdentity,
        source: _localSource,
        backend: p2pBackend,
        rawListenAddrs: p2pListenAddrs,
        publicRelay: p2pPublicRelay,
      ),
    );
  }

  final DdmSqliteStorage _storage;
  final SyncSource _localSource;
  final SourceRegistry sources;
  final List<SyncTransportServer> _servers = <SyncTransportServer>[];
  bool _discoveryServersStarted = false;
  bool _closed = false;

  List<String> registeredSourceProtocols() {
    return _servers
        .map((server) => server.protocolName)
        .toSet()
        .toList(growable: false)
      ..sort();
  }

  List<String> sourceIds() => sources.sourceIds();

  Future<HttpSyncSourceServer> startHttpServer({
    required String listenAddress,
  }) async {
    final server = HttpSyncSourceServer(listenAddress: listenAddress);
    await addServer(server);
    return server;
  }

  Future<void> addServer(SyncTransportServer server) async {
    _ensureOpen();
    final protocolName = server.protocolName.trim();
    if (protocolName.isEmpty) {
      throw const FormatException(
          'sync server protocol name must not be empty');
    }
    await server.start(_localSource);
    try {
      await _restoreStoredPeerSources(server);
      _servers.add(server);
    } catch (_) {
      await server.stop();
      rethrow;
    }
  }

  Future<void> addSource(String raw) async {
    _ensureOpen();
    final id = raw.trim();
    if (id.isEmpty) {
      throw const FormatException('sync source upstream must not be empty');
    }
    final server = _matchServer(id);
    if (server == null) {
      throw FormatException('unsupported sync source upstream: $id');
    }
    final source = await server.createPeerSource(id);
    if (!sources.add(source)) {
      source.stop();
    }
  }

  Future<List<String>> discoverPeers() async {
    _ensureOpen();
    final out = <String>[];
    for (final server in _servers) {
      if (!server.flags.has(serverFlagDiscovery)) {
        continue;
      }
      out.addAll(await server.discoverPeers());
    }
    return out;
  }

  Future<void> restoreRegisteredSources() async {
    _ensureOpen();
    unawaited(
      _startDiscoveryServers().catchError((Object _) {
        _discoveryServersStarted = false;
      }),
    );
    for (final server in _servers) {
      await _restoreStoredPeerSources(server);
    }
    await _addDefaultPeerExchangeSources();
  }

  Future<void> stopServers() async {
    final servers = List<SyncTransportServer>.from(_servers);
    _servers.clear();
    _discoveryServersStarted = false;
    for (final server in servers) {
      await server.stop();
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    final servers = List<SyncTransportServer>.from(_servers);
    _servers.clear();
    for (final server in servers) {
      unawaited(server.stop());
    }
    sources.close();
  }

  Future<void> _restoreStoredPeerSources(SyncTransportServer server) async {
    for (final peer in _storage.peers.listPeers()) {
      if (!server.peerMatch(peer.id)) {
        continue;
      }
      SyncSource source;
      try {
        source = await server.createPeerSource(peer.id);
      } catch (_) {
        continue;
      }
      if (!sources.addStored(source, peer)) {
        source.stop();
      }
    }
  }

  Future<void> _addDefaultPeerExchangeSources() async {
    final existing = sources.sourceIds().toSet();
    for (final addr in defaultPeerExchangeAddrs) {
      if (existing.contains(addr)) {
        continue;
      }
      await addSource(addr);
      existing.add(addr);
    }
  }

  Future<void> _startDiscoveryServers() async {
    if (_discoveryServersStarted) {
      return;
    }
    _discoveryServersStarted = true;
    try {
      for (final server in _servers) {
        if (!server.flags.has(serverFlagDiscovery)) {
          continue;
        }
        await server.start(_localSource);
      }
    } catch (_) {
      _discoveryServersStarted = false;
      rethrow;
    }
  }

  SyncTransportServer? _matchServer(String id) {
    for (final server in _servers) {
      if (server.peerMatch(id)) {
        return server;
      }
    }
    return null;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('runtime transport service is closed');
    }
  }
}

final class AccountOverview {
  const AccountOverview({
    required this.account,
    required this.inboxCount,
    required this.outboxCount,
  });

  final AccountRecord account;
  final int inboxCount;
  final int outboxCount;
}

final class AccountKeyExport {
  AccountKeyExport({
    required this.account,
    required Uint8List publicKey,
    required Uint8List privateKey,
  })  : publicKey = Uint8List.fromList(publicKey),
        privateKey = Uint8List.fromList(privateKey);

  final AccountRecord account;
  final Uint8List publicKey;
  final Uint8List privateKey;
}

final class AccountsService {
  AccountsService({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    required RandomBytes randomBytes,
  })  : _storage = storage,
        _nowUtc = nowUtc,
        _randomBytes = randomBytes;

  final DdmSqliteStorage _storage;
  final UtcNow _nowUtc;
  final RandomBytes _randomBytes;

  Future<AccountRecord> createAccount(
    String accountName, {
    int policy = 0,
  }) async {
    final name = _normalizeAccountName(accountName, _nowUtc);
    final keys = await _newAccountKeys(_randomBytes);
    final address = Address.newV1(keys.publicKey, policy: policy);
    return _storage.accounts.createAccount(
      AccountInsert(
        name: name,
        address: address.toText(),
        publicKey: keys.publicKey,
        privateKey: keys.privateKey,
        streamId: address.streamId(),
        createdAt: _nowUtc(),
      ),
    );
  }

  List<AccountRecord> listAccounts() {
    return _storage.accounts.listAccounts();
  }

  AccountOverview getAccountOverview(AccountRecord account) {
    final local = requireLocalAccount(account);
    return AccountOverview(
      account: local,
      inboxCount: _storage.messages.countMessagesByRecipientAddress(
        local.address,
      ),
      outboxCount: _storage.messages.countMessagesBySenderAddress(
        local.address,
      ),
    );
  }

  List<MessageRecord> listMailboxMessages(
    AccountRecord account,
    Mailbox mailbox,
  ) {
    final local = requireLocalAccount(account);
    switch (mailbox) {
      case Mailbox.inbox:
        return _storage.messages.listMessagesByRecipientAddress(local.address);
      case Mailbox.outbox:
        return _storage.messages.listMessagesBySenderAddress(local.address);
    }
  }

  void markMessageRead(AccountRecord account, MessageId messageId) {
    final local = requireLocalAccount(account);
    final message = _storage.messages.getMessageById(messageId);
    if (message == null) {
      throw FormatException('message ${messageId.toHex()} not found');
    }
    if (message.recipientAddress != local.address) {
      throw FormatException(
        'message ${messageId.toHex()} does not belong to inbox account ${local.address}',
      );
    }
    if (message.isRead) {
      return;
    }
    _storage.messages.markMessageRead(messageId);
  }

  AccountKeyExport exportAccountKeys(AccountRecord account) {
    final local = requireLocalAccount(account);
    return AccountKeyExport(
      account: local,
      publicKey: local.publicKey,
      privateKey: local.privateKey,
    );
  }

  AccountRecord requireLocalAccount(AccountRecord account) {
    final parsed = Address.fromText(account.address);
    final local = _storage.accounts.getAccountByAddress(parsed.toText());
    if (local == null) {
      throw FormatException(
        'account address ${parsed.toText()} not found in local db',
      );
    }
    return local;
  }
}

final class ConfigService {
  ConfigService({required DdmSqliteStorage storage}) : _storage = storage;

  final DdmSqliteStorage _storage;

  ConfigV1Core loadActiveConfigCore(DateTime now) {
    final record = _storage.configs.getActiveConfigRecord(now.toUtc());
    if (record == null) {
      throw const FormatException('active config record not found in storage');
    }
    final payload = ConfigV1Payload.fromBytes(record.record.payload);
    return payload.core;
  }
}

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

    final senderAddress = Address.fromText(sender.address);
    final localSender = _storage.accounts.getAccountByAddress(
      senderAddress.toText(),
    );
    if (localSender == null) {
      throw const FormatException('sender address not found in local db');
    }

    final createdAt = _nowUtc().toUtc();
    var ttlSeconds = ttl.inSeconds;
    if (ttlSeconds <= 0) {
      ttlSeconds = 1;
    }
    final expiresAt = createdAt.add(Duration(seconds: ttlSeconds));
    final recipientAddress = recipient.toText();
    final id = _generateMessageId(
      sender: localSender.address,
      recipient: recipientAddress,
      createdAt: createdAt,
      randomBytes: _randomBytes,
    );
    final localMessage = MessageRecord(
      id: id,
      senderAddress: localSender.address,
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
    return localMessage;
  }
}

final class ReceiveService {
  ReceiveService({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
  })  : _storage = storage,
        _nowUtc = nowUtc;

  final DdmSqliteStorage _storage;
  final UtcNow _nowUtc;
  LocalSyncSource? _localSource;

  void attachLocalSource(LocalSyncSource localSource) {
    if (_localSource != null && !identical(_localSource, localSource)) {
      throw StateError('receive service local sync source is already attached');
    }
    _localSource = localSource;
  }

  Future<bool> materializeImportedEncrypted(
    EncryptedMessage encrypted, {
    ImportValidationContext? validationContext,
    RecipientPayloadDecryptor decrypt = decryptForRecipientWithDage,
  }) async {
    var handled = false;
    for (final account in _storage.accounts.listAccounts()) {
      if (account.streamId.toUint32() != encrypted.streamNumber.toUint32()) {
        continue;
      }
      Uint8List plaintext;
      try {
        plaintext = await decrypt(
          privateKey: account.privateKey,
          publicKey: account.publicKey,
          ciphertext: encrypted.payload,
        );
      } catch (_) {
        continue;
      }
      try {
        final decrypted = UnencryptedMessage.fromBytes(plaintext);
        handled = await materializeDecodedInbound(
              recipient: account,
              encrypted: encrypted,
              decrypted: decrypted,
              validationContext: validationContext,
            ) ||
            handled;
      } on FormatException {
        continue;
      }
    }
    return handled;
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
      await processAckMessage(recipient: localRecipient, decrypted: decrypted);
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
    await _publishEmbeddedAckForStoredMessage(
      decrypted.ackData,
      stored: inbound,
      sender: decrypted.sender,
      recipient: localRecipient,
      validationContext: validationContext,
    );
    return true;
  }

  Future<void> processAckMessage({
    required AccountRecord recipient,
    required UnencryptedMessage decrypted,
  }) async {
    final localRecipient = _requireLocalAccount(recipient);
    if (decrypted.sender.toText() != localRecipient.address) {
      return;
    }
    final ackedMessageId = MessageId(decrypted.message);
    final ackedMessage = _storage.messages.getMessageById(ackedMessageId);
    if (ackedMessage == null ||
        ackedMessage.senderAddress != localRecipient.address) {
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

    final validated = await parseAndValidateBlob(
      blobPayload: ackData,
      currentConfig: validationContext.currentConfig,
      currentUnixSeconds: validationContext.currentUnixSeconds,
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
    _localSource?.index.add(record.blobId, record.expiresAt);
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
    final local = _storage.accounts.getAccountByAddress(parsed.toText());
    if (local == null) {
      throw FormatException(
        'account address ${parsed.toText()} not found in local db',
      );
    }
    return local;
  }
}

final class OutboxService {
  OutboxService({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    required RandomBytes randomBytes,
    required DurationJitterDraw ttlJitterDraw,
    required DurationJitterDraw expiresJitterDraw,
    LocalSyncSource? localSource,
  })  : _storage = storage,
        _nowUtc = nowUtc,
        _randomBytes = randomBytes,
        _ttlJitterDraw = ttlJitterDraw,
        _expiresJitterDraw = expiresJitterDraw,
        _localSource = localSource;

  final DdmSqliteStorage _storage;
  final UtcNow _nowUtc;
  final RandomBytes _randomBytes;
  final DurationJitterDraw _ttlJitterDraw;
  final DurationJitterDraw _expiresJitterDraw;
  final LocalSyncSource? _localSource;

  List<MessageRecord> listPendingMessages() {
    return _storage.messages.listMessagesByState(messageStateCreated);
  }

  List<MessageRecord> listExpiredReliableDeliveryMessages(DateTime now) {
    return _storage.messages.listExpiredReliablePowSyncedMessages(now);
  }

  Future<List<PublishedOutboxMessage>> publishPendingMessages({
    required ConfigV1Core activeConfig,
    required PowService pow,
    RecipientPayloadEncryptor encrypt = encryptForRecipientWithDage,
    void Function(PowSolveProgress progress)? onPowProgress,
  }) async {
    final out = <PublishedOutboxMessage>[];
    for (final message in listPendingMessages()) {
      out.add(
        await publishMessage(
          message.id,
          activeConfig: activeConfig,
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
    required ConfigV1Core activeConfig,
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
      activeConfig: activeConfig,
      pow: pow,
      encrypt: encrypt,
      onPowProgress: onPowProgress,
    );
  }

  Future<List<PublishedOutboxMessage>> retryExpiredReliableDelivery({
    required DateTime now,
    required ConfigV1Core activeConfig,
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
            activeConfig: activeConfig,
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
    required ConfigV1Core activeConfig,
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
    final senderAccount = _storage.accounts.getAccountByAddress(
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
      final ackMessageId = _generateMessageId(
        sender: senderAddress.toText(),
        recipient: senderAddress.toText(),
        createdAt: _nowUtc(),
        randomBytes: _randomBytes,
      );
      final ackPayload = await _buildPowEnvelopePayload(
        activeConfig: activeConfig,
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
        activeConfig: activeConfig,
        pow: pow,
      );
      ackData = ackPayload.payload;
    }

    final payload = await _buildPowEnvelopePayload(
      activeConfig: activeConfig,
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
    required ConfigV1Core activeConfig,
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
    final senderKeys = await _newAccountKeys(_randomBytes);
    final senderAddress = Address.newV1(senderKeys.publicKey, policy: 0);
    final recipientAddress = Address.newV1(_randomBytes(32), policy: 0);
    final messageId = _generateMessageId(
      sender: senderAddress.toText(),
      recipient: recipientAddress.toText(),
      createdAt: createdAt,
      randomBytes: _randomBytes,
    );
    final payloadLength = _drawRandomIntInclusive(
      minPayloadBytes,
      maxPayloadBytes,
      _randomBytes,
    );
    final payload = _randomBytes(payloadLength);
    final prepared = await _buildPowEnvelopePayload(
      activeConfig: activeConfig,
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
      activeConfig: activeConfig,
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

  Future<_PreparedPowEnvelopePayload> _buildPowEnvelopePayload({
    required ConfigV1Core activeConfig,
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
    final expiresTime = _unixSeconds(expiresAt);
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
    return _PreparedPowEnvelopePayload(
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
      expiresAt: _unixSeconds(expiresAt),
    );
    _storage.syncBlobs.insertSyncBlob(record);
    _localSource?.index.add(record.blobId, record.expiresAt);
    return PublishedSyncBlob(
      syncBlob: record,
      difficulty: difficulty,
      powElapsed: powElapsed,
    );
  }

  Future<void> _validatePreparedBlob(
    Uint8List payload, {
    required ConfigV1Core activeConfig,
    required PowService pow,
  }) async {
    await parseAndValidateBlob(
      blobPayload: payload,
      currentConfig: activeConfig,
      currentUnixSeconds: _unixSeconds(_nowUtc()),
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

final class PublishedOutboxMessage {
  PublishedOutboxMessage({
    required this.message,
    required this.syncBlob,
    required this.difficulty,
    required this.powElapsed,
  });

  final MessageRecord message;
  final SyncBlobRecord syncBlob;
  final int difficulty;
  final Duration powElapsed;
}

final class PublishedSyncBlob {
  PublishedSyncBlob({
    required this.syncBlob,
    required this.difficulty,
    required this.powElapsed,
  });

  final SyncBlobRecord syncBlob;
  final int difficulty;
  final Duration powElapsed;
}

final class _PreparedPowEnvelopePayload {
  _PreparedPowEnvelopePayload({
    required this.payload,
    required this.difficulty,
    required this.powElapsed,
  });

  final Uint8List payload;
  final int difficulty;
  final Duration powElapsed;
}

({Duration powTTL, Duration expiresTTL}) deriveJitteredTTLsWith(
  Duration base, {
  required DurationJitterDraw ttlDraw,
  required DurationJitterDraw expiresDraw,
}) {
  final powTTL = addRandomTTLJitterWith(base, ttlDraw);
  var expiresTTL = addRandomDurationJitterWith(
    base,
    expiresJitterDivisor,
    expiresDraw,
  );
  if (expiresTTL > powTTL) {
    expiresTTL = powTTL;
  }
  return (powTTL: powTTL, expiresTTL: expiresTTL);
}

({int ttlSeconds, DateTime expiresAt}) deriveAckJitteredTTLWith({
  required DateTime createdAt,
  required int baseTTLSeconds,
  required DateTime baseExpiresAt,
  required DurationJitterDraw ttlDraw,
  required DurationJitterDraw expiresDraw,
}) {
  var baseTTL = Duration(seconds: baseTTLSeconds);
  if (baseTTL <= Duration.zero) {
    baseTTL = const Duration(seconds: 1);
  }
  var ackTTL = addRandomTTLJitterWith(baseTTL, ttlDraw);
  if (ackTTL <= Duration.zero) {
    ackTTL = const Duration(seconds: 1);
  }

  var baseExpiresTTL = baseExpiresAt.toUtc().difference(createdAt.toUtc());
  if (baseExpiresTTL <= Duration.zero) {
    baseExpiresTTL = const Duration(seconds: 1);
  }
  var ackExpiresTTL = addRandomDurationJitterWith(
    baseExpiresTTL,
    expiresJitterDivisor,
    expiresDraw,
  );
  if (ackExpiresTTL > ackTTL) {
    ackExpiresTTL = ackTTL;
  }
  var ackTTLSeconds = ackTTL.inSeconds;
  if (ackTTLSeconds <= 0) {
    ackTTLSeconds = 1;
  }
  return (
    ttlSeconds: ackTTLSeconds,
    expiresAt: createdAt.toUtc().add(ackExpiresTTL),
  );
}

Duration addRandomTTLJitterWith(
  Duration base,
  DurationJitterDraw draw,
) {
  return addRandomDurationJitterWith(base, ttlJitterDivisor, draw);
}

Duration addRandomDurationJitterWith(
  Duration base,
  int divisor,
  DurationJitterDraw draw,
) {
  if (base <= Duration.zero || divisor <= 0) {
    return base;
  }
  final maxJitter = Duration(microseconds: base.inMicroseconds ~/ divisor);
  if (maxJitter <= Duration.zero) {
    return base;
  }
  var jitter = draw(maxJitter);
  if (jitter < Duration.zero) {
    jitter = Duration.zero;
  }
  if (jitter > maxJitter) {
    jitter = maxJitter;
  }
  return base + jitter;
}

Duration randomDurationUpToInclusive(Duration max) {
  if (max <= Duration.zero) {
    return Duration.zero;
  }
  final value =
      _secureRandomBigInt(BigInt.from(max.inMicroseconds) + BigInt.one);
  return Duration(microseconds: value);
}

Future<({Uint8List publicKey, Uint8List privateKey})> _newAccountKeys(
  RandomBytes randomBytes,
) async {
  final seed = randomBytes(32);
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  final privateKey = Uint8List(64)
    ..setRange(0, 32, seed)
    ..setRange(32, 64, publicKey.bytes);
  return (
    publicKey: Uint8List.fromList(publicKey.bytes),
    privateKey: privateKey,
  );
}

MessageId _generateMessageId({
  required String sender,
  required String recipient,
  required DateTime createdAt,
  required RandomBytes randomBytes,
}) {
  final input = <int>[
    ...sender.codeUnits,
    ...recipient.codeUnits,
    ...createdAt.toUtc().toIso8601String().codeUnits,
    ...randomBytes(16),
  ];
  final digest = crypto.sha256.convert(input).bytes;
  return MessageId(Uint8List.fromList(digest.sublist(0, 16)));
}

int _drawRandomIntInclusive(
  int min,
  int max,
  RandomBytes randomBytes,
) {
  if (min > max) {
    throw FormatException('min $min must be <= max $max');
  }
  final span = BigInt.from(max - min + 1);
  final byteLength = (span.bitLength + 7) >> 3;
  while (true) {
    var value = BigInt.zero;
    final bytes = randomBytes(byteLength);
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    if (value < span) {
      return min + value.toInt();
    }
  }
}

String _normalizeAccountName(String accountName, UtcNow nowUtc) {
  final trimmed = accountName.trim();
  if (trimmed.isNotEmpty) {
    return trimmed;
  }
  return 'account-${nowUtc().toUtc().microsecondsSinceEpoch * 1000}';
}

DateTime _defaultUtcNow() => DateTime.now().toUtc();

int _unixSeconds(DateTime value) {
  final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xffffffff) {
    throw FormatException('unix timestamp out of uint32 range: $seconds');
  }
  return seconds;
}

final Random _secureRandom = Random.secure();

Uint8List _secureRandomBytes(int length) {
  if (length < 0) {
    throw FormatException('random byte length must be non-negative');
  }
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

int _secureRandomBigInt(BigInt exclusiveMax) {
  if (exclusiveMax <= BigInt.zero) {
    throw const FormatException('exclusive max must be positive');
  }

  final byteLength = (exclusiveMax.bitLength + 7) >> 3;
  while (true) {
    var value = BigInt.zero;
    for (var i = 0; i < byteLength; i++) {
      value = (value << 8) | BigInt.from(_secureRandom.nextInt(256));
    }
    if (value < exclusiveMax) {
      return value.toInt();
    }
  }
}
