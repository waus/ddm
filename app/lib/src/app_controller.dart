import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'constants.dart';
import 'macos_file_picker.dart';

typedef AppPowVerifier = FutureOr<bool> Function({
  required List<int> modulus,
  required List<int> input,
  required int difficulty,
  required List<int> y,
  required List<int> pi,
});

typedef ExternalPowerCheck = Future<bool> Function();

final class AppDependencies {
  const AppDependencies({
    this.workspacePath,
    this.verifyPow,
    this.powService = const VdfPowService(),
    this.runtimeOptions = const DdmCoreRuntimeOptions(),
    this.externalPowerCheck = externalPowerCheckWithBatteryPlus,
    this.noiseGeneratorInterval = defaultNoiseGeneratorInterval,
    this.noiseGeneratorTTL = defaultMessageTTL,
    this.noiseGeneratorMinPayloadBytes = defaultNoiseGeneratorMinPayloadBytes,
    this.noiseGeneratorMaxPayloadBytes = defaultNoiseGeneratorMaxPayloadBytes,
  });

  final String? workspacePath;
  final AppPowVerifier? verifyPow;
  final PowService powService;
  final DdmCoreRuntimeOptions runtimeOptions;
  final ExternalPowerCheck externalPowerCheck;
  final Duration noiseGeneratorInterval;
  final Duration noiseGeneratorTTL;
  final int noiseGeneratorMinPayloadBytes;
  final int noiseGeneratorMaxPayloadBytes;
}

final appDependenciesProvider = Provider<AppDependencies>((ref) {
  return const AppDependencies();
});

final appControllerProvider = StateNotifierProvider<AppController, AppState>((
  ref,
) {
  final controller = AppController(ref.watch(appDependenciesProvider));
  ref.onDispose(controller.close);
  unawaited(controller.initialize());
  return controller;
});

final class AppController extends StateNotifier<AppState> {
  AppController(this._dependencies) : super(const AppState());

  final AppDependencies _dependencies;
  DdmCore? _core;
  Timer? _backgroundSyncTimer;
  Timer? _backgroundDiscoveryTimer;
  Timer? _backgroundPeerExchangeTimer;
  Timer? _reliableDeliveryRetryStartupTimer;
  Timer? _reliableDeliveryRetryTimer;
  Timer? _noiseGeneratorTimer;
  bool _backgroundStarted = false;
  bool _backgroundSyncRunning = false;
  bool _backgroundDiscoveryRunning = false;
  bool _backgroundPeerExchangeRunning = false;
  bool _reliableDeliveryRetryRunning = false;
  bool _outboxPublishRunning = false;
  bool _outboxPublishRequested = false;
  bool _noiseGeneratorRunning = false;
  bool _closed = false;

  Future<void> initialize() async {
    try {
      final workspacePath =
          _dependencies.workspacePath ?? await _defaultWorkspacePath();
      final core = DdmCore.open(
        workspacePath,
        runtimeOptions: _dependencies.runtimeOptions,
      );
      _core = core;
      _refreshState(core, section: AppSection.accounts);
      unawaited(_publishPendingOutbox(core));
      unawaited(_startReliableDeliveryRetry(core));
      unawaited(_startNoiseGenerator(core));
      if (core.runtimeOptions.transports.backgroundSyncEnabled) {
        unawaited(_startBackgroundSync(core));
      }
    } catch (error) {
      state = state.copyWith(
        status: AppLoadStatus.failed,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> createAccount(String name, {bool silent = false}) async {
    final core = _requireCore();
    try {
      await core.accounts.createAccount(
        name,
        policy: silent ? 0 : addressPolicyAckExpected,
      );
      _refreshState(core, section: AppSection.accounts, clearError: true);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  void selectSection(AppSection section) {
    state = state.copyWith(section: section, clearError: true);
  }

  void selectAccount(AccountRecord account) {
    final core = _requireCore();
    final messages = core.accounts.listMailboxMessages(account, state.mailbox);
    state = state.copyWith(
      section: AppSection.mailbox,
      selectedAccount: account,
      messages: messages,
      clearSelectedMessage: true,
      clearError: true,
      sync: _diagnostics(core),
    );
  }

  void selectMailbox(Mailbox mailbox) {
    final core = _requireCore();
    final account = state.selectedAccount ?? state.accounts.firstOrNull;
    state = state.copyWith(
      section: AppSection.mailbox,
      mailbox: mailbox,
      selectedAccount: account,
      messages: account == null
          ? const <MessageRecord>[]
          : core.accounts.listMailboxMessages(account, mailbox),
      clearSelectedMessage: true,
      clearError: true,
      sync: _diagnostics(core),
    );
  }

  void selectAccountMailbox(AccountRecord account, Mailbox mailbox) {
    final core = _requireCore();
    state = state.copyWith(
      section: AppSection.mailbox,
      mailbox: mailbox,
      selectedAccount: account,
      messages: core.accounts.listMailboxMessages(account, mailbox),
      clearSelectedMessage: true,
      clearError: true,
      sync: _diagnostics(core),
    );
  }

  int mailboxMessageCount(AccountRecord account, Mailbox mailbox) {
    final core = _requireCore();
    return core.accounts.listMailboxMessages(account, mailbox).length;
  }

  int unreadMailboxMessageCount(AccountRecord account, Mailbox mailbox) {
    final core = _requireCore();
    return core.accounts
        .listMailboxMessages(account, mailbox)
        .where((message) => !message.isRead)
        .length;
  }

  void selectMessage(MessageRecord message) {
    final core = _requireCore();
    final account = state.selectedAccount;
    var selected = message;
    var messages = state.messages;
    try {
      if (state.mailbox == Mailbox.inbox &&
          account != null &&
          !message.isRead) {
        core.accounts.markMessageRead(account, message.id);
        messages = core.accounts.listMailboxMessages(account, state.mailbox);
        for (final refreshed in messages) {
          if (refreshed.id == message.id) {
            selected = refreshed;
            break;
          }
        }
      }
      state = state.copyWith(
        messages: messages,
        selectedMessage: selected,
        clearError: true,
        sync: _diagnostics(core),
      );
    } catch (error) {
      state = state.copyWith(
        selectedMessage: selected,
        errorMessage: error.toString(),
        sync: _diagnostics(core),
      );
    }
  }

  Future<void> sendText({
    required AccountRecord sender,
    required String recipientAddress,
    required String text,
    Duration ttl = defaultMessageTTL,
  }) async {
    final core = _requireCore();
    try {
      final message = core.messaging.sendTextMessage(
        sender: sender,
        recipient: Address.fromText(recipientAddress),
        text: text,
        ttl: ttl,
      );
      final messages = core.accounts.listMailboxMessages(
        sender,
        Mailbox.outbox,
      );
      state = state.copyWith(
        section: AppSection.mailbox,
        mailbox: Mailbox.outbox,
        selectedAccount: sender,
        messages: messages,
        clearSelectedMessage: true,
        clearError: true,
        sync: _diagnostics(core).copyWith(
          powActivity: 'Queued',
          lastSyncMessage: 'Outbox message queued',
        ),
      );
      _appDebug('outbox message queued id=${message.id.toHex()}');
      unawaited(_publishPendingOutbox(core));
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<void> addSource(String sourceText) async {
    final core = _requireCore();
    final sourceId = sourceText.trim();
    _appDebug('source add requested source=$sourceId');
    state = state.copyWith(
      section: AppSection.diagnostics,
      sync: _diagnostics(core).copyWith(
        status: SyncRunStatus.running,
        powActivity: 'Adding source',
        lastSyncMessage: 'Adding source',
      ),
      clearError: true,
    );

    try {
      await core.transports.addSource(sourceId);
      _appDebug('source added id=$sourceId');
      state = _stateWithRuntimeSnapshot(
        core,
        sync: _diagnostics(core).copyWith(
          status: SyncRunStatus.succeeded,
          powActivity: 'Idle',
          lastSyncMessage: 'Source added',
        ),
        clearError: true,
      );
    } catch (error) {
      _appDebug('source add failed source=$sourceId error=$error');
      state = state.copyWith(
        errorMessage: error.toString(),
        sync: _diagnostics(core).copyWith(
          status: SyncRunStatus.failed,
          powActivity: 'Idle',
          lastSyncMessage: 'Source add failed',
        ),
      );
    }
  }

  Future<void> chooseExternalStorageFile([String? fileUrl]) async {
    if (!Platform.isMacOS) {
      return;
    }
    final selectedUrl =
        fileUrl ?? state.sync.externalStorageFileUrls.firstOrNull;
    if (selectedUrl == null) {
      return;
    }
    final pickedUrl = await pickMacOSSyncFile(selectedUrl);
    if (pickedUrl == null || pickedUrl.trim().isEmpty) {
      return;
    }
    await addSource(pickedUrl);
    final remaining = state.sync.externalStorageFileUrls
        .where((url) => url != selectedUrl && url != pickedUrl)
        .toList(growable: false);
    state = state.copyWith(
      sync: state.sync.copyWith(externalStorageFileUrls: remaining),
    );
  }

  void refresh() {
    final core = _requireCore();
    _refreshState(core, section: state.section, clearError: true);
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _backgroundSyncTimer?.cancel();
    _backgroundDiscoveryTimer?.cancel();
    _backgroundPeerExchangeTimer?.cancel();
    _reliableDeliveryRetryStartupTimer?.cancel();
    _reliableDeliveryRetryTimer?.cancel();
    _noiseGeneratorTimer?.cancel();
    _core?.close();
  }

  DdmCore _requireCore() {
    final core = _core;
    if (core == null) {
      throw StateError('DDM core is not initialized');
    }
    return core;
  }

  void _refreshState(
    DdmCore core, {
    required AppSection section,
    bool clearError = false,
  }) {
    final accounts = core.accounts.listAccounts();
    final selected = _selectCurrentAccount(accounts);
    final messages = selected == null
        ? const <MessageRecord>[]
        : core.accounts.listMailboxMessages(selected, state.mailbox);
    state = state.copyWith(
      status: AppLoadStatus.ready,
      section: accounts.isEmpty ? AppSection.accounts : section,
      accounts: accounts,
      selectedAccount: selected,
      clearSelectedAccount: selected == null,
      messages: messages,
      clearSelectedMessage: true,
      clearError: clearError,
      sync: _diagnostics(core),
    );
  }

  AccountRecord? _selectCurrentAccount(List<AccountRecord> accounts) {
    if (accounts.isEmpty) {
      return null;
    }
    final current = state.selectedAccount;
    if (current != null) {
      for (final account in accounts) {
        if (account.id == current.id) {
          return account;
        }
      }
    }
    return accounts.first;
  }

  SyncDiagnostics _diagnostics(DdmCore core) {
    return SyncDiagnostics(
      registeredProtocols: core.transports.registeredSourceProtocols(),
      onlinePeerCount: core.transports.sources.onlineCountSince(
        DateTime.now().toUtc().subtract(sourceOnlineWindow),
      ),
      totalPeerCount: core.transports.sources.sourceIds().length,
      totalSyncedMessages: core.sync.totalSyncedMessages,
      powActivity: state.sync.powActivity,
      powProgress: state.sync.powProgress,
      lastSyncMessage: state.sync.lastSyncMessage,
      status: state.sync.status,
      externalStorageFileUrls: state.sync.externalStorageFileUrls,
    );
  }

  FutureOr<bool> _verifyPow({
    required List<int> modulus,
    required List<int> input,
    required int difficulty,
    required List<int> y,
    required List<int> pi,
  }) {
    final verifier = _dependencies.verifyPow;
    if (verifier == null) {
      return _dependencies.powService.verify(
        modulus: Uint8List.fromList(modulus),
        inputHash: Uint8List.fromList(input),
        difficulty: difficulty,
        y: Uint8List.fromList(y),
        pi: Uint8List.fromList(pi),
      );
    }
    return verifier(
      modulus: modulus,
      input: input,
      difficulty: difficulty,
      y: y,
      pi: pi,
    );
  }

  Future<void> _startBackgroundSync(DdmCore core) async {
    if (_backgroundStarted || _closed) {
      return;
    }
    _backgroundStarted = true;
    final transportOptions = core.runtimeOptions.transports;
    _appDebug(
      'background sync starting sync_interval=${transportOptions.backgroundSyncInterval} '
      'discovery_interval=${transportOptions.discoveryInterval} '
      'pex_interval=${transportOptions.peerExchangeInterval}',
    );

    await core.transports.restoreRegisteredSources();

    unawaited(_runBackgroundDiscovery(core));
    unawaited(_runBackgroundPeerExchange(core));
    unawaited(_runBackgroundSync(core));

    _backgroundSyncTimer = Timer.periodic(
      transportOptions.backgroundSyncInterval,
      (_) => unawaited(_runBackgroundSync(core)),
    );
    _backgroundDiscoveryTimer = Timer.periodic(
      transportOptions.discoveryInterval,
      (_) => unawaited(_runBackgroundDiscovery(core)),
    );
    _backgroundPeerExchangeTimer = Timer.periodic(
      transportOptions.peerExchangeInterval,
      (_) => unawaited(_runBackgroundPeerExchange(core)),
    );
    _appDebug('background sync timers started');
  }

  Future<void> _startReliableDeliveryRetry(DdmCore core) async {
    if (_closed) {
      return;
    }
    _reliableDeliveryRetryStartupTimer?.cancel();
    _reliableDeliveryRetryTimer?.cancel();
    _reliableDeliveryRetryStartupTimer = Timer(
      reliableDeliveryRetryStartupDelay,
      () {
        if (_closed) {
          return;
        }
        unawaited(_runReliableDeliveryRetry(core));
        _reliableDeliveryRetryTimer = Timer.periodic(
          reliableDeliveryRetryInterval,
          (_) => unawaited(_runReliableDeliveryRetry(core)),
        );
      },
    );
    _appDebug(
      'reliable delivery retry timer scheduled '
      'startup_delay=$reliableDeliveryRetryStartupDelay '
      'interval=$reliableDeliveryRetryInterval',
    );
  }

  Future<void> _startNoiseGenerator(DdmCore core) async {
    if (_closed) {
      return;
    }
    _noiseGeneratorTimer?.cancel();
    final interval = _dependencies.noiseGeneratorInterval;
    _noiseGeneratorTimer = Timer.periodic(
      interval,
      (_) => unawaited(_runNoiseGeneratorTick(core)),
    );
    _appDebug('noise generator timer started interval=$interval');
  }

  Future<void> _runBackgroundSync(DdmCore core) async {
    if (_closed || _backgroundSyncRunning) {
      return;
    }
    _backgroundSyncRunning = true;
    try {
      final config = core.config.loadActiveConfigCore(DateTime.now().toUtc());
      final sources = core.transports.sources.getActive(10);
      _appDebug(
        'background sync tick selected=${sources.length} '
        'sources=${sources.map((source) => source.id).join(',')}',
      );
      for (final source in sources) {
        if (!source.flags.has(syncSourceFlagSupportTree)) {
          _appDebug('background sync skip unsupported source=${source.id}');
          continue;
        }
        try {
          final before = core.sync.totalSyncedMessages;
          final receivedBlobs = await core.sync.importFrom(
            source: source,
            currentConfig: config,
            verifyPow: _verifyPow,
          );
          final after = core.sync.totalSyncedMessages;
          if (receivedBlobs > 0) {
            source.increaseRatingConst(
              ratingGoodBlobReceived * receivedBlobs,
            );
          }
          _appDebug(
            'background sync source ok source=${source.id} '
            'received_blobs=$receivedBlobs blobs_before=$before '
            'blobs_after=$after rating=${source.rating}',
          );
        } catch (error) {
          if (!isSyncSourceUnavailableError(error)) {
            source.decreaseRatingMul(ratingReceivedSomethingStrange);
          }
          _appDebug(
            'background sync source failed source=${source.id} rating=${source.rating}',
          );
          _appDebug(
              'background sync source error source=${source.id} error=$error');
        }
      }
      core.transports.sources.saveUpdatedPeers();
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(core);
      }
    } catch (error) {
      _appDebug('background sync tick failed error=$error');
      _setBackgroundError(core, 'Background sync failed', error);
    } finally {
      _backgroundSyncRunning = false;
    }
  }

  Future<void> _runReliableDeliveryRetry(DdmCore core) async {
    if (_closed || _reliableDeliveryRetryRunning || _outboxPublishRunning) {
      return;
    }
    _reliableDeliveryRetryRunning = true;
    try {
      final now = DateTime.now().toUtc();
      final expired = core.outbox.listExpiredReliableDeliveryMessages(now);
      if (expired.isEmpty) {
        return;
      }
      _appDebug(
        'reliable delivery retry starting expired=${expired.length}',
      );
      final config = core.config.loadActiveConfigCore(now);
      final published = await core.outbox.retryExpiredReliableDelivery(
        now: now,
        activeConfig: config,
        pow: _dependencies.powService,
      );
      _appDebug(
        'reliable delivery retry completed published=${published.length}',
      );
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(core, clearError: true);
      }
    } catch (error) {
      _appDebug('reliable delivery retry failed error=$error');
    } finally {
      _reliableDeliveryRetryRunning = false;
    }
  }

  Future<void> _runNoiseGeneratorTick(DdmCore core) async {
    if (_closed || _noiseGeneratorRunning || _outboxPublishRunning) {
      return;
    }
    bool isCharging;
    try {
      isCharging = await _dependencies.externalPowerCheck();
    } catch (error) {
      _appDebug('noise generator power check failed error=$error');
      return;
    }
    if (!isCharging) {
      return;
    }
    _noiseGeneratorRunning = true;
    _appDebug('noise generator publish starting');
    state = _stateWithRuntimeSnapshot(
      core,
      sync: _diagnostics(core).copyWith(
        powActivity: 'Making noise',
        powProgress: 0,
        lastSyncMessage: 'Publishing noise blob',
      ),
    );
    try {
      final config = core.config.loadActiveConfigCore(DateTime.now().toUtc());
      await core.outbox.publishEphemeralRandomMessage(
        activeConfig: config,
        pow: _dependencies.powService,
        ttl: _dependencies.noiseGeneratorTTL,
        minPayloadBytes: _dependencies.noiseGeneratorMinPayloadBytes,
        maxPayloadBytes: _dependencies.noiseGeneratorMaxPayloadBytes,
        onPowProgress: (progress) {
          if (_closed) {
            return;
          }
          state = state.copyWith(
            sync: _diagnostics(core).copyWith(
              powActivity: 'Making noise',
              powProgress: progress.completion <= 0
                  ? 0
                  : progress.completion >= 1
                      ? 100
                      : (progress.completion * 100).round(),
              lastSyncMessage: 'Publishing noise blob',
            ),
          );
        },
      );
      _appDebug('noise generator publish completed');
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(
          core,
          sync: _diagnostics(core).copyWith(
            powActivity: 'Idle',
            powProgress: 0,
            lastSyncMessage: 'Noise blob published',
          ),
          clearError: true,
        );
      }
    } catch (error) {
      _appDebug('noise generator publish failed error=$error');
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(
          core,
          sync: _diagnostics(core).copyWith(
            powActivity: 'Idle',
            powProgress: 0,
            lastSyncMessage: 'Noise blob failed',
          ),
        ).copyWith(errorMessage: error.toString());
      }
    } finally {
      _noiseGeneratorRunning = false;
    }
  }

  Future<void> _runBackgroundDiscovery(DdmCore core) async {
    if (_closed || _backgroundDiscoveryRunning) {
      return;
    }
    _backgroundDiscoveryRunning = true;
    try {
      final peers = await core.transports.discoverPeers();
      _appDebug('background discovery tick peers=${peers.length}');
      final registeredSources = core.transports.sourceIds().toSet();
      final externalStorageFileUrls = <String>{
        ...state.sync.externalStorageFileUrls.where(
          (url) => !registeredSources.contains(url),
        ),
      };
      for (final peer in peers) {
        if (_isMacOSExternalStorageFile(peer)) {
          if (registeredSources.contains(peer)) {
            continue;
          }
          externalStorageFileUrls.add(peer);
          _appDebug(
              'background discovery external storage file found id=$peer');
          continue;
        }
        try {
          await _addSourceText(core, peer);
          _appDebug('background discovery source added id=$peer');
        } catch (error) {
          _appDebug(
              'background discovery source skipped id=$peer error=$error');
          // Discovery may return stale peers.
        }
      }
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(
          core,
          sync: _diagnostics(core).copyWith(
            externalStorageFileUrls: externalStorageFileUrls.toList()..sort(),
          ),
        );
      }
    } catch (error) {
      _appDebug('background discovery tick failed error=$error');
      // Discovery is opportunistic; direct sync attempts continue separately.
    } finally {
      _backgroundDiscoveryRunning = false;
    }
  }

  Future<void> _runBackgroundPeerExchange(DdmCore core) async {
    if (_closed || _backgroundPeerExchangeRunning) {
      return;
    }
    _backgroundPeerExchangeRunning = true;
    try {
      final sources = core.transports.sources.peerExchangeSources();
      _appDebug(
        'background pex tick sources=${sources.length} '
        'ids=${sources.map((source) => source.id).join(',')}',
      );
      for (final source in sources) {
        List<String> peers;
        try {
          peers = await source.discoverPeers();
          _appDebug(
            'background pex source ok source=${source.id} peers=${peers.length}',
          );
        } catch (error) {
          _appDebug(
              'background pex source failed source=${source.id} error=$error');
          continue;
        }
        for (final peer in peers) {
          try {
            await _addSourceText(core, peer);
            _appDebug('background pex source added id=$peer');
          } catch (error) {
            _appDebug('background pex source skipped id=$peer error=$error');
            // Peer exchange may return stale peers.
          }
        }
      }
    } catch (error) {
      _appDebug('background pex tick failed error=$error');
      // Peer exchange is opportunistic; direct sync attempts continue separately.
    } finally {
      _backgroundPeerExchangeRunning = false;
    }
  }

  Future<void> _publishPendingOutbox(DdmCore core) async {
    if (_closed) {
      return;
    }
    if (_outboxPublishRunning || _reliableDeliveryRetryRunning) {
      _outboxPublishRequested = true;
      return;
    }
    final pending = core.outbox.listPendingMessages();
    if (pending.isEmpty) {
      return;
    }
    _outboxPublishRunning = true;
    _outboxPublishRequested = false;
    _appDebug('outbox publish starting pending=${pending.length}');
    state = _stateWithRuntimeSnapshot(
      core,
      sync: _diagnostics(core).copyWith(
        powActivity: 'Solving',
        powProgress: 0,
        lastSyncMessage: 'Publishing outbox',
      ),
    );
    try {
      final config = core.config.loadActiveConfigCore(DateTime.now().toUtc());
      final published = await core.outbox.publishPendingMessages(
        activeConfig: config,
        pow: _dependencies.powService,
        onPowProgress: (progress) {
          if (_closed) {
            return;
          }
          state = state.copyWith(
            sync: _diagnostics(core).copyWith(
              powActivity: 'Solving',
              powProgress: progress.completion <= 0
                  ? 0
                  : progress.completion >= 1
                      ? 100
                      : (progress.completion * 100).round(),
              lastSyncMessage: 'Publishing outbox',
            ),
          );
        },
      );
      _appDebug('outbox publish completed published=${published.length}');
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(
          core,
          sync: _diagnostics(core).copyWith(
            powActivity: 'Idle',
            powProgress: 0,
            lastSyncMessage: 'Outbox published ${published.length}',
          ),
          clearError: true,
        );
      }
    } catch (error) {
      _appDebug('outbox publish failed error=$error');
      if (!_closed) {
        state = _stateWithRuntimeSnapshot(
          core,
          sync: _diagnostics(core).copyWith(
            powActivity: 'Idle',
            powProgress: 0,
            lastSyncMessage: 'Outbox publish failed',
          ),
        ).copyWith(errorMessage: error.toString());
      }
    } finally {
      _outboxPublishRunning = false;
      if (!_closed && _outboxPublishRequested) {
        unawaited(_publishPendingOutbox(core));
      }
    }
  }

  Future<void> _addSourceText(DdmCore core, String raw) async {
    final sourceId = raw.trim();
    await core.transports.addSource(sourceId);
    _appDebug('source registered raw=${raw.trim()} id=$sourceId');
  }

  void _setBackgroundError(DdmCore core, String message, Object error) {
    if (_closed) {
      return;
    }
    state = state.copyWith(
      errorMessage: '$message: $error',
      sync: _diagnostics(core).copyWith(
        status: SyncRunStatus.failed,
        powActivity: 'Idle',
        powProgress: 0,
        lastSyncMessage: message,
      ),
    );
  }

  AppState _stateWithRuntimeSnapshot(
    DdmCore core, {
    SyncDiagnostics? sync,
    bool clearError = false,
  }) {
    final accounts = core.accounts.listAccounts();
    final selected = _selectCurrentAccount(accounts);
    final messages = selected == null
        ? const <MessageRecord>[]
        : core.accounts.listMailboxMessages(selected, state.mailbox);
    return state.copyWith(
      status: AppLoadStatus.ready,
      section: accounts.isEmpty ? AppSection.accounts : state.section,
      accounts: accounts,
      selectedAccount: selected,
      clearSelectedAccount: selected == null,
      messages: messages,
      clearError: clearError,
      sync: sync ?? _diagnostics(core),
    );
  }

  Future<String> _defaultWorkspacePath() async {
    final dir = await getApplicationSupportDirectory();
    final workspace = Directory('${dir.path}/ddm');
    workspace.createSync(recursive: true);
    return workspace.path;
  }
}

bool _isMacOSExternalStorageFile(String value) {
  if (!Platform.isMacOS) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'file' &&
      uri.path.startsWith('/Volumes/');
}

void _appDebug(String message) {
  if (_isProductBuild) {
    return;
  }
  stderr.writeln('${DateTime.now().toIso8601String()} [ddm:app] $message');
}

bool _isChargingState(BatteryState state) {
  return state == BatteryState.charging || state == BatteryState.full;
}

Future<bool> externalPowerCheckWithBatteryPlus() async {
  return _isChargingState(await Battery().batteryState);
}

const bool _isProductBuild = bool.fromEnvironment('dart.vm.product');
