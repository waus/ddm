part of '../runtime.dart';

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
    required BlobIndex index,
    required this.accounts,
    required this.contacts,
    required this.config,
    required this.messaging,
    required this.receive,
    required this.outbox,
    required this.sync,
    required this.transports,
    required this.p2pIdentity,
    required this.runtimeOptions,
  })  : _storage = storage,
        _index = index;

  final DdmSqliteStorage _storage;
  final BlobIndex _index;
  final AccountsService accounts;
  final ContactsService contacts;
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
    final now = nowUtc ?? defaultRuntimeUtcNow;
    final bytes = randomBytes ?? secureRandomBytes;
    final ttlDraw = ttlJitterDraw ?? randomDurationUpToInclusive;
    final expiresDraw = expiresJitterDraw ?? randomDurationUpToInclusive;
    final configManager = ConfigManager(storage: storage.configs, nowUtc: now);
    final config = ConfigService(configs: configManager);
    final accountManager = AccountManager(storage: storage);
    final accounts = AccountsService(
      storage: storage,
      accountManager: accountManager,
      nowUtc: now,
      randomBytes: bytes,
    );
    final contacts = ContactsService(storage: storage);
    final messaging = MessagingService(
      storage: storage,
      nowUtc: now,
      randomBytes: bytes,
    );
    final index = BlobIndex.fromStorage(storage: storage, nowUtc: now);
    final receive = ReceiveService(
      index: index,
      storage: storage,
      accountManager: accountManager,
      nowUtc: now,
    );
    final sync = SyncService(
      index: index,
      storage: storage,
      configs: configManager,
      nowUtc: now,
      onImportedBlob: receive.materializeImportedEncrypted,
    );
    final outbox = OutboxService(
      storage: storage,
      accountManager: accountManager,
      nowUtc: now,
      randomBytes: bytes,
      ttlJitterDraw: ttlDraw,
      expiresJitterDraw: expiresDraw,
      index: index,
      configs: configManager,
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
      index: index,
      storage: storage,
      accounts: accounts,
      contacts: contacts,
      config: config,
      messaging: messaging,
      receive: receive,
      outbox: outbox,
      sync: sync,
      transports: transports,
      p2pIdentity: p2pIdentity,
      runtimeOptions: runtimeOptions,
    );
    return core;
  }

  void close() {
    transports.close();
    sync.close();
    _index.close();
    _storage.close();
  }
}
