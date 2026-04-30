import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_app/src/app_controller.dart';
import 'package:ddm_app/src/app_state.dart';
import 'package:ddm_app/src/update_service.dart';
import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddm_app/src/ddm_app.dart';

void main() {
  test('AppController checks for newer app versions on startup', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-update-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    Uri? openedUrl;
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
        appVersionLoader: () async => const AppVersion(
          version: '0.2.0',
          os: 'linux',
          arch: 'x64',
        ),
        updateChecker: (version) async {
          expect(version.version, '0.2.0');
          expect(version.os, 'linux');
          expect(version.arch, 'x64');
          return const UpdateCheckResult(
            lastVersion: '0.3.0',
            mandatoryUpdate: true,
          );
        },
        urlOpener: (url) async {
          openedUrl = url;
          return true;
        },
      ),
    );
    addTearDown(controller.close);

    await controller.initialize();
    await _waitUntil(
      () => controller.state.update != null,
      timeout: const Duration(seconds: 1),
    );

    expect(controller.state.appVersion?.displayText, '0.2.0');
    expect(controller.state.update?.lastVersion, '0.3.0');
    expect(controller.state.update?.mandatoryUpdate, isTrue);

    await controller.openUpdateSite();

    expect(openedUrl, Uri.parse(updateSiteUrl));
  });

  test('AppController creates accounts and writes composed messages', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-test-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final pow = _ImmediatePowService();
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
        powService: pow,
      ),
    );
    addTearDown(controller.close);

    await controller.initialize();
    expect(controller.state.status, AppLoadStatus.ready);
    expect(controller.state.accounts, isEmpty);

    await controller.createAccount('Alice');
    final account = controller.state.accounts.single;
    expect(account.name, 'Alice');
    expect(Address.fromText(account.address).requiresAck, isTrue);

    await controller.sendText(
      sender: account,
      recipientAddress: account.address,
      text: 'hello from flutter',
    );
    await _waitUntil(
      () => controller.state.messages.single.state == messageStatePowSynced,
      timeout: const Duration(seconds: 3),
    );

    expect(controller.state.mailbox, Mailbox.outbox);
    expect(controller.state.messages.single.state, messageStatePowSynced);
    expect(
        messagePreview(controller.state.messages.single), 'hello from flutter');
    expect(controller.state.sync.totalSyncedMessages, 1);
    expect(pow.solves, 2);
  });

  test('AppController creates silent accounts without ACK policy', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-silent-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
      ),
    );
    addTearDown(controller.close);

    await controller.initialize();
    await controller.createAccount('Silent', silent: true);

    final account = controller.state.accounts.single;
    expect(account.name, 'Silent');
    expect(Address.fromText(account.address).requiresAck, isFalse);
  });

  test('AppController adds and deletes contacts', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-contact-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
      ),
    );
    addTearDown(controller.close);

    await controller.initialize();
    await controller.createAccount('Alice');
    await controller.createAccount('Bob');
    final alice = controller.state.accounts[0];
    final bob = controller.state.accounts[1];

    expect(
      await controller.addContact(
        account: alice,
        name: 'Bob',
        address: bob.address,
      ),
      isTrue,
    );
    expect(controller.state.contacts.single.name, 'Bob');

    expect(
      await controller.deleteContact(account: alice, address: bob.address),
      isTrue,
    );
    expect(controller.state.contacts, isEmpty);
  });

  test('AppController deletes local messages', () async {
    final workspace =
        Directory.systemTemp.createTempSync('ddm-app-delete-message-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
        powService: _ImmediatePowService(),
      ),
    );
    addTearDown(controller.close);

    await controller.initialize();
    await controller.createAccount('Alice');
    final account = controller.state.accounts.single;
    await controller.sendText(
      sender: account,
      recipientAddress: account.address,
      text: 'delete me',
    );
    await _waitUntil(
      () => controller.state.messages.single.state == messageStatePowSynced,
      timeout: const Duration(seconds: 3),
    );
    controller.selectMessage(controller.state.messages.single);

    expect(await controller.deleteMessages(controller.state.messages), isTrue);
    expect(controller.state.messages, isEmpty);
    expect(controller.state.selectedMessage, isNull);
  });

  test('AppController source registration imports blobs via background sync',
      () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-sync-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(
            backgroundSyncInterval: Duration(milliseconds: 50),
            discoveryInterval: Duration(seconds: 30),
            peerExchangeInterval: Duration(seconds: 30),
          ),
        ),
        verifyPow: ({
          required List<int> modulus,
          required List<int> input,
          required int difficulty,
          required List<int> y,
          required List<int> pi,
        }) =>
            true,
      ),
    );
    addTearDown(controller.close);
    await controller.initialize();

    final now = DateTime.now().toUtc();
    final fixture = _buildPowBlob(
      streamId: const StreamId(0x01020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    );
    final sourcePath = '${workspace.path}/source.sqlite';
    File(sourcePath).writeAsBytesSync(Uint8List(0));
    final source = FileSyncSourceClient(
      Uri.file(sourcePath).toString(),
      nowUtc: () => DateTime.now().toUtc(),
    );
    await source.push(fixture.blob);
    source.stop();

    await controller.addSource(Uri.file(sourcePath).toString());

    expect(controller.state.sync.lastSyncMessage, 'Source added');
    await _waitUntil(
      () => controller.state.sync.totalSyncedMessages == 1,
      timeout: const Duration(seconds: 3),
    );
    expect(controller.state.errorMessage, isNull);
  });

  test('AppController background sync imports new blobs from registered source',
      () async {
    final workspace =
        Directory.systemTemp.createTempSync('ddm-app-background-sync-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(
            backgroundSyncInterval: Duration(milliseconds: 50),
            discoveryInterval: Duration(seconds: 30),
            peerExchangeInterval: Duration(seconds: 30),
          ),
        ),
        verifyPow: ({
          required List<int> modulus,
          required List<int> input,
          required int difficulty,
          required List<int> y,
          required List<int> pi,
        }) =>
            true,
      ),
    );
    addTearDown(controller.close);
    await controller.initialize();

    final sourcePath = '${workspace.path}/background-source.sqlite';
    File(sourcePath).writeAsBytesSync(Uint8List(0));
    final firstSource = FileSyncSourceClient(
      Uri.file(sourcePath).toString(),
      nowUtc: () => DateTime.now().toUtc(),
    );
    final now = DateTime.now().toUtc();
    final first = _buildPowBlob(
      streamId: const StreamId(0x01020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
      payload: Uint8List.fromList(<int>[1]),
    );
    await firstSource.push(first.blob);
    firstSource.stop();

    await controller.addSource(Uri.file(sourcePath).toString());
    await _waitUntil(
      () => controller.state.sync.totalSyncedMessages == 1,
      timeout: const Duration(seconds: 3),
    );

    final secondSource = FileSyncSourceClient(
      Uri.file(sourcePath).toString(),
      nowUtc: () => DateTime.now().toUtc(),
    );
    final second = _buildPowBlob(
      streamId: const StreamId(0x09080706),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
      payload: Uint8List.fromList(<int>[2]),
    );
    await secondSource.push(second.blob);
    secondSource.stop();

    await _waitUntil(
      () => controller.state.sync.totalSyncedMessages == 2,
      timeout: const Duration(seconds: 3),
    );
    expect(controller.state.sync.onlinePeerCount, 1);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    controller.close();

    final core = DdmCore.open(workspace.path);
    addTearDown(core.close);
    final peer = core.sync.listStoredPeers().singleWhere(
          (peer) => peer.id == Uri.file(sourcePath).toString(),
        );
    expect(
      peer.rating,
      closeTo(ratingDefault + ratingGoodBlobReceived * 2, 0.000000001),
    );
  });

  test(
      'AppController does not penalize unavailable source during background sync',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final workspace =
          Directory.systemTemp.createTempSync('ddm-app-source-unavailable-');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final controller = AppController(
        AppDependencies(
          workspacePath: workspace.path,
          runtimeOptions: const DdmCoreRuntimeOptions(
            transports: RuntimeTransportOptions(
              backgroundSyncInterval: Duration(milliseconds: 50),
              discoveryInterval: Duration(seconds: 30),
              peerExchangeInterval: Duration(seconds: 30),
            ),
          ),
          verifyPow: ({
            required List<int> modulus,
            required List<int> input,
            required int difficulty,
            required List<int> y,
            required List<int> pi,
          }) =>
              true,
        ),
      );
      addTearDown(controller.close);
      await controller.initialize();

      final now = DateTime.now().toUtc();
      final fixture = _buildPowBlob(
        streamId: const StreamId(0x0a0b0c0d),
        ttl: 3600,
        expiresTime: _unix(now.add(const Duration(hours: 1))),
        payload: Uint8List.fromList(<int>[7, 8, 9]),
      );
      final source = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => now)..add(fixture.id, fixture.expiresAt),
        blobs: <SyncBlobId, SyncBlob>{fixture.id: fixture.blob},
      );
      final server = HttpSyncSourceServer(listenAddress: '127.0.0.1:0');
      await server.start(source);
      addTearDown(server.stop);

      final sourceId = server.boundUri.toString();
      await controller.addSource(sourceId);
      await _waitUntil(
        () => controller.state.sync.totalSyncedMessages == 1,
        timeout: const Duration(seconds: 3),
      );

      await server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 180));

      controller.close();

      final core = DdmCore.open(workspace.path);
      addTearDown(core.close);
      final peer = core.sync
          .listStoredPeers()
          .singleWhere((peer) => peer.id == sourceId);
      expect(
        peer.rating,
        closeTo(ratingDefault + ratingGoodBlobReceived, 0.000000001),
      );
    }, _RealHttpOverrides());
  });

  test('AppController marks unread inbox message read when selected', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-read-');
    addTearDown(() => workspace.deleteSync(recursive: true));

    final core = DdmCore.open(workspace.path);
    final now = DateTime.now().toUtc();
    final alice = await core.accounts.createAccount('alice');
    final bob = await core.accounts.createAccount('bob');
    final decrypted = await UnencryptedMessage.signed(
      privateKey: bob.privateKey,
      messageId: Uint8List.fromList(List<int>.filled(16, 0x51)),
      sender: Address.fromText(bob.address),
      messageType: MessageType.plain,
      message: Uint8List.fromList('hello unread'.codeUnits),
    );
    await core.receive.materializeDecodedInbound(
      recipient: alice,
      encrypted: EncryptedMessage(
        version: encryptedMessageVersionV1,
        ttl: 3600,
        expiresTime: _unix(now.add(const Duration(hours: 1))),
        streamNumber: Address.fromText(alice.address).streamId(),
        payload: Uint8List(0),
      ),
      decrypted: decrypted,
    );
    core.close();

    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
      ),
    );
    addTearDown(controller.close);
    await controller.initialize();

    final unread = controller.state.messages.single;
    expect(unread.isRead, isFalse);

    controller.selectMessage(unread);

    expect(controller.state.selectedMessage?.isRead, isTrue);
    expect(controller.state.messages.single.isRead, isTrue);
    expect(controller.state.errorMessage, isNull);
  });

  test('AppController publishes noise blobs while on external power', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-cover-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    var onExternalPower = true;
    final controller = AppController(
      AppDependencies(
        workspacePath: workspace.path,
        runtimeOptions: const DdmCoreRuntimeOptions(
          transports: RuntimeTransportOptions(backgroundSyncEnabled: false),
        ),
        powService: _ImmediatePowService(),
        externalPowerCheck: () async => onExternalPower,
        noiseGeneratorInterval: const Duration(milliseconds: 200),
      ),
    );
    addTearDown(() async {
      onExternalPower = false;
      controller.close();
    });

    await controller.initialize();
    await _waitUntil(
      () => controller.state.sync.totalSyncedMessages >= 1,
      timeout: const Duration(seconds: 3),
    );

    controller.close();

    final core = DdmCore.open(workspace.path);
    addTearDown(core.close);
    expect(core.sync.totalSyncedMessages, greaterThanOrEqualTo(1));
    expect(core.outbox.listPendingMessages(), isEmpty);
    expect(core.accounts.listAccounts(), isEmpty);
    expect(core.sync.localSource.index.totalBlobs, greaterThanOrEqualTo(1));
  });

  testWidgets('app shell shows onboarding and account creation controls',
      (tester) async {
    final workspace = Directory.systemTemp.createTempSync('ddm-app-widget-');
    addTearDown(() => workspace.deleteSync(recursive: true));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDependenciesProvider.overrideWithValue(
            AppDependencies(
              workspacePath: workspace.path,
              runtimeOptions: const DdmCoreRuntimeOptions(
                transports: RuntimeTransportOptions(
                  backgroundSyncEnabled: false,
                ),
              ),
              externalPowerCheck: () async => false,
              appVersionLoader: () async => const AppVersion(
                version: '0.1.0',
                os: 'linux',
                arch: 'x64',
              ),
              updateChecker: (_) async => null,
            ),
          ),
        ],
        child: const DdmApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New account'), findsOneWidget);

    await tester.tap(find.text('New account'));
    await tester.pumpAndSettle();

    expect(find.text('Silent account'), findsOneWidget);
    expect(
      find.text(
        'No delivery receipts (more private; offline messages may expire).',
      ),
      findsOneWidget,
    );
    expect(find.text('Create'), findsOneWidget);
  });

  testWidgets('app shell shows fatal error screen when startup fails',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDependenciesProvider.overrideWithValue(
            AppDependencies(
              workspacePath: '',
              externalPowerCheck: () async => false,
              appVersionLoader: () async => const AppVersion(
                version: '0.1.0',
                os: 'linux',
                arch: 'x64',
              ),
              updateChecker: (_) async => null,
            ),
          ),
        ],
        child: const DdmApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.text('DDM cannot start.'), findsOneWidget);
    expect(find.textContaining('workdir must not be empty'), findsOneWidget);
    expect(find.text('New account'), findsNothing);
  });
}

({SyncBlobId id, SyncBlob blob, int expiresAt}) _buildPowBlob({
  required StreamId streamId,
  required int ttl,
  required int expiresTime,
  required Uint8List payload,
}) {
  final encrypted = EncryptedMessage(
    version: encryptedMessageVersionV1,
    ttl: ttl,
    expiresTime: expiresTime,
    streamNumber: streamId,
    payload: payload,
  );
  final envelope = PowEnvelope(
    version: powEnvelopeVersionV1,
    algorithm: PowAlgorithm.vdfRsa,
    y: Uint8List(powProofComponentSize),
    pi: Uint8List(powProofComponentSize),
    object: encrypted.toBytes(),
  );
  final bytes = envelope.toBytes();
  final id = deriveSyncBlobId(streamId: streamId, blobPayload: bytes);
  return (
    id: id,
    blob: SyncBlob(id: id, payload: bytes),
    expiresAt: expiresTime,
  );
}

int _unix(DateTime value) => value.toUtc().millisecondsSinceEpoch ~/ 1000;

Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class _ImmediatePowService implements PowService {
  int solves = 0;

  @override
  Future<PowSolveResult> solve({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    void Function(PowSolveProgress progress)? onProgress,
  }) async {
    solves++;
    onProgress?.call(
      const PowSolveProgress(completion: 1, elapsed: Duration.zero),
    );
    return PowSolveResult(
      y: _proofBytes(1),
      pi: _proofBytes(2),
      elapsed: Duration.zero,
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
    return true;
  }
}

final class _RealHttpOverrides extends HttpOverrides {}

final class _MemorySyncSource implements SyncSource {
  _MemorySyncSource({
    required this.index,
    Map<SyncBlobId, SyncBlob>? blobs,
  }) : _blobs = blobs ?? <SyncBlobId, SyncBlob>{};

  final BlobIndex index;
  final Map<SyncBlobId, SyncBlob> _blobs;

  @override
  String get id => 'memory';

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async => const <ConfigRecord>[];

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    return index.latestRoot().node;
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    return index.node(id);
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    return ids.map((id) => _blobs[id]).toList(growable: false);
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    _blobs[blob.id] = blob;
    index.add(
        blob.id, encryptedMessageFromPowEnvelope(blob.payload).expiresTime);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}

Uint8List _proofBytes(int lastByte) {
  return Uint8List(powProofComponentSize)..last = lastByte;
}
