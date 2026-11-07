import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'constants.dart';
import 'macos_file_picker.dart';
import 'update_service.dart';

import 'app_controller/dependencies.dart';
import 'app_controller/environment.dart';

export 'app_controller/dependencies.dart';

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
  RuntimeWorker? _runtime;
  bool _updateCheckRunning = false;
  bool _closed = false;

  Future<void> initialize() async {
    try {
      await _loadAppVersion();
      final workspacePath =
          _dependencies.workspacePath ?? await _defaultWorkspacePath();
      final core = DdmCore.open(
        workspacePath,
        runtimeOptions: _dependencies.runtimeOptions,
        verifyPow: _verifyPow,
      );
      _core = core;
      _refreshState(core, section: AppSection.accounts);
      final runtime = RuntimeWorker(
        core: core,
        pow: _dependencies.powService,
        canGenerateNoise: _dependencies.externalPowerCheck,
        onEvent: _onRuntimeEvent,
        log: appDebug,
        noiseInterval: _dependencies.noiseGeneratorInterval,
        noiseTTL: _dependencies.noiseGeneratorTTL,
        noiseMinPayloadBytes: _dependencies.noiseGeneratorMinPayloadBytes,
        noiseMaxPayloadBytes: _dependencies.noiseGeneratorMaxPayloadBytes,
      );
      _runtime = runtime;
      runtime.start();
      unawaited(_checkForUpdate());
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
      contacts: core.contacts.listContacts(account),
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
      contacts: account == null
          ? const <ContactRecord>[]
          : core.contacts.listContacts(account),
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
      contacts: core.contacts.listContacts(account),
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
        contacts: core.contacts.listContacts(sender),
        messages: messages,
        clearSelectedMessage: true,
        clearError: true,
        sync: _diagnostics(core).copyWith(
          powActivity: 'Queued',
          lastSyncMessage: 'Outbox message queued',
        ),
      );
      appDebug('outbox message queued id=${message.id.toHex()}');
      unawaited(_runtime!.publishPending());
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<bool> addContact({
    required AccountRecord account,
    required String name,
    required String address,
  }) async {
    final core = _requireCore();
    try {
      core.contacts.addContact(
        account: account,
        name: name,
        address: Address.fromText(address),
      );
      final selected = state.selectedAccount ?? account;
      state = state.copyWith(
        selectedAccount: selected,
        contacts: core.contacts.listContacts(selected),
        clearError: true,
        sync: _diagnostics(core),
      );
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> deleteContact({
    required AccountRecord account,
    required String address,
  }) async {
    final core = _requireCore();
    try {
      final deleted = core.contacts.deleteContact(
        account: account,
        address: Address.fromText(address),
      );
      final selected = state.selectedAccount ?? account;
      state = state.copyWith(
        selectedAccount: selected,
        contacts: core.contacts.listContacts(selected),
        clearError: true,
        sync: _diagnostics(core),
      );
      return deleted;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> deleteMessages(List<MessageRecord> messages) async {
    if (messages.isEmpty) {
      return true;
    }
    final core = _requireCore();
    final account = state.selectedAccount;
    if (account == null) {
      state = state.copyWith(errorMessage: 'Select an account first');
      return false;
    }
    try {
      final ids = messages.map((message) => message.id).toList(growable: false);
      core.accounts.deleteLocalMessages(
        account,
        ids,
        now: DateTime.now().toUtc(),
      );
      final nextMessages = core.accounts.listMailboxMessages(
        account,
        state.mailbox,
      );
      final selectedMessage = state.selectedMessage;
      final selectedDeleted = selectedMessage != null &&
          ids.any((messageId) => messageId == selectedMessage.id);
      state = state.copyWith(
        messages: nextMessages,
        clearSelectedMessage: selectedDeleted,
        clearError: true,
        sync: _diagnostics(core),
      );
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  void refreshContacts(AccountRecord account) {
    final core = _requireCore();
    final local = _selectAccountById(core.accounts.listAccounts(), account.id);
    if (local == null) {
      return;
    }
    state = state.copyWith(
      selectedAccount: local,
      contacts: core.contacts.listContacts(local),
      clearError: true,
      sync: _diagnostics(core),
    );
  }

  Future<void> addSource(String sourceText) async {
    final core = _requireCore();
    final sourceId = sourceText.trim();
    appDebug('source add requested source=$sourceId');
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
      appDebug('source added id=$sourceId');
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
      appDebug('source add failed source=$sourceId error=$error');
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

  Future<void> openUpdateSite() async {
    final opened = await _dependencies.urlOpener(Uri.parse(updateSiteUrl));
    if (!opened && !_closed) {
      state = state.copyWith(errorMessage: 'Could not open $updateSiteUrl');
    }
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
    _runtime?.close();
    _core?.close();
  }

  Future<void> _loadAppVersion() async {
    try {
      final appVersion = await _dependencies.appVersionLoader();
      if (!_closed) {
        state = state.copyWith(appVersion: appVersion);
      }
    } catch (error) {
      appDebug('app version load failed error=$error');
    }
  }

  Future<void> _checkForUpdate() async {
    final appVersion = state.appVersion;
    if (_closed || _updateCheckRunning || appVersion == null) {
      return;
    }
    _updateCheckRunning = true;
    try {
      final update = await _dependencies.updateChecker(appVersion);
      if (_closed || update == null) {
        return;
      }
      state = state.copyWith(
        update: update.isNewerThan(appVersion.version) ? update : null,
        clearUpdate: !update.isNewerThan(appVersion.version),
      );
    } catch (error) {
      appDebug('update check failed error=$error');
    } finally {
      _updateCheckRunning = false;
    }
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
    final contacts = selected == null
        ? const <ContactRecord>[]
        : core.contacts.listContacts(selected);
    state = state.copyWith(
      status: AppLoadStatus.ready,
      section: accounts.isEmpty ? AppSection.accounts : section,
      accounts: accounts,
      contacts: contacts,
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

  AccountRecord? _selectAccountById(List<AccountRecord> accounts, int id) {
    for (final account in accounts) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
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

  void _onRuntimeEvent(RuntimeEvent event) {
    if (_closed) return;
    final core = _requireCore();
    switch (event.operation) {
      case RuntimeOperation.sync:
        if (event.phase == RuntimePhase.failed) {
          state = state.copyWith(
            errorMessage: 'Background sync failed: ${event.error}',
            sync: _diagnostics(core).copyWith(
              status: SyncRunStatus.failed,
              powActivity: 'Idle',
              powProgress: 0,
              lastSyncMessage: 'Background sync failed',
            ),
          );
        } else {
          state = _stateWithRuntimeSnapshot(core);
        }
      case RuntimeOperation.discovery:
        final registered = core.transports.sourceIds().toSet();
        final files = <String>{
          ...state.sync.externalStorageFileUrls,
          ...event.externalStorageFiles.map((file) => file.toString()),
        }..removeWhere(registered.contains);
        state = _stateWithRuntimeSnapshot(
          core,
          sync: _diagnostics(core).copyWith(
            externalStorageFileUrls: files.toList()..sort(),
          ),
        );
      case RuntimeOperation.reliableDelivery:
        state = _stateWithRuntimeSnapshot(core, clearError: true);
      case RuntimeOperation.outbox:
      case RuntimeOperation.noise:
        final noise = event.operation == RuntimeOperation.noise;
        final active = event.phase == RuntimePhase.started ||
            event.phase == RuntimePhase.progress;
        final failed = event.phase == RuntimePhase.failed;
        final message = switch (event.phase) {
          RuntimePhase.started ||
          RuntimePhase.progress =>
            noise ? 'Publishing noise blob' : 'Publishing outbox',
          RuntimePhase.completed => noise
              ? 'Noise blob published'
              : 'Outbox published ${event.publishedCount}',
          RuntimePhase.failed =>
            noise ? 'Noise blob failed' : 'Outbox publish failed',
        };
        final sync = _diagnostics(core).copyWith(
          powActivity: active ? (noise ? 'Making noise' : 'Solving') : 'Idle',
          powProgress:
              active ? (event.completion.clamp(0, 1) * 100).round() : 0,
          lastSyncMessage: message,
        );
        if (event.phase == RuntimePhase.progress) {
          state = state.copyWith(sync: sync);
        } else {
          state = _stateWithRuntimeSnapshot(core,
              sync: sync, clearError: event.phase == RuntimePhase.completed);
          if (failed) {
            state = state.copyWith(errorMessage: event.error.toString());
          }
        }
    }
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
    final contacts = selected == null
        ? const <ContactRecord>[]
        : core.contacts.listContacts(selected);
    return state.copyWith(
      status: AppLoadStatus.ready,
      section: accounts.isEmpty ? AppSection.accounts : state.section,
      accounts: accounts,
      contacts: contacts,
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
