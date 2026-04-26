import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

void main() {
  test('BlobIndex adds blobs into compressed nibble tree', () {
    var now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final index = BlobIndex(nowUtc: () => now);
    final idA = SyncBlobId.parseHex(
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01',
    );
    final idB = SyncBlobId.parseHex(
      'abcfef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01',
    );

    final first = index.add(idA, 10);
    final second = index.add(idB, 20);

    expect(first.changed, isTrue);
    expect(second.changed, isTrue);
    final root = index.latestRoot().node;
    expect(root.branch, isNotNull);
    expect(root.branch!.childrenCount, 2);
    expect(root.branch!.minTtl, 10);
    expect(root.branch!.maxTtl, 20);

    final splitId = root.branch!.childrenIds[10];
    expect(splitId, isNotNull);
    final split = index.node(splitId!);
    expect(split!.branch!.prefix, 'abc');
    expect(split.branch!.childrenCount, 2);
    expect(split.branch!.childrenIds[13], isNotNull);
    expect(split.branch!.childrenIds[15], isNotNull);

    final duplicate = index.add(idA, 10);
    expect(duplicate.changed, isFalse);
    expect(duplicate.rootId, second.rootId);
  });

  test('BlobIndex garbage collection removes expired obsolete blobs', () {
    var now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final id = SyncBlobId.parseHex('10' * syncBlobIdSize);
    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: id,
        blob: Uint8List.fromList(<int>[1, 2, 3]),
        source: syncBlobSourceLocal,
        expiresAt: _unix(now),
      ),
    );

    final index = BlobIndex(
      nowUtc: () => now,
      storage: storage,
      rootRetention: const Duration(seconds: 10),
    );
    index.add(id, _unix(now));

    index.runGarbageCollection(now);
    expect(storage.syncBlobs.getSyncBlobById(id), isNotNull);

    now = now.add(const Duration(seconds: 12));
    final deleted = index.runGarbageCollection(now);
    expect(deleted, [id]);
    expect(storage.syncBlobs.getSyncBlobById(id), isNull);
    expect(index.latestRoot().node.branch!.childrenCount, 0);
  });

  test('BlobIndex periodic garbage collection removes expired obsolete blobs',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final id = SyncBlobId.parseHex('11' * syncBlobIdSize);
    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: id,
        blob: Uint8List.fromList(<int>[1, 2, 3]),
        source: syncBlobSourceLocal,
        expiresAt: _unix(now),
      ),
    );

    final index = BlobIndex(
      nowUtc: () => now,
      storage: storage,
      rootRetention: Duration.zero,
      garbageCollectionInterval: const Duration(milliseconds: 10),
    );
    addTearDown(index.close);
    index.add(id, _unix(now));

    await _waitUntil(() => storage.syncBlobs.getSyncBlobById(id) == null);
    expect(index.latestRoot().node.branch!.childrenCount, 0);
  });

  test('LocalSyncSource preloads fresh storage rows and serves lookups',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final freshId = SyncBlobId.parseHex('22' * syncBlobIdSize);
    final expiredId = SyncBlobId.parseHex('33' * syncBlobIdSize);
    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: freshId,
        blob: Uint8List.fromList(<int>[9, 9, 9]),
        source: syncBlobSourceLocal,
        expiresAt: _unix(now.add(const Duration(hours: 1))),
      ),
    );
    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: expiredId,
        blob: Uint8List.fromList(<int>[7, 7, 7]),
        source: syncBlobSourceLocal,
        expiresAt: _unix(now.subtract(const Duration(seconds: 1))),
      ),
    );

    final source = LocalSyncSource(storage: storage, nowUtc: () => now);
    expect(source.index.totalBlobs, 1);
    expect(storage.syncBlobs.getSyncBlobById(expiredId), isNull);

    final root = await source.getMessageIndexRoot();
    expect(root.branch!.childrenCount, 1);
    expect(await source.getMessageIndexNode(root.hash()), isNotNull);

    final blobs = await source.getSyncBlobs(<SyncBlobId>[freshId, expiredId]);
    expect(blobs.length, 2);
    expect(blobs[0]!.id, freshId);
    expect(blobs[1], isNull);
  });

  test('recursiveSync imports validated leaves into local source', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final fixture = _buildPowBlob(
      streamId: const StreamId(0x01020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    final remoteIndex = BlobIndex(nowUtc: () => now)
      ..add(fixture.id, fixture.encrypted.expiresTime);
    final remote = _MemorySyncSource(
      index: remoteIndex,
      blobs: <SyncBlobId, SyncBlob>{fixture.id: fixture.blob},
    );
    var imported = 0;
    final local = LocalSyncSource(
      storage: storage,
      nowUtc: () => now,
      onImportedBlob: (encrypted, {validationContext}) {
        imported++;
      },
    );

    final received = await recursiveSync(
      prefix: '',
      node: await remote.getMessageIndexRoot() as MessageIndexNode,
      from: remote,
      to: local,
      currentConfig: _currentConfig(storage),
      currentUnixSeconds: _unix(now),
      verifyPow: _acceptPow,
    );

    expect(received, 1);
    expect(imported, 1);
    expect(local.index.totalBlobs, 1);
    expect(storage.syncBlobs.getSyncBlobById(fixture.id), isNotNull);

    final duplicateReceived = await recursiveSync(
      prefix: '',
      node: await remote.getMessageIndexRoot() as MessageIndexNode,
      from: remote,
      to: local,
      currentConfig: _currentConfig(storage),
      currentUnixSeconds: _unix(now),
      verifyPow: _acceptPow,
    );
    expect(duplicateReceived, 0);
  });

  test('recursiveSync rolls back imported blob when callback fails', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final fixture = _buildPowBlob(
      streamId: const StreamId(0x05060708),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    final remoteIndex = BlobIndex(nowUtc: () => now)
      ..add(fixture.id, fixture.encrypted.expiresTime);
    final remote = _MemorySyncSource(
      index: remoteIndex,
      blobs: <SyncBlobId, SyncBlob>{fixture.id: fixture.blob},
    );
    final local = LocalSyncSource(
      storage: storage,
      nowUtc: () => now,
      onImportedBlob: (encrypted, {validationContext}) {
        throw StateError('callback failed');
      },
    );

    await expectLater(
      recursiveSync(
        prefix: '',
        node: await remote.getMessageIndexRoot() as MessageIndexNode,
        from: remote,
        to: local,
        currentConfig: _currentConfig(storage),
        currentUnixSeconds: _unix(now),
        verifyPow: _acceptPow,
      ),
      throwsA(isA<StateError>()),
    );

    expect(storage.syncBlobs.getSyncBlobById(fixture.id), isNull);
    expect(local.index.totalBlobs, 0);
  });

  test('SyncService importFrom pushes local root back to writable source',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final localFixture = _buildPowBlob(
      streamId: const StreamId(0x21020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: localFixture.id,
        blob: localFixture.blob.payload,
        source: syncBlobSourceLocal,
        expiresAt: localFixture.encrypted.expiresTime,
      ),
    );
    final service = SyncService(storage: storage, nowUtc: () => now);

    final remoteFixture = _buildPowBlob(
      streamId: const StreamId(0xa1020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    final remoteIndex = BlobIndex(nowUtc: () => now)
      ..add(remoteFixture.id, remoteFixture.encrypted.expiresTime);
    final remote = _MemorySyncSource(
      index: remoteIndex,
      flags: const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      ),
      blobs: <SyncBlobId, SyncBlob>{remoteFixture.id: remoteFixture.blob},
    );

    final received = await service.importFrom(
      source: remote,
      currentConfig: _currentConfig(storage),
      verifyPow: _acceptPow,
    );

    expect(received, 1);
    expect(remote.pushed.map((blob) => blob.id), [localFixture.id]);
    expect(storage.syncBlobs.getSyncBlobById(remoteFixture.id), isNotNull);
  });

  test('SyncService reverse sync limits pushes per writable source', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final localFixtures =
        <({SyncBlobId id, SyncBlob blob, EncryptedMessage encrypted})>[];
    for (var i = 0; i < reverseSyncPushLimit + 1; i++) {
      final fixture = _buildPowBlob(
        streamId: StreamId(0x31000000 + i),
        ttl: 3600,
        expiresTime: _unix(now.add(const Duration(hours: 1))),
      );
      storage.syncBlobs.insertSyncBlob(
        SyncBlobRecord(
          blobId: fixture.id,
          blob: fixture.blob.payload,
          source: syncBlobSourceLocal,
          expiresAt: fixture.encrypted.expiresTime,
        ),
      );
      localFixtures.add(fixture);
    }
    final service = SyncService(storage: storage, nowUtc: () => now);

    final remoteFixture = _buildPowBlob(
      streamId: const StreamId(0xa1020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    final remoteIndex = BlobIndex(nowUtc: () => now)
      ..add(remoteFixture.id, remoteFixture.encrypted.expiresTime);
    final remote = _MemorySyncSource(
      index: remoteIndex,
      flags: const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      ),
      blobs: <SyncBlobId, SyncBlob>{remoteFixture.id: remoteFixture.blob},
    );

    await service.importFrom(
      source: remote,
      currentConfig: _currentConfig(storage),
      verifyPow: _acceptPow,
    );

    expect(remote.pushed, hasLength(reverseSyncPushLimit));
    expect(remote.pushed.map((blob) => blob.id),
        isNot(contains(remoteFixture.id)));
    final localIds = localFixtures.map((fixture) => fixture.id).toSet();
    expect(remote.pushed.every((blob) => localIds.contains(blob.id)), isTrue);
  });

  test('SyncService pushes local root to writable source with null root',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final localFixture = _buildPowBlob(
      streamId: const StreamId(0x21020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: localFixture.id,
        blob: localFixture.blob.payload,
        source: syncBlobSourceLocal,
        expiresAt: localFixture.encrypted.expiresTime,
      ),
    );
    final service = SyncService(storage: storage, nowUtc: () => now);
    final remote = _MemorySyncSource(
      index: BlobIndex(nowUtc: () => now),
      flags: const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      ),
      rootIsNull: true,
    );

    final received = await service.importFrom(
      source: remote,
      currentConfig: _currentConfig(storage),
      verifyPow: _acceptPow,
    );

    expect(received, 0);
    expect(remote.pushed.map((blob) => blob.id), [localFixture.id]);
  });

  test('source selection includes bad and old exploration quotas', () {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final sources = <RegisteredSource>[
      for (var i = 0; i < 12; i++)
        _registered('healthy-recent-$i', ratingDefault, now),
      for (var i = 0; i < 3; i++)
        _registered('bad-recent-$i', ratingDefault / 2, now),
      for (var i = 0; i < 3; i++)
        _registered(
          'healthy-old-$i',
          ratingDefault,
          now.subtract(const Duration(hours: 2)),
        ),
    ];

    final active = selectActiveSources(
      sources,
      now,
      10,
      permutation: (length) => List<int>.generate(length, (idx) => idx),
    );

    expect(active.length, 10);
    expect(active.any((source) => source.rating < ratingDefault), isTrue);
    expect(
      active.any(
        (source) => source.lastOnlineAt!.isBefore(
          now.subtract(sourceOnlineWindow),
        ),
      ),
      isTrue,
    );
  });
}

DdmSqliteStorage _openStorage({required UtcNow nowUtc}) {
  final dir = Directory.systemTemp.createTempSync('ddm-sync-');
  return DdmSqliteStorage.open('${dir.path}/$defaultFileName', nowUtc: nowUtc);
}

ConfigV1Core _currentConfig(DdmSqliteStorage storage) {
  return ConfigV1Payload.fromBytes(
    storage.configs.listConfigRecords().single.record.payload,
  ).core;
}

FutureOr<bool> _acceptPow({
  required Uint8List modulus,
  required Uint8List input,
  required int difficulty,
  required Uint8List y,
  required Uint8List pi,
}) {
  return true;
}

({SyncBlobId id, SyncBlob blob, EncryptedMessage encrypted}) _buildPowBlob({
  required StreamId streamId,
  required int ttl,
  required int expiresTime,
}) {
  final encrypted = EncryptedMessage(
    version: encryptedMessageVersionV1,
    ttl: ttl,
    expiresTime: expiresTime,
    streamNumber: streamId,
    payload: Uint8List.fromList(<int>[1, 2, 3, 4]),
  );
  final envelope = PowEnvelope(
    version: powEnvelopeVersionV1,
    algorithm: PowAlgorithm.vdfRsa,
    y: Uint8List(powProofComponentSize),
    pi: Uint8List(powProofComponentSize),
    object: encrypted.toBytes(),
  );
  final payload = envelope.toBytes();
  final id = deriveSyncBlobId(streamId: streamId, blobPayload: payload);
  return (
    id: id,
    blob: SyncBlob(id: id, payload: payload),
    encrypted: encrypted
  );
}

RegisteredSource _registered(String id, double rating, DateTime lastOnlineAt) {
  return RegisteredSource(
    source:
        _MemorySyncSource(id: id, index: BlobIndex(nowUtc: () => lastOnlineAt)),
    createdAt: lastOnlineAt.subtract(const Duration(hours: 1)),
    lastOnlineAt: lastOnlineAt,
    rating: rating,
  );
}

int _unix(DateTime value) => value.toUtc().millisecondsSinceEpoch ~/ 1000;

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not met within $timeout');
}

final class _MemorySyncSource implements SyncSource {
  _MemorySyncSource({
    this.id = 'memory',
    this.flags = const SyncSourceFlags(syncSourceFlagSupportTree),
    this.rootIsNull = false,
    required this.index,
    Map<SyncBlobId, SyncBlob>? blobs,
  }) : _blobs = blobs ?? <SyncBlobId, SyncBlob>{};

  @override
  final String id;

  @override
  final SyncSourceFlags flags;

  final bool rootIsNull;

  final BlobIndex index;
  final Map<SyncBlobId, SyncBlob> _blobs;
  final List<SyncBlob> pushed = <SyncBlob>[];

  @override
  Future<List<ConfigRecord>> getConfigs() async => const <ConfigRecord>[];

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    return index.node(id);
  }

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    if (rootIsNull) {
      return null;
    }
    return index.latestRoot().node;
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
    pushed.add(blob);
    _blobs[blob.id] = blob;
    index.add(
        blob.id, encryptedMessageFromPowEnvelope(blob.payload).expiresTime);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}
