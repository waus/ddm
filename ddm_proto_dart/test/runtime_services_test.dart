import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

void main() {
  test('DdmCore creates accounts with DDM addresses and exportable keys',
      () async {
    final core = _openCore();
    addTearDown(core.close);

    final account = await core.accounts.createAccount(
      'alice',
      policy: addressPolicyAckExpected,
    );

    final parsed = Address.fromText(account.address);
    expect(parsed.requiresAck, isTrue);
    expect(account.publicKey.length, 32);
    expect(account.privateKey.length, 64);
    expect(account.streamId.toUint32(), parsed.streamId().toUint32());

    final exported = core.accounts.exportAccountKeys(account);
    expect(exported.publicKey, account.publicKey);
    expect(exported.privateKey, account.privateKey);
  });

  test('DdmCore rejects duplicate account names case-insensitively', () async {
    final core = _openCore();
    addTearDown(core.close);

    await core.accounts.createAccount('Alice');
    expect(
      () => core.accounts.createAccount('alice'),
      throwsA(isA<AccountNameExistsException>()),
    );
  });

  test('send text persists local outbound message with base ttl', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final core = _openCore(
      nowUtc: () => now,
      ttlDraw: (max) => max,
      expiresDraw: (max) => Duration(microseconds: max.inMicroseconds ~/ 2),
    );
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount('bob');
    final message = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(bob.address),
      text: 'hello bob',
      ttl: const Duration(seconds: 100),
    );

    expect(message.senderAddress, alice.address);
    expect(message.recipientAddress, bob.address);
    expect(message.createdAt, now);
    expect(message.ttlSeconds, 100);
    expect(
      message.expiresAt,
      now.add(const Duration(seconds: 100)),
    );
    expect(message.payloadType, MessageType.plain);
    expect(String.fromCharCodes(message.payload), 'hello bob');
    expect(message.isRead, isTrue);
    expect(message.state, messageStateCreated);
    expect(message.updatedAt, message.createdAt);
    expect(message.reliableDelivery, isFalse);
    expect(core.outbox.listPendingMessages().map((m) => m.id), [message.id]);

    final contacts = core.contacts.listContacts(alice);
    expect(contacts, hasLength(1));
    expect(contacts.single.address, bob.address);
    expect(contacts.single.account, alice.address);
    expect(contacts.single.approved, isFalse);
  });

  test('send requires a local sender account', () async {
    final core = _openCore();
    addTearDown(core.close);
    final otherCore = _openCore();
    addTearDown(otherCore.close);

    final bob = await core.accounts.createAccount('bob');
    final unknownSender = await otherCore.accounts.createAccount('alice');

    expect(
      () => core.messaging.sendTextMessage(
        sender: unknownSender,
        recipient: Address.fromText(bob.address),
        text: 'hello bob',
        ttl: const Duration(hours: 1),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('account overview, mailbox queries and mark read use runtime API',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final core = _openCore(nowUtc: () => now);
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount('bob');
    final outbound = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(bob.address),
      text: 'hello bob',
      ttl: const Duration(hours: 1),
    );
    final inbound = await _decodedMessage(
      sender: bob,
      recipient: alice,
      message: 'hello alice',
      messageIdSeed: 0x41,
    );
    final handled = await core.receive.materializeDecodedInbound(
      recipient: alice,
      encrypted: inbound.encrypted,
      decrypted: inbound.decrypted,
    );
    expect(handled, isTrue);

    final overview = core.accounts.getAccountOverview(alice);
    expect(overview.inboxCount, 1);
    expect(overview.outboxCount, 1);

    final inbox = core.accounts.listMailboxMessages(alice, Mailbox.inbox);
    expect(inbox.length, 1);
    expect(String.fromCharCodes(inbox.first.payload), 'hello alice');
    expect(inbox.first.isRead, isFalse);

    core.accounts.markMessageRead(alice, inbox.first.id);
    expect(
      core.accounts.listMailboxMessages(alice, Mailbox.inbox).first.isRead,
      true,
    );

    final outbox = core.accounts.listMailboxMessages(alice, Mailbox.outbox);
    expect(outbox.map((m) => m.id), [outbound.id]);
  });

  test('local message deletion blocks unexpired received messages', () async {
    final now = DateTime.utc(2026, 1, 1, 12, 0, 0);
    final core = _openCore(nowUtc: () => now);
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount('bob');
    final inbound = await _decodedMessage(
      sender: bob,
      recipient: alice,
      message: 'protected until expiry',
      messageIdSeed: 0x31,
    );
    await core.receive.materializeDecodedInbound(
      recipient: alice,
      encrypted: inbound.encrypted,
      decrypted: inbound.decrypted,
    );
    final received =
        core.accounts.listMailboxMessages(alice, Mailbox.inbox).single;
    final outbound = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(bob.address),
      text: 'allowed to delete',
      ttl: const Duration(hours: 1),
    );

    expect(canDeleteLocalMessage(received, now), isFalse);
    expect(
      () => core.accounts.deleteLocalMessages(
        alice,
        <MessageId>[outbound.id, received.id],
        now: now,
      ),
      throwsFormatException,
    );
    expect(
        core.accounts.listMailboxMessages(alice, Mailbox.inbox), hasLength(1));
    expect(
        core.accounts.listMailboxMessages(alice, Mailbox.outbox), hasLength(1));

    final afterExpiry = received.expiresAt.add(const Duration(seconds: 1));
    expect(
      core.accounts.deleteLocalMessages(
        alice,
        <MessageId>[received.id],
        now: afterExpiry,
      ),
      1,
    );
    expect(core.accounts.listMailboxMessages(alice, Mailbox.inbox), isEmpty);
  });

  test('decoded inbound ACK marks matching outbound message delivered',
      () async {
    final core = _openCore();
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final outbound = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(alice.address),
      text: 'hello self',
      ttl: const Duration(hours: 1),
    );
    core.outbox.markPowSynced(outbound.id);

    final ack = await _decodedAck(
      account: alice,
      ackedMessageId: outbound.id,
    );
    final handled = await core.receive.materializeDecodedInbound(
      recipient: alice,
      encrypted: ack.encrypted,
      decrypted: ack.decrypted,
    );
    expect(handled, isTrue);

    final outbox = core.accounts.listMailboxMessages(alice, Mailbox.outbox);
    expect(outbox.single.state, messageStateDelivered);
    expect(outbox.single.reliableDelivery, isTrue);
  });

  test('publish message stores PoW envelope sync blob and updates index',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final core = _openCore(nowUtc: () => now);
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount('bob');
    final message = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(bob.address),
      text: 'hello bob',
      ttl: const Duration(hours: 1),
    );
    final pow = _RecordingPowService();
    final encryptor = _RecordingEncryptor();

    final published = await core.outbox.publishMessage(
      message.id,
      pow: pow,
      encrypt: encryptor.call,
    );

    expect(published.message.state, messageStatePowSynced);
    expect(core.outbox.listPendingMessages(), isEmpty);
    expect(core.sync.totalSyncedMessages, 1);

    final envelope = PowEnvelope.fromBytes(published.syncBlob.blob);
    expect(envelope.y, _fakeProofY);
    expect(envelope.pi, _fakeProofPi);
    final encrypted = EncryptedMessage.fromBytes(envelope.object);
    expect(
      encrypted.streamNumber.toUint32(),
      Address.fromText(bob.address).streamId().toUint32(),
    );
    expect(encrypted.ttl, message.ttlSeconds);
    expect(encrypted.expiresTime, _unixSecondsForTest(message.expiresAt));
    expect(encrypted.payload, encryptor.ciphertexts.single);

    expect(pow.solves, hasLength(1));
    expect(pow.solves.single.inputHash, encrypted.powInputHash());
    expect(pow.solves.single.difficulty, published.difficulty);
    expect(
      published.difficulty,
      calculateDifficulty(
        base: core.config.loadActiveConfigCore(now).powBaseTarget,
        scaleDivisor: core.config.loadActiveConfigCore(now).powScaleDivisor,
        ttlSeconds: encrypted.ttl,
        payloadBytes: envelope.object.length,
      ),
    );
  });

  test('publish message embeds ACK blob when recipient requires ACK', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final core = _openCore(
      nowUtc: () => now,
      ttlDraw: (max) => max,
      expiresDraw: (max) => Duration.zero,
    );
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount(
      'bob',
      policy: addressPolicyAckExpected,
    );
    final message = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(bob.address),
      text: 'hello bob',
      ttl: const Duration(seconds: 100),
    );
    expect(message.reliableDelivery, isTrue);
    final pow = _RecordingPowService();
    final encryptor = _RecordingEncryptor();

    final published = await core.outbox.publishMessage(
      message.id,
      pow: pow,
      encrypt: encryptor.call,
    );

    expect(pow.solves, hasLength(2));
    expect(pow.verifications, hasLength(1));
    expect(encryptor.plaintexts, hasLength(2));
    expect(core.sync.totalSyncedMessages, 1);

    final ackPlaintext = UnencryptedMessage.fromBytes(encryptor.plaintexts[0]);
    await ackPlaintext.validate();
    expect(ackPlaintext.sender.toText(), alice.address);
    expect(ackPlaintext.messageType, MessageType.ack);
    expect(MessageId(ackPlaintext.message), message.id);
    expect(ackPlaintext.ackData, isEmpty);

    final outerPlaintext =
        UnencryptedMessage.fromBytes(encryptor.plaintexts[1]);
    await outerPlaintext.validate();
    expect(outerPlaintext.messageType, MessageType.plain);
    expect(outerPlaintext.ackData, isNotEmpty);

    final ackEnvelope = PowEnvelope.fromBytes(outerPlaintext.ackData);
    final ackEncrypted = EncryptedMessage.fromBytes(ackEnvelope.object);
    expect(
      ackEncrypted.streamNumber.toUint32(),
      Address.fromText(alice.address).streamId().toUint32(),
    );
    expect(ackEncrypted.ttl, 121);
    expect(
      ackEncrypted.expiresTime,
      _unixSecondsForTest(message.createdAt.add(const Duration(seconds: 100))),
    );

    final storedEnvelope = PowEnvelope.fromBytes(published.syncBlob.blob);
    final storedEncrypted = EncryptedMessage.fromBytes(storedEnvelope.object);
    expect(
      storedEncrypted.streamNumber.toUint32(),
      Address.fromText(bob.address).streamId().toUint32(),
    );
  });

  test('retry expired reliable delivery republishes with refreshed expiry',
      () async {
    var now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final core = _openCore(nowUtc: () => now);
    addTearDown(core.close);

    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount(
      'bob',
      policy: addressPolicyAckExpected,
    );
    final message = core.messaging.sendTextMessage(
      sender: alice,
      recipient: Address.fromText(bob.address),
      text: 'hello bob',
      ttl: const Duration(hours: 1),
    );
    final pow = _RecordingPowService();
    final encryptor = _RecordingEncryptor();

    await core.outbox.publishMessage(
      message.id,
      pow: pow,
      encrypt: encryptor.call,
    );

    now = DateTime.utc(2026, 4, 19, 12, 0, 0);
    final retried = await core.outbox.retryExpiredReliableDelivery(
      now: now,
      pow: pow,
      encrypt: encryptor.call,
    );

    expect(retried, hasLength(1));
    expect(retried.single.message.id, message.id);
    expect(retried.single.message.createdAt, message.createdAt);
    expect(retried.single.message.updatedAt, now);
    expect(retried.single.message.expiresAt, now.add(const Duration(hours: 1)));
    expect(retried.single.message.state, messageStatePowSynced);
    expect(pow.solves, hasLength(4));

    final envelope = PowEnvelope.fromBytes(retried.single.syncBlob.blob);
    final encrypted = EncryptedMessage.fromBytes(envelope.object);
    expect(encrypted.ttl, 3600);
    expect(
      encrypted.expiresTime,
      _unixSecondsForTest(now.add(const Duration(hours: 1))),
    );
  });

  test('publish ephemeral random message stores only sync blob', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final dir = Directory.systemTemp.createTempSync('ddm-ephemeral-runtime-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final storage = DdmSqliteStorage.open('${dir.path}/ddmdb.sqlite');
    final core = DdmCore.fromStorage(
      storage,
      nowUtc: () => now,
      ttlJitterDraw: (max) => max,
      expiresJitterDraw: (max) =>
          Duration(microseconds: max.inMicroseconds ~/ 2),
      randomBytes: (length) => Uint8List.fromList(
        List<int>.generate(length, (index) => (index + 1) & 0xff),
      ),
    );
    addTearDown(core.close);
    final pow = _RecordingPowService();
    final encryptor = _RecordingEncryptor();

    final published = await core.outbox.publishEphemeralRandomMessage(
      pow: pow,
      ttl: const Duration(days: 2),
      minPayloadBytes: 512,
      maxPayloadBytes: 16 * 1024,
      encrypt: encryptor.call,
    );

    expect(storage.messages.listMessages(), isEmpty);
    expect(storage.syncBlobs.listSyncBlobIndexRecords(), hasLength(1));
    expect(core.outbox.listPendingMessages(), isEmpty);
    expect(core.sync.totalSyncedMessages, 1);
    expect(pow.solves, hasLength(1));

    final envelope = PowEnvelope.fromBytes(published.syncBlob.blob);
    final encrypted = EncryptedMessage.fromBytes(envelope.object);
    final plaintext = UnencryptedMessage.fromBytes(encryptor.plaintexts.single);
    await plaintext.validate();

    expect(plaintext.messageType, MessageType.binary);
    expect(plaintext.sender.requiresAck, isFalse);
    expect(plaintext.message.length, inInclusiveRange(512, 16 * 1024));
    expect(encrypted.streamNumber.toUint32(), isNonZero);
    expect(
      encrypted.expiresTime,
      _unixSecondsForTest(
        now.add(const Duration(days: 2, hours: 1, minutes: 12)),
      ),
    );
  });

  test('sync import decrypts local-recipient blobs into inbox', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final aliceCore = _openCore(nowUtc: () => now);
    addTearDown(aliceCore.close);
    final bobCore = _openCore(nowUtc: () => now);
    addTearDown(bobCore.close);

    final alice = await aliceCore.accounts.createAccount('alice');
    final bob = await bobCore.accounts.createAccount('bob');
    final outbound = bobCore.messaging.sendTextMessage(
      sender: bob,
      recipient: Address.fromText(alice.address),
      text: 'hello synced alice',
      ttl: const Duration(hours: 1),
    );
    await bobCore.outbox.publishMessage(
      outbound.id,
      pow: _RecordingPowService(),
    );

    final received = await aliceCore.sync.importFrom(
      source: bobCore.sync.localSource,
      verifyPow: ({
        required Uint8List modulus,
        required Uint8List input,
        required int difficulty,
        required Uint8List y,
        required Uint8List pi,
      }) =>
          true,
    );

    expect(received, 1);
    final inbox = aliceCore.accounts.listMailboxMessages(alice, Mailbox.inbox);
    expect(inbox, hasLength(1));
    expect(String.fromCharCodes(inbox.single.payload), 'hello synced alice');
    expect(inbox.single.senderAddress, bob.address);
    expect(inbox.single.recipientAddress, alice.address);
  });

  test('sync import publishes embedded ACK for received message', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final aliceCore = _openCore(nowUtc: () => now);
    addTearDown(aliceCore.close);
    final bobCore = _openCore(nowUtc: () => now);
    addTearDown(bobCore.close);

    final alice = await aliceCore.accounts.createAccount(
      'alice',
      policy: addressPolicyAckExpected,
    );
    final bob = await bobCore.accounts.createAccount('bob');
    final outbound = bobCore.messaging.sendTextMessage(
      sender: bob,
      recipient: Address.fromText(alice.address),
      text: 'hello acked alice',
      ttl: const Duration(hours: 1),
    );
    await bobCore.outbox.publishMessage(
      outbound.id,
      pow: _RecordingPowService(),
    );

    final received = await aliceCore.sync.importFrom(
      source: bobCore.sync.localSource,
      verifyPow: _acceptPow,
    );

    expect(received, 1);
    final inbox = aliceCore.accounts.listMailboxMessages(alice, Mailbox.inbox);
    expect(inbox, hasLength(1));
    expect(String.fromCharCodes(inbox.single.payload), 'hello acked alice');
    expect(inbox.single.reliableDelivery, isTrue);

    expect(aliceCore.sync.totalSyncedMessages, 2);

    await bobCore.sync.importFrom(
      source: aliceCore.sync.localSource,
      verifyPow: _acceptPow,
    );
    final outbox = bobCore.accounts.listMailboxMessages(bob, Mailbox.outbox);
    expect(outbox.single.state, messageStateDelivered);
  });

  test('runtime starts HTTP server and registers HTTP sources', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final core = _openCore(nowUtc: () => now);
    addTearDown(core.close);

    await core.transports.addSource('http://127.0.0.1:8080');
    expect(core.transports.sourceIds(), ['http://127.0.0.1:8080/']);

    final server = await core.transports.startHttpServer(
      listenAddress: '127.0.0.1:0',
    );
    final bound = server.boundUri.toString();

    expect(
      core.transports.registeredSourceProtocols(),
      [
        fileTransportProtocolName,
        httpTransportProtocolName,
        p2pTransportProtocolName,
      ],
    );
    await core.transports.addSource(bound);
    expect(
      core.transports.sourceIds(),
      unorderedEquals(<String>['http://127.0.0.1:8080/', bound]),
    );

    final client = HttpSyncSourceClient(bound);
    addTearDown(client.stop);
    final root = await client.getMessageIndexRoot();
    expect(root, isNotNull);

    await core.transports.stopServers();
    expect(core.transports.registeredSourceProtocols(), isEmpty);
  });

  test('runtime starts P2P discovery server while restoring sources', () async {
    final generated = Uint8List.fromList(<int>[7, 8, 9, 10]);
    final backend = _RecordingP2pBackend();
    final core = _openCore(
      runtimeOptions: DdmCoreRuntimeOptions(
        p2p: RuntimeP2pOptions(
          backend: backend,
          listenAddrs: '/ip4/127.0.0.1/tcp/0',
        ),
      ),
    );
    addTearDown(core.close);

    final first = await core.p2pIdentity.loadOrCreatePrivateKey(
      generatePrivateKey: () => generated,
    );
    final second = await core.p2pIdentity.loadOrCreatePrivateKey(
      generatePrivateKey: () => Uint8List.fromList(<int>[1]),
    );
    expect(first, generated);
    expect(second, generated);

    await core.transports.restoreRegisteredSources();
    await core.transports.discoverPeers();

    expect(core.transports.registeredSourceProtocols(),
        contains(p2pTransportProtocolName));
    expect(backend.privateKey, generated);
    expect(backend.listenAddrs, ['/ip4/127.0.0.1/tcp/0']);
    await core.transports.stopServers();
    expect(backend.stopped, isTrue);
  });

  test('runtime restores built-in P2P peer exchange sources', () async {
    final backend = _RecordingP2pBackend();
    final core = _openCore(
      runtimeOptions: DdmCoreRuntimeOptions(
        p2p: RuntimeP2pOptions(
          backend: backend,
          listenAddrs: '/ip4/127.0.0.1/tcp/0',
        ),
      ),
    );
    addTearDown(core.close);

    await core.transports.restoreRegisteredSources();
    await core.transports.discoverPeers();

    expect(core.transports.sourceIds(), containsAll(defaultPeerExchangeAddrs));
    expect(backend.privateKey, isNotNull);
    expect(backend.listenAddrs, ['/ip4/127.0.0.1/tcp/0']);

    await core.transports.restoreRegisteredSources();
    expect(core.transports.sourceIds(), containsAll(defaultPeerExchangeAddrs));
  });

  test('TTL jitter helpers match Go boundary behavior', () {
    final randomJitter = randomDurationUpToInclusive(
      const Duration(hours: 48),
    );
    expect(randomJitter >= Duration.zero, isTrue);
    expect(randomJitter <= const Duration(hours: 48), isTrue);

    final jittered = deriveJitteredTTLsWith(
      const Duration(seconds: 100),
      ttlDraw: (max) => Duration.zero,
      expiresDraw: (max) => max,
    );
    expect(jittered.powTTL, const Duration(seconds: 100));
    expect(jittered.expiresTTL, jittered.powTTL);

    final createdAt = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final ack = deriveAckJitteredTTLWith(
      createdAt: createdAt,
      baseTTLSeconds: 100,
      baseExpiresAt: createdAt.add(const Duration(seconds: 80)),
      ttlDraw: (max) => max,
      expiresDraw: (max) => max,
    );
    expect(ack.ttlSeconds, 110);
    expect(ack.expiresAt, createdAt.add(const Duration(seconds: 84)));
  });
}

final class _RecordingEncryptor {
  final List<Uint8List> plaintexts = <Uint8List>[];
  final List<Uint8List> ciphertexts = <Uint8List>[];

  Future<Uint8List> call({
    required Address recipient,
    required Uint8List plaintext,
  }) async {
    plaintexts.add(Uint8List.fromList(plaintext));
    final ciphertext = Uint8List.fromList(<int>[
      recipient.streamId().toBytes()[0],
      recipient.streamId().toBytes()[1],
      recipient.streamId().toBytes()[2],
      recipient.streamId().toBytes()[3],
      ...plaintext.take(12),
    ]);
    ciphertexts.add(ciphertext);
    return ciphertext;
  }
}

final class _RecordingPowService implements PowService {
  final List<_SolveCall> solves = <_SolveCall>[];
  final List<_VerifyCall> verifications = <_VerifyCall>[];

  @override
  Future<PowSolveResult> solve({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    void Function(PowSolveProgress progress)? onProgress,
  }) async {
    solves.add(
      _SolveCall(
        inputHash: Uint8List.fromList(inputHash),
        difficulty: difficulty,
      ),
    );
    onProgress?.call(const PowSolveProgress(
      completion: 1,
      elapsed: Duration(milliseconds: 1),
    ));
    return PowSolveResult(
      y: _fakeProofY,
      pi: _fakeProofPi,
      elapsed: const Duration(milliseconds: 1),
    );
  }

  @override
  Future<bool> verify({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    required Uint8List y,
    required Uint8List pi,
  }) async {
    verifications.add(
      _VerifyCall(
        inputHash: Uint8List.fromList(inputHash),
        difficulty: difficulty,
      ),
    );
    return true;
  }
}

final class _RecordingP2pBackend implements P2pHostBackend {
  Uint8List? privateKey;
  List<String> listenAddrs = const <String>[];
  bool stopped = false;

  @override
  Future<void> start({
    required Uint8List privateKey,
    required SyncSource source,
    required List<String> listenAddrs,
    required bool publicRelay,
    required P2pDiscoveryPeerPool discoveryPool,
  }) async {
    this.privateKey = Uint8List.fromList(privateKey);
    this.listenAddrs = List<String>.from(listenAddrs);
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<SyncSource> createPeerSource(String id) async {
    return _StubSyncSource(id: id);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];
}

final class _StubSyncSource implements SyncSource {
  _StubSyncSource({required this.id});

  @override
  final String id;

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(0);

  @override
  Future<List<ConfigRecord>> getConfigs() async => const <ConfigRecord>[];

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async => null;

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async =>
      null;

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async =>
      List<SyncBlob?>.filled(ids.length, null);

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {}

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}

final class _SolveCall {
  const _SolveCall({required this.inputHash, required this.difficulty});

  final Uint8List inputHash;
  final int difficulty;
}

final class _VerifyCall {
  const _VerifyCall({required this.inputHash, required this.difficulty});

  final Uint8List inputHash;
  final int difficulty;
}

final Uint8List _fakeProofY = Uint8List.fromList(
  List<int>.generate(powProofComponentSize, (i) => (i + 1) & 0xff),
);

final Uint8List _fakeProofPi = Uint8List.fromList(
  List<int>.generate(powProofComponentSize, (i) => (i + 17) & 0xff),
);

DdmCore _openCore({
  UtcNow? nowUtc,
  DurationJitterDraw? ttlDraw,
  DurationJitterDraw? expiresDraw,
  DdmCoreRuntimeOptions runtimeOptions = const DdmCoreRuntimeOptions(),
}) {
  final dir = Directory.systemTemp.createTempSync('ddm-runtime-');
  var randomCall = 0;
  final coreSeed = _nextCoreSeed++;
  return DdmCore.open(
    dir.path,
    nowUtc: nowUtc,
    randomBytes: (length) {
      randomCall++;
      return _deterministicBytes(length, randomCall + coreSeed);
    },
    ttlJitterDraw: ttlDraw ?? ((max) => Duration.zero),
    expiresJitterDraw: expiresDraw ?? ((max) => Duration.zero),
    runtimeOptions: runtimeOptions,
  );
}

int _nextCoreSeed = 1;

Future<({EncryptedMessage encrypted, UnencryptedMessage decrypted})>
    _decodedMessage({
  required AccountRecord sender,
  required AccountRecord recipient,
  required String message,
  required int messageIdSeed,
}) async {
  final decrypted = await UnencryptedMessage.signed(
    privateKey: sender.privateKey,
    messageId: _bytes16(messageIdSeed),
    sender: Address.fromText(sender.address),
    messageType: MessageType.plain,
    message: Uint8List.fromList(message.codeUnits),
  );
  return (
    encrypted: EncryptedMessage(
      version: encryptedMessageVersionV1,
      ttl: 3600,
      expiresTime: 1770000000,
      streamNumber: recipient.streamId,
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    ),
    decrypted: decrypted,
  );
}

Future<({EncryptedMessage encrypted, UnencryptedMessage decrypted})>
    _decodedAck({
  required AccountRecord account,
  required MessageId ackedMessageId,
}) async {
  final decrypted = await UnencryptedMessage.signed(
    privateKey: account.privateKey,
    messageId: _bytes16(0x90),
    sender: Address.fromText(account.address),
    messageType: MessageType.ack,
    message: ackedMessageId.toBytes(),
  );
  return (
    encrypted: EncryptedMessage(
      version: encryptedMessageVersionV1,
      ttl: 3600,
      expiresTime: 1770000000,
      streamNumber: account.streamId,
      payload: Uint8List.fromList(<int>[4, 5, 6]),
    ),
    decrypted: decrypted,
  );
}

Uint8List _deterministicBytes(int length, int call) {
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = (i + length + call) & 0xff;
  }
  return out;
}

Uint8List _bytes16(int seed) {
  final out = Uint8List(16);
  for (var i = 0; i < out.length; i++) {
    out[i] = (seed + i) & 0xff;
  }
  return out;
}

int _unixSecondsForTest(DateTime value) {
  return value.toUtc().millisecondsSinceEpoch ~/ 1000;
}

bool _acceptPow({
  required Uint8List modulus,
  required Uint8List input,
  required int difficulty,
  required Uint8List y,
  required Uint8List pi,
}) {
  return true;
}
