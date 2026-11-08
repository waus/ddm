import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';
import 'package:ddm_proto_dart/src/sync/outgoing_delivery.dart';

void main() {
  final shardCases =
      jsonDecode(File('test/fixtures/shard_selection.json').readAsStringSync())
          as List<dynamic>;
  for (final raw in shardCases) {
    final c = raw as Map<String, dynamic>;
    test('shard fixture ${c['name']}', () async {
      final now = DateTime.utc(2026, 5, 1);
      final storage = _openStorage(nowUtc: () => now);
      addTearDown(storage.close);
      final accounts = (c['accounts'] as List)
          .cast<String>()
          .map(StreamId.parseHex)
          .toList();
      final index = BlobIndex(nowUtc: () => now);
      final blobs = <SyncBlobId, SyncBlob>{};
      var i = 0;
      for (final raw in (c['leaves'] as List).cast<String>()) {
        final f = _buildPowBlob(
            streamId: StreamId.parseHex(raw),
            ttl: 3600,
            expiresTime: _unix(now) + 1800 + i++);
        index.add(f.id, f.encrypted.expiresTime);
        blobs[f.id] = f.blob;
      }
      final remote = _MemorySyncSource(index: index, blobs: blobs);
      final policy = ShardPolicy(
          targetLeaves: c['target'] as int,
          streams: () => accounts,
          nowUtc: () => now);
      await policy.select(remote, await readSyncState(remote),
          _validator(_configs(storage, now), _unix(now)));
      expect(policy.coverage.map((p) => p.value).toList(), c['coverage']);
    });
  }
  for (final scenario in [
    'newer_snapshot',
    'removed_account',
    'expired_observation'
  ]) {
    test('late shard observation: $scenario', () async {
      final publicationTime = DateTime.utc(2026, 5, 1);
      var now = publicationTime;
      final storage = _openStorage(nowUtc: () => publicationTime);
      addTearDown(storage.close);
      var accounts = [const StreamId(0x10000000)];
      final policy = ShardPolicy(
          targetLeaves: 1, streams: () => accounts, nowUtc: () => now);
      final a = _buildPowBlob(
          streamId: const StreamId(0x10000000),
          ttl: 3600,
          expiresTime: _unix(now) + 1800);
      final b = _buildPowBlob(
          streamId: const StreamId(0x20000000),
          ttl: 3600,
          expiresTime: _unix(now) + 1800);
      final entered = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      final remote = _MemorySyncSource(
          id: 'peer',
          index: BlobIndex(nowUtc: () => publicationTime)
            ..add(a.id, a.encrypted.expiresTime)
            ..add(b.id, b.encrypted.expiresTime),
          blobs: {a.id: a.blob, b.id: b.blob},
          beforeNodeLookup: () async {
            if (!blocked) {
              blocked = true;
              entered.complete();
              await release.future;
            }
          });
      final validate = _validator(
          _configs(storage, publicationTime), _unix(publicationTime));
      final pending =
          policy.select(remote, await readSyncState(remote), validate);
      await entered.future;
      if (scenario == 'newer_snapshot') {
        await policy.select(
            _MemorySyncSource(
                id: 'peer', index: BlobIndex(nowUtc: () => publicationTime)),
            SyncState(root: null, coverage: []),
            validate);
      }
      if (scenario == 'removed_account') {
        accounts = [const StreamId(0x30000000)];
      }
      if (scenario == 'expired_observation') {
        now = now.add(shardReassessmentInterval);
      }
      release.complete();
      await pending;
      expect(policy.coverage, [StreamPrefix('')]);
    });
  }
  test('periodic reassessment combines fresh peers and local density',
      () async {
    final publicationTime = DateTime.utc(2026, 5, 1);
    var now = publicationTime;
    final storage = _openStorage(nowUtc: () => publicationTime);
    addTearDown(storage.close);
    final a = _buildPowBlob(
        streamId: const StreamId(0x10000000),
        ttl: 3600,
        expiresTime: _unix(publicationTime) + 1800);
    final b = _buildPowBlob(
        streamId: const StreamId(0x20000000),
        ttl: 3600,
        expiresTime: _unix(publicationTime) + 1800);
    final remote = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => publicationTime)
          ..add(a.id, a.encrypted.expiresTime)
          ..add(b.id, b.encrypted.expiresTime),
        blobs: {a.id: a.blob, b.id: b.blob});
    final dense = await readSyncState(remote);
    final empty = SyncState(root: null, coverage: []);
    final validate =
        _validator(_configs(storage, publicationTime), _unix(publicationTime));
    final policy = ShardPolicy(
        targetLeaves: 1,
        streams: () => [const StreamId(0x10000000)],
        nowUtc: () => now);
    await policy.select(remote, empty, validate, local: true);
    await policy.select(remote, dense, validate);
    expect(policy.coverage, [StreamPrefix('1')]);
    now = now.add(const Duration(minutes: 9));
    await policy.select(remote, dense, validate);
    await policy.select(remote, empty, validate, local: true);
    expect(policy.coverage, [StreamPrefix('1')]);
    now = now.add(const Duration(minutes: 1));
    await policy.select(remote, empty, validate, local: true);
    expect(policy.coverage, [StreamPrefix('1')]);
    now = now.add(shardReassessmentInterval);
    await policy.select(remote, dense, validate, local: true);
    expect(policy.coverage, [StreamPrefix('1')]);
    now = now.add(shardReassessmentInterval);
    await policy.select(remote, empty, validate, local: true);
    expect(policy.coverage, [StreamPrefix('')]);
    await policy.select(remote, dense, validate);
    expect(policy.coverage, [StreamPrefix('1')]);
  });
  test('accounts retain their choices after overlapping coverage disappears',
      () async {
    final now = DateTime.utc(2026, 5, 1);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);
    var streams = [const StreamId(0x10000000), const StreamId(0x20000000)];
    final a = _buildPowBlob(
        streamId: streams[0], ttl: 3600, expiresTime: _unix(now) + 1800);
    final b = _buildPowBlob(
        streamId: streams[1], ttl: 3600, expiresTime: _unix(now) + 1800);
    final remote = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => now)
          ..add(a.id, a.encrypted.expiresTime)
          ..add(b.id, b.encrypted.expiresTime),
        blobs: {a.id: a.blob, b.id: b.blob});
    final policy = ShardPolicy(targetLeaves: 1, streams: () => streams);
    final validate = _validator(_configs(storage, now), _unix(now));
    await policy.select(remote, await readSyncState(remote), validate);
    expect(policy.coverage, [StreamPrefix('1'), StreamPrefix('2')]);
    streams = [...streams, const StreamId(0x30000000)];
    await policy.select(remote, SyncState(root: null, coverage: []), validate);
    expect(policy.coverage, [StreamPrefix('')]);
    streams = streams.take(2).toList();
    await policy.select(remote, SyncState(root: null, coverage: []), validate);
    expect(policy.coverage, [StreamPrefix('1'), StreamPrefix('2')]);
  });
  test('split depth preserves every message in a dense stream', () async {
    final now = DateTime.utc(2026, 5, 1);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);
    const stream = StreamId(0x12345678);
    final a = _buildPowBlob(
        streamId: stream, ttl: 3600, expiresTime: _unix(now) + 1800);
    final b = _buildPowBlob(
        streamId: stream, ttl: 3600, expiresTime: _unix(now) + 1801);
    final index = BlobIndex(nowUtc: () => now)
      ..add(a.id, a.encrypted.expiresTime)
      ..add(b.id, b.encrypted.expiresTime);
    final remote =
        _MemorySyncSource(index: index, blobs: {a.id: a.blob, b.id: b.blob});
    final configs = _configs(storage, now);
    final policy = ShardPolicy(targetLeaves: 1, streams: () => [stream]);
    final service = SyncService(
        blobs: storage.syncBlobs,
        configs: configs,
        validateBlob: _validator(configs, _unix(now)),
        nowUtc: () => now,
        shards: policy);
    addTearDown(service.close);
    expect(await service.importFrom(source: remote), 2);
    expect(policy.coverage.single.value.length, maxSplit);
    expect(service.totalSyncedMessages, 2);
  });
  test('density selection samples its snapshot before narrowing', () async {
    final now = DateTime.utc(2026, 5, 1);
    final a = _buildPowBlob(
        streamId: const StreamId(0x10000000),
        ttl: 3600,
        expiresTime: _unix(now) + 3600);
    final b = _buildPowBlob(
        streamId: const StreamId(0x20000000),
        ttl: 3600,
        expiresTime: _unix(now) + 3600);
    final index = BlobIndex(nowUtc: () => now)
      ..add(a.id, a.encrypted.expiresTime)
      ..add(b.id, b.encrypted.expiresTime);
    final remote =
        _MemorySyncSource(index: index, blobs: {a.id: a.blob, b.id: b.blob});
    final policy = ShardPolicy(
        targetLeaves: 1, streams: () => [const StreamId(0x10000000)]);
    final localPolicy = ShardPolicy(
        targetLeaves: 1, streams: () => [const StreamId(0x10000000)]);
    final local = _MemorySyncSource(index: index);
    await localPolicy.select(
        local,
        await readSyncState(local),
        (_) =>
            throw StateError('local selection must not validate sampled blobs'),
        local: true);
    expect(localPolicy.coverage, [StreamPrefix('1')]);
    var checks = 0;
    await policy.select(remote, await readSyncState(remote), (payload) {
      checks++;
      return validateSyncBlob(
          payload: payload,
          configAtUnix: (_) => _testConfigCore(),
          currentUnixSeconds: _unix(now),
          verifyPow: _acceptPow);
    });
    expect(checks, sourceCheckSampleCount);
    expect(policy.coverage, [StreamPrefix('1')]);
    expect(remote.rootLookups, 1);
    await policy.select(
        remote,
        await readSyncState(remote),
        (_) =>
            throw StateError('unchanged coverage must not trigger sampling'));
    expect(policy.coverage, [StreamPrefix('1')]);
  });

  test('outgoing queue persists retries and deduplicates peers', () async {
    var now = DateTime.utc(2026, 5, 1);
    final dir = Directory.systemTemp.createTempSync('ddm-outgoing-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/queue.sqlite';
    var storage = DdmSqliteStorage.open(path, nowUtc: () => now);
    final fixture = _buildPowBlob(
        streamId: const StreamId(0x20000000),
        ttl: 3600,
        expiresTime: _unix(now) + 3600);
    storage.syncBlobs.insertSyncBlob(SyncBlobRecord(
        blobId: fixture.id,
        blob: fixture.blob.payload,
        source: syncBlobSourceLocal,
        expiresAt: fixture.encrypted.expiresTime));
    final wrong = _MemorySyncSource(
        id: 'wrong',
        index: BlobIndex(nowUtc: () => now),
        coverage: [StreamPrefix('1')]);
    final existing = _MemorySyncSource(
        id: 'existing',
        index: BlobIndex(nowUtc: () => now)
          ..add(fixture.id, fixture.encrypted.expiresTime),
        blobs: {fixture.id: fixture.blob});
    final target =
        _MemorySyncSource(id: 'target', index: BlobIndex(nowUtc: () => now));
    final duplicate =
        _MemorySyncSource(id: 'target', index: BlobIndex(nowUtc: () => now));
    final discovery = _TestShardDiscovery([wrong, existing, target, duplicate]);
    await OutgoingDelivery(
        queue: storage.syncBlobs,
        blobs: storage.syncBlobs,
        discovery: discovery,
        nowUtc: () => now).run();
    expect(discovery.streams.single.toHex(), '20000000');
    expect(wrong.pushed, isEmpty);
    expect(existing.pushed, isEmpty);
    expect(target.pushed, hasLength(1));
    expect(duplicate.pushed, isEmpty);
    expect(storage.syncBlobs.outgoingPeers(fixture.id), ['existing', 'target']);
    storage.close();
    storage = DdmSqliteStorage.open(path, nowUtc: () => now);
    addTearDown(storage.close);
    expect(storage.syncBlobs.pendingOutgoing(_unix(now), 16, 3), isEmpty);
    now = now.add(const Duration(seconds: 30));
    expect(storage.syncBlobs.pendingOutgoing(_unix(now), 16, 3), [fixture.id]);
    final third =
        _MemorySyncSource(id: 'third', index: BlobIndex(nowUtc: () => now));
    await OutgoingDelivery(
        queue: storage.syncBlobs,
        blobs: storage.syncBlobs,
        discovery: _TestShardDiscovery([third]),
        nowUtc: () => now).run();
    expect(storage.syncBlobs.pendingOutgoing(_unix(now) + 30, 16, 3), isEmpty);
    storage.syncBlobs.deleteSyncBlobById(fixture.id);
    expect(storage.syncBlobs.outgoingPeers(fixture.id), isEmpty);
  });

  test(
      'routed coverage selects exports while fixed storage accepts all local blobs',
      () async {
    final now = DateTime.utc(2026, 5, 1);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);
    final fixture = _buildPowBlob(
        streamId: const StreamId(0x20000000),
        ttl: 3600,
        expiresTime: _unix(now) + 3600);
    storage.syncBlobs.insertSyncBlob(SyncBlobRecord(
        blobId: fixture.id,
        blob: fixture.blob.payload,
        source: syncBlobSourceLocal,
        expiresAt: fixture.encrypted.expiresTime));
    final policy = ShardPolicy(
        targetLeaves: 1, streams: () => [const StreamId(0x10000000)]);
    final another = _buildPowBlob(
        streamId: const StreamId(0x30000000),
        ttl: 3600,
        expiresTime: _unix(now) + 3600);
    final dense = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => now)
          ..add(fixture.id, fixture.encrypted.expiresTime)
          ..add(another.id, another.encrypted.expiresTime),
        blobs: {fixture.id: fixture.blob, another.id: another.blob});
    await policy.select(dense, await readSyncState(dense),
        _validator(_configs(storage, now), _unix(now)));
    final configs = _configs(storage, now);
    final service = SyncService(
        blobs: storage.syncBlobs,
        configs: configs,
        validateBlob: _validator(configs, _unix(now)),
        nowUtc: () => now,
        shards: policy);
    addTearDown(service.close);
    final routed = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => now),
        coverage: [StreamPrefix('2')],
        flags: const SyncSourceFlags(syncSourceFlagSupportTree |
            syncSourceFlagWritable |
            syncSourceFlagRouted));
    await service.importFrom(source: routed);
    expect(routed.pushed.single.id, fixture.id);
    final fixed = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => now),
        flags: const SyncSourceFlags(
            syncSourceFlagSupportTree | syncSourceFlagWritable));
    await service.importFrom(source: fixed, prefix: '1');
    expect(fixed.pushed.single.id, fixture.id);
  });

  test('reconciliation caches snapshot pairs and retries failed exchanges',
      () async {
    final now = DateTime.utc(2026, 5, 1);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);
    final configs = _configs(storage, now);
    final service = SyncService(
        blobs: storage.syncBlobs,
        configs: configs,
        validateBlob: _validator(configs, _unix(now)),
        nowUtc: () => now);
    addTearDown(service.close);
    final fixtures = [
      for (final stream in [
        0x11000000,
        0x12000000,
        0x13000000,
        0x20000000,
        0x21000000,
        0x14000000
      ])
        _buildPowBlob(
            streamId: StreamId(stream),
            ttl: 3600,
            expiresTime: _unix(now) + 3600)
    ];
    await service.localSource.push(fixtures[2].blob);
    final remote = _MemorySyncSource(
        index: BlobIndex(nowUtc: () => now),
        coverage: [StreamPrefix('2')],
        flags: const SyncSourceFlags(syncSourceFlagSupportTree |
            syncSourceFlagWritable |
            syncSourceFlagRouted));
    for (final f in [fixtures[0], fixtures[1], fixtures[3]]) {
      remote.index.add(f.id, f.encrypted.expiresTime);
      remote._blobs[f.id] = f.blob;
    }
    final source =
        RegisteredSource(source: remote, createdAt: now, rating: ratingDefault);
    expect(await service.importFrom(source: source, prefix: '1'), 2);
    expect(source.rating,
        closeTo(ratingDefault + 2 * ratingGoodBlobReceived, 1e-9));
    expect(remote.pushed, isEmpty);
    final subtree = remote.index.latestRoot().node.branch!.childrenIds[1]!;
    final children = remote.index
        .node(subtree)!
        .branch!
        .childrenIds
        .whereType<MessageIndexNodeId>()
        .toSet();

    Future<void> expectCached() async {
      remote.nodeLookups.clear();
      expect(await service.importFrom(source: source, prefix: '1'), 0);
      expect(remote.nodeLookups.where(children.contains), isEmpty);
    }

    await service.importFrom(source: source, prefix: '1');
    await expectCached();
    await remote.push(fixtures[4].blob);
    await expectCached();

    final next = fixtures[5];
    remote.index.add(next.id, next.encrypted.expiresTime);
    await expectLater(service.importFrom(source: source, prefix: '1'),
        throwsA(isA<SyncSourceException>()));
    remote._blobs[next.id] = next.blob;
    await service.localSource.push(fixtures[4].blob);
    // A failed exchange must remain eligible for retry.
    remote.coverage = [StreamPrefix('1')];
    remote.failPush = true;
    await expectLater(
        service.importFrom(source: source, prefix: '1'), throwsStateError);

    remote.coverage = [StreamPrefix('2')];
    await service.importFrom(source: source, prefix: '1');
    await service.importFrom(source: source, prefix: '1');
    await expectCached();
    remote.coverage = [StreamPrefix('1')];
    remote.failPush = false;
    await service.importFrom(source: source, prefix: '1');
    expect(source.rating,
        closeTo(ratingDefault + 3 * ratingGoodBlobReceived, 1e-9));
    expect(
        await importLeaf(
            leaf: MessageIndexLeaf(
                syncBlobId: next.id, ttl: next.encrypted.expiresTime),
            from: source,
            to: service.localSource,
            validateBlob: _validator(configs, _unix(now))),
        isFalse);
    expect(source.rating,
        closeTo(ratingDefault + 3 * ratingGoodBlobReceived, 1e-9));
  });

  for (final streams in [
    [0x10000000, 0x11000000, 0x20000000],
    [0x10000000, 0x10000000, 0x10000000],
    [0x12345678, 0x12345679, 0x12345670],
  ]) {
    for (final reverse in [false, true]) {
      test('bidirectional compressed paths $streams reverse=$reverse',
          () async {
        final now = DateTime.utc(2026, 5, 1);
        final storage = _openStorage(nowUtc: () => now);
        addTearDown(storage.close);
        final configs = _configs(storage, now);
        final service = SyncService(
            blobs: storage.syncBlobs,
            configs: configs,
            validateBlob: _validator(configs, _unix(now)),
            nowUtc: () => now);
        addTearDown(service.close);
        final fixtures = [
          for (var i = 0; i < streams.length; i++)
            _buildPowBlob(
                streamId: StreamId(streams[i]),
                ttl: 3600,
                expiresTime: _unix(now) + 1800 + i)
        ];
        final left = reverse ? fixtures.skip(1) : fixtures.take(1);
        final right = reverse ? fixtures.take(1) : fixtures.skip(1);
        for (final f in left) {
          await service.localSource.push(f.blob);
        }
        final remote = _MemorySyncSource(
            index: BlobIndex(nowUtc: () => now),
            flags: const SyncSourceFlags(syncSourceFlagSupportTree |
                syncSourceFlagWritable |
                syncSourceFlagRouted));
        for (final f in right) {
          remote.index.add(f.id, f.encrypted.expiresTime);
          remote._blobs[f.id] = f.blob;
        }
        expect(await service.importFrom(source: remote), right.length);
        expect(remote.pushed.length, left.length);
        expect(service.totalSyncedMessages, fixtures.length);
        expect(remote._blobs.length, fixtures.length);
        await service.importFrom(source: remote);
        remote.nodeLookups.clear();
        expect(await service.importFrom(source: remote), 0);
        expect(remote.nodeLookups, isEmpty);
        final next = _buildPowBlob(
            streamId: const StreamId(0x30000000),
            ttl: 3600,
            expiresTime: _unix(now) + 1800);
        remote.coverage = [StreamPrefix('1')];
        await service.localSource.push(next.blob);
        await service.importFrom(source: remote);
        expect(remote._blobs.containsKey(next.id), isFalse);
        remote.coverage = [StreamPrefix('')];
        await service.importFrom(source: remote);
        expect(remote._blobs.containsKey(next.id), isTrue);
      });
    }
  }

  for (final push in [false, true]) {
    test('reconciliation checks live destination after snapshot push=$push',
        () async {
      final now = DateTime.utc(2026, 5, 1);
      final storage = _openStorage(nowUtc: () => now);
      addTearDown(storage.close);
      final configs = _configs(storage, now);
      final validate = _validator(configs, _unix(now));
      var validations = 0;
      final service = SyncService(
          blobs: storage.syncBlobs,
          configs: configs,
          validateBlob: (payload) {
            validations++;
            return validate(payload);
          },
          nowUtc: () => now);
      addTearDown(service.close);
      final fixtures = [
        for (final stream in [0x11000000, 0x12000000])
          _buildPowBlob(
              streamId: StreamId(stream),
              ttl: 3600,
              expiresTime: _unix(now) + 1800)
      ];
      var injected = false;
      late final _MemorySyncSource remote;
      remote = _MemorySyncSource(
          index: BlobIndex(nowUtc: () => now),
          flags: const SyncSourceFlags(syncSourceFlagSupportTree |
              syncSourceFlagWritable |
              syncSourceFlagRouted),
          beforeNodeLookup: () async {
            if (injected) return;
            injected = true;
            for (final f in fixtures) {
              if (push) {
                remote.index.add(f.id, f.encrypted.expiresTime);
                remote._blobs[f.id] = f.blob;
              } else {
                await service.localSource.push(f.blob);
              }
            }
            validations = 0;
          });
      for (final f in fixtures) {
        if (push) {
          await service.localSource.push(f.blob);
        } else {
          remote.index.add(f.id, f.encrypted.expiresTime);
          remote._blobs[f.id] = f.blob;
        }
      }
      validations = 0;
      expect(await service.importFrom(source: remote), 0);
      expect(injected, isTrue);
      expect(validations, 0);
      expect(remote.blobLookups, isEmpty);
      expect(remote.pushed, isEmpty);
      expect(service.totalSyncedMessages, fixtures.length);
    });
  }

  test('push checks current multi-account coverage before import', () async {
    final now = DateTime.utc(2026, 5, 1);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);
    final configs = _configs(storage, now);
    final validate = _validator(configs, _unix(now));
    final streams = [const StreamId(0x11000000), const StreamId(0x22000000)];
    final policy =
        ShardPolicy(targetLeaves: 1, streams: () => streams, nowUtc: () => now);
    var callbacks = 0;
    final local = LocalSyncSource(
        blobs: storage.syncBlobs,
        configs: () => [],
        validateBlob: validate,
        nowUtc: () => now,
        shards: policy,
        onImportedBlob: (_) {
          callbacks++;
        });
    addTearDown(local.stop);
    final fixtures = [
      for (final stream in [0x11000000, 0x22000000, 0x33000000, 0x44000000])
        _buildPowBlob(
            streamId: StreamId(stream),
            ttl: 3600,
            expiresTime: _unix(now) + 3600)
    ];
    // Initial full coverage accepts every stream.
    await local.push(fixtures[2].blob);
    final remote = _MemorySyncSource(index: BlobIndex(nowUtc: () => now));
    for (final f in fixtures) {
      remote.index.add(f.id, f.encrypted.expiresTime);
      remote._blobs[f.id] = f.blob;
    }
    await policy.select(remote, await readSyncState(remote), validate);
    expect(policy.coverage, [StreamPrefix('1'), StreamPrefix('2')]);
    await local.push(fixtures[0].blob);
    await local.push(fixtures[1].blob);
    expect(callbacks, 3);
    for (final f in fixtures.skip(2)) {
      await expectLater(
          local.push(f.blob), throwsA(predicate(isSyncSourceUnavailableError)));
    }
    expect(callbacks, 3);
    expect(storage.syncBlobs.getSyncBlobById(fixtures[3].id), isNull);
    expect(local.index.totalBlobs, 3);
    // Removing an account changes admission for the next push.
    streams.removeAt(1);
    await policy.select(remote, await readSyncState(remote), validate);
    await expectLater(local.push(fixtures[1].blob),
        throwsA(predicate(isSyncSourceUnavailableError)));
    expect(callbacks, 3);
    // Pull imports continue through the validated sink.
    await importSnapshot(
        prefix: '4',
        node: remote.index.latestRoot().node,
        from: remote,
        to: local,
        validateBlob: validate);
    expect(storage.syncBlobs.getSyncBlobById(fixtures[3].id), isNotNull);
  });

  test('local source uses a memory store and validates direct pushes',
      () async {
    final now = DateTime.utc(2026, 5, 1);
    final store = _MemoryBlobStore();
    var checks = 0;
    final source = LocalSyncSource(
      blobs: store,
      configs: () => [],
      nowUtc: () => now,
      validateBlob: (payload) {
        checks++;
        return validateSyncBlob(
            payload: payload,
            configAtUnix: (_) => _testConfigCore(),
            currentUnixSeconds: _unix(now),
            verifyPow: _acceptPow);
      },
    );
    addTearDown(source.stop);
    final fixture = _buildPowBlob(
        streamId: const StreamId(1), ttl: 60, expiresTime: _unix(now) + 60);
    final remoteIndex = BlobIndex(nowUtc: () => now)
      ..add(fixture.id, fixture.encrypted.expiresTime);
    final remote = _MemorySyncSource(
        index: remoteIndex, blobs: {fixture.id: fixture.blob});
    await importSnapshot(
        prefix: '',
        node: remoteIndex.latestRoot().node,
        from: remote,
        to: source,
        validateBlob: (payload) {
          checks++;
          return validateSyncBlob(
              payload: payload,
              configAtUnix: (_) => _testConfigCore(),
              currentUnixSeconds: _unix(now),
              verifyPow: _acceptPow);
        });
    expect(checks, 1);
    expect(store.blobs.keys, [fixture.id]);
    await expectLater(
        source.push(SyncBlob(id: fixture.id, payload: Uint8List(0))),
        throwsFormatException);
    for (final expires in [_unix(now), _unix(now) + 61]) {
      final invalid = _buildPowBlob(
          streamId: const StreamId(2), ttl: 60, expiresTime: expires);
      await expectLater(source.push(invalid.blob), throwsFormatException);
    }
    final wrongId = SyncBlobId(Uint8List(syncBlobIdSize));
    await expectLater(
        source.push(SyncBlob(id: wrongId, payload: fixture.blob.payload)),
        throwsFormatException);
    expect(store.blobs.length, 1);
  });

  test('validation selects creation config while checking actual time',
      () async {
    final fixture =
        _buildPowBlob(streamId: const StreamId(1), ttl: 60, expiresTime: 200);
    int? selectedAt;
    Future<ValidatedBlob> validate(int now) => validateSyncBlob(
        payload: fixture.blob.payload,
        configAtUnix: (at) {
          selectedAt = at;
          return _testConfigCore();
        },
        currentUnixSeconds: now,
        verifyPow: _acceptPow);
    await validate(150);
    expect(selectedAt, 140);
    await expectLater(validate(200), throwsA(isA<ExpiredSyncBlob>()));
    await expectLater(validate(139), throwsFormatException);
  });

  test('traversal rejects changed metadata and distinguishes lost snapshots',
      () async {
    final now = DateTime.utc(2026, 5, 1);
    final id = SyncBlobId.parseHex('10' * syncBlobIdSize);
    final leaf = MessageIndexNode.leaf(
        MessageIndexLeaf(syncBlobId: id, ttl: _unix(now) + 60));
    final children = List<MessageIndexNodeId?>.filled(16, null)
      ..[1] = leaf.hash();
    MessageIndexNode root(int count) =>
        MessageIndexNode.branch(MessageIndexBranch(
            prefix: '',
            childrenCount: count,
            minTtl: _unix(now) + 60,
            maxTtl: _unix(now) + 60,
            childrenIds: children));
    expect(root(1).hash(), root(2).hash());
    final local = _MemorySyncSource(index: BlobIndex(nowUtc: () => now));
    for (final lost in [false, true]) {
      final remote = _FixedTreeSource(
          root: root(lost ? 1 : 2), nodes: lost ? {} : {leaf.hash(): leaf});
      await expectLater(
          importSnapshot(
              prefix: '',
              node: remote.root,
              from: remote,
              to: local,
              validateBlob: (_) async =>
                  throw StateError('must fail before blob validation')),
          throwsA(isA<SyncSourceException>().having(
              (e) => e.kind,
              'kind',
              lost
                  ? SyncSourceErrorKind.unavailable
                  : SyncSourceErrorKind.invalidResponse)));
    }
  });

  test('GC expires a root collapsed to a single leaf', () {
    var now = DateTime.utc(2026, 5, 1);
    final index = BlobIndex(nowUtc: () => now, rootRetention: Duration.zero);
    index.add(SyncBlobId.parseHex('10' * syncBlobIdSize), _unix(now) + 1);
    index.add(SyncBlobId.parseHex('20' * syncBlobIdSize), _unix(now) + 2);
    now = now.add(const Duration(seconds: 1));
    index.runGarbageCollection(now);
    expect(index.totalBlobs, 1);
    now = now.add(const Duration(seconds: 1));
    index.runGarbageCollection(now);
    expect(index.totalBlobs, 0);
  });

  test('BlobIndex adds blobs into compressed nibble tree', () {
    var now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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
    var now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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
      rootRetention: const Duration(seconds: 10),
    );
    index.add(id, _unix(now));

    index.runGarbageCollection(now);
    expect(storage.syncBlobs.getSyncBlobById(id), isNotNull);

    now = now.add(const Duration(seconds: 12));
    final deleted = index.runGarbageCollection(now);
    expect(deleted, [id]);
    expect(storage.syncBlobs.getSyncBlobById(id), isNotNull);
    expect(index.latestRoot().node.branch!.childrenCount, 0);
  });

  test('LocalSyncSource collects unreferenced stored blobs', () {
    var now = DateTime.utc(2026, 5, 1);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);
    final index = BlobIndex(nowUtc: () => now, rootRetention: Duration.zero);
    final source = LocalSyncSource(
        blobs: storage.syncBlobs,
        configs: _configs(storage, now).records,
        validateBlob: _validator(_configs(storage, now), _unix(now)),
        nowUtc: () => now,
        index: index);
    addTearDown(source.stop);
    final id = SyncBlobId.parseHex('11' * syncBlobIdSize);
    storage.syncBlobs.insertSyncBlob(SyncBlobRecord(
        blobId: id,
        blob: Uint8List(0),
        source: syncBlobSourceLocal,
        expiresAt: _unix(now) + 1));
    index.add(id, _unix(now) + 1);
    now = now.add(const Duration(seconds: 2));
    source.collectGarbage();
    expect(storage.syncBlobs.getSyncBlobById(id), isNull);
    expect(index.totalBlobs, 0);
  });

  test('LocalSyncSource preloads fresh storage rows and serves lookups',
      () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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

    final configs = _configs(storage, now);
    final source = LocalSyncSource(
      blobs: storage.syncBlobs,
      configs: configs.records,
      nowUtc: () => now,
      validateBlob: _validator(configs, _unix(now)),
    );
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

  test('importSnapshot imports validated leaves into local source', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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
    final configs = _configs(storage, now);
    final local = LocalSyncSource(
      blobs: storage.syncBlobs,
      configs: configs.records,
      nowUtc: () => now,
      onImportedBlob: (encrypted) {
        imported++;
      },
      validateBlob: _validator(configs, _unix(now)),
    );

    final received = await importSnapshot(
      prefix: '',
      node: await remote.getMessageIndexRoot() as MessageIndexNode,
      from: remote,
      to: local,
      validateBlob: _validator(configs, _unix(now), verifyPow: _acceptPow),
    );

    expect(received, 1);
    expect(imported, 1);
    expect(local.index.totalBlobs, 1);
    expect(storage.syncBlobs.getSyncBlobById(fixture.id), isNotNull);

    final duplicateReceived = await importSnapshot(
      prefix: '',
      node: await remote.getMessageIndexRoot() as MessageIndexNode,
      from: remote,
      to: local,
      validateBlob: _validator(configs, _unix(now), verifyPow: _acceptPow),
    );
    expect(duplicateReceived, 0);
  });

  test('LocalSyncSource runs import callback before duplicate blob insert',
      () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final fixture = _buildPowBlob(
      streamId: const StreamId(0x01020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );
    final configs = _configs(storage, now);
    var imported = 0;
    final local = LocalSyncSource(
      blobs: storage.syncBlobs,
      configs: configs.records,
      nowUtc: () => now,
      onImportedBlob: (encrypted) {
        imported++;
      },
      validateBlob: _validator(configs, _unix(now)),
    );

    storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: fixture.id,
        blob: fixture.blob.payload,
        source: syncBlobSourceImported,
        expiresAt: fixture.encrypted.expiresTime,
      ),
    );

    await local.push(fixture.blob);

    expect(imported, 1);
    expect(storage.syncBlobs.getSyncBlobById(fixture.id), isNotNull);
  });

  test('parseAndValidateBlob allows expires_time at ttl lifetime', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final fixture = _buildPowBlob(
      streamId: const StreamId(0x05060708),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
    );

    await parseAndValidateBlob(
      blobPayload: fixture.blob.payload,
      currentConfig: _testConfigCore(),
      currentUnixSeconds: _unix(now),
      verifyPow: _acceptPow,
    );
  });

  test('parseAndValidateBlob rejects expires_time beyond ttl lifetime',
      () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final fixture = _buildPowBlob(
      streamId: const StreamId(0x05060708),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1, seconds: 1))),
    );

    await expectLater(
      parseAndValidateBlob(
        blobPayload: fixture.blob.payload,
        currentConfig: _testConfigCore(),
        currentUnixSeconds: _unix(now),
        verifyPow: ({
          required modulus,
          required input,
          required difficulty,
          required y,
          required pi,
        }) {
          fail('verifyPow must not be called');
        },
      ),
      throwsFormatException,
    );
  });

  test('importSnapshot does not store imported blob when callback fails',
      () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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
    final configs = _configs(storage, now);
    final local = LocalSyncSource(
      blobs: storage.syncBlobs,
      configs: configs.records,
      nowUtc: () => now,
      onImportedBlob: (encrypted) {
        throw StateError('callback failed');
      },
      validateBlob: _validator(configs, _unix(now)),
    );

    await expectLater(
      importSnapshot(
        prefix: '',
        node: await remote.getMessageIndexRoot() as MessageIndexNode,
        from: remote,
        to: local,
        validateBlob: _validator(configs, _unix(now), verifyPow: _acceptPow),
      ),
      throwsA(isA<StateError>()),
    );

    expect(storage.syncBlobs.getSyncBlobById(fixture.id), isNull);
    expect(local.index.totalBlobs, 0);
  });

  test('SyncService importFrom pushes local root back to writable source',
      () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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
    final service = SyncService(
      blobs: storage.syncBlobs,
      configs: _configs(storage, now),
      nowUtc: () => now,
      validateBlob: _validator(_configs(storage, now), _unix(now)),
    );

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
    );

    expect(received, 1);
    expect(remote.pushed.map((blob) => blob.id), [localFixture.id]);
    expect(storage.syncBlobs.getSyncBlobById(remoteFixture.id), isNotNull);
  });

  test('SyncService sends all local blobs to fixed storage', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final localFixtures =
        <({SyncBlobId id, SyncBlob blob, EncryptedMessage encrypted})>[];
    for (var i = 0; i < 6; i++) {
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
    final service = SyncService(
      blobs: storage.syncBlobs,
      configs: _configs(storage, now),
      nowUtc: () => now,
      validateBlob: _validator(_configs(storage, now), _unix(now)),
    );

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
    );

    expect(remote.pushed, hasLength(6));
    expect(remote.pushed.map((blob) => blob.id),
        isNot(contains(remoteFixture.id)));
    final localIds = localFixtures.map((fixture) => fixture.id).toSet();
    expect(remote.pushed.every((blob) => localIds.contains(blob.id)), isTrue);
  });

  test('SyncService pushes local root to writable source with null root',
      () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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
    final service = SyncService(
      blobs: storage.syncBlobs,
      configs: _configs(storage, now),
      nowUtc: () => now,
      validateBlob: _validator(_configs(storage, now), _unix(now)),
    );
    final remote = _MemorySyncSource(
      index: BlobIndex(nowUtc: () => now),
      flags: const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      ),
      rootIsNull: true,
    );

    final received = await service.importFrom(
      source: remote,
    );

    expect(received, 0);
    expect(remote.pushed.map((blob) => blob.id), [localFixture.id]);
  });

  test('SyncService imports source configs before tree sync', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final configs = _configs(storage, now);
    final service = SyncService(
      blobs: storage.syncBlobs,
      configs: configs,
      nowUtc: () => now,
      validateBlob: _validator(configs, _unix(now)),
    );
    final remote = _MemorySyncSource(
      index: BlobIndex(nowUtc: () => now),
      rootIsNull: true,
      configs: <ConfigRecord>[ConfigRepository.defaultConfigRecord],
    );

    final received = await service.importFrom(
      source: remote,
    );

    expect(received, 0);
    expect(remote.rootLookups, 1);
    expect(_configSeqNos(configs.records()), contains(1));
    expect(storage.configs.listConfigRecords().map(configRecordVersion),
        everyElement(configRecordVersionV1));
  });

  test('checkSource accepts empty root', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    await checkSource(
      source: _MemorySyncSource(index: BlobIndex(nowUtc: () => now)),
      validateBlob:
          _validator(_configs(storage, now), _unix(now), verifyPow: _acceptPow),
    );
  });

  test('checkSource rejects inflated branch children count', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final storage = _openStorage(nowUtc: () => now);
    addTearDown(storage.close);

    final leafId = SyncBlobId.parseHex(
      '10${List<String>.filled(syncBlobIdSize - 1, '00').join()}',
    );
    final leaf = MessageIndexNode.leaf(
      MessageIndexLeaf(syncBlobId: leafId, ttl: 100),
    );
    final children = List<MessageIndexNodeId?>.filled(
      messageIndexChildSlotCount,
      null,
    );
    children[1] = leaf.hash();
    final root = MessageIndexNode.branch(
      MessageIndexBranch(
        prefix: '',
        childrenCount: 2,
        minTtl: 100,
        maxTtl: 100,
        childrenIds: children,
      ),
    );

    await expectLater(
      checkSource(
        source: _FixedTreeSource(
          root: root,
          nodes: <MessageIndexNodeId, MessageIndexNode>{leaf.hash(): leaf},
        ),
        validateBlob: _validator(_configs(storage, now), _unix(now),
            verifyPow: _acceptPow),
      ),
      throwsA(
        isA<SyncSourceException>().having(
          (error) => error.kind,
          'kind',
          SyncSourceErrorKind.invalidResponse,
        ),
      ),
    );
  });

  test('source selection includes bad and old exploration quotas', () {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
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

ConfigManager _configs(DdmSqliteStorage storage, DateTime now) {
  return ConfigManager(storage: storage.configs, nowUtc: () => now);
}

ConfigV1Core _testConfigCore() {
  return ConfigV1Core(
    seqNo: 1,
    activeFromUnix: 0,
    powBaseTarget: 1000,
    powScaleDivisor: 7373,
    powModulus: _testPowModulus(),
  );
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

List<int> _configSeqNos(List<ConfigRecord> records) {
  return records
      .map(configRecordPayload)
      .map(ConfigV1Payload.fromBytes)
      .map((payload) => payload.core.seqNo)
      .toList(growable: false);
}

Uint8List _testPowModulus() {
  return Uint8List(powModulusSize)
    ..[0] = 0x80
    ..[powModulusSize - 1] = 1;
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

final class _MemorySyncSource
    implements SyncSource, SyncStateSource, PeerIdentitySource {
  _MemorySyncSource({
    this.id = 'memory',
    this.beforeNodeLookup,
    List<StreamPrefix>? coverage,
    this.flags = const SyncSourceFlags(syncSourceFlagSupportTree),
    this.rootIsNull = false,
    List<ConfigRecord> configs = const <ConfigRecord>[],
    required this.index,
    Map<SyncBlobId, SyncBlob>? blobs,
  })  : coverage = coverage ?? [StreamPrefix('')],
        configs = List<ConfigRecord>.from(configs),
        _blobs = blobs ?? <SyncBlobId, SyncBlob>{};

  @override
  final String id;

  @override
  final SyncSourceFlags flags;

  final Future<void> Function()? beforeNodeLookup;
  final bool rootIsNull;
  List<StreamPrefix> coverage;
  @override
  String get peerIdentity => id;
  @override
  Future<SyncState> getSyncState() async =>
      SyncState(root: await getMessageIndexRoot(), coverage: coverage);

  final List<ConfigRecord> configs;
  final BlobIndex index;
  final Map<SyncBlobId, SyncBlob> _blobs;
  final List<SyncBlob> pushed = <SyncBlob>[];
  int rootLookups = 0;
  final blobLookups = <SyncBlobId>[];
  final nodeLookups = <MessageIndexNodeId>[];
  bool failPush = false;

  @override
  Future<List<ConfigRecord>> getConfigs() async {
    return List<ConfigRecord>.from(configs);
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    nodeLookups.add(id);
    await beforeNodeLookup?.call();
    return index.node(id);
  }

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    rootLookups++;
    if (rootIsNull) {
      return null;
    }
    return index.latestRoot().node;
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    blobLookups.addAll(ids);
    return ids.map((id) => _blobs[id]).toList(growable: false);
  }

  @override
  Future<void> push(SyncBlob blob) async {
    if (failPush) throw StateError("push failed");
    pushed.add(blob);
    _blobs[blob.id] = blob;
    index.add(
        blob.id, parseSyncBlobPayload(blob.payload).encrypted.expiresTime);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}

final class _FixedTreeSource implements SyncSource {
  const _FixedTreeSource({
    required this.root,
    required this.nodes,
  });

  final MessageIndexNode root;
  final Map<MessageIndexNodeId, MessageIndexNode> nodes;

  @override
  String get id => 'fixed-tree';

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(syncSourceFlagSupportTree);

  @override
  Future<List<ConfigRecord>> getConfigs() async => const <ConfigRecord>[];

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async => root;

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    return nodes[id];
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    return List<SyncBlob?>.filled(ids.length, null);
  }

  @override
  Future<void> push(SyncBlob blob) async {}

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}

BlobValidator _validator(ConfigManager configs, int now,
    {PowProofVerifier verifyPow = _acceptPow}) {
  return (payload) => validateSyncBlob(
      payload: payload,
      configAtUnix: configs.configAtUnix,
      currentUnixSeconds: now,
      verifyPow: verifyPow);
}

final class _MemoryBlobStore implements SyncBlobStore {
  final blobs = <SyncBlobId, SyncBlobRecord>{};
  @override
  bool insertSyncBlob(SyncBlobRecord blob) {
    if (blobs.containsKey(blob.blobId)) return false;
    blobs[blob.blobId] = blob;
    return true;
  }

  @override
  SyncBlobRecord? getSyncBlobById(SyncBlobId id) => blobs[id];
  @override
  List<SyncBlobIndexRecord> listSyncBlobIndexRecords() => blobs.values
      .map((b) => SyncBlobIndexRecord(blobId: b.blobId, expiresAt: b.expiresAt))
      .toList();
  @override
  int deleteExpiredSyncBlobs(int now) {
    final before = blobs.length;
    blobs.removeWhere((_, b) => b.expiresAt <= now);
    return before - blobs.length;
  }

  @override
  void deleteSyncBlobById(SyncBlobId id) {
    blobs.remove(id);
  }
}

final class _TestShardDiscovery implements ShardDiscovery {
  _TestShardDiscovery(this.peers);
  final List<SyncSource> peers;
  final streams = <StreamId>[];
  @override
  Future<List<SyncSource>> findShardPeers(StreamId stream) async {
    streams.add(stream);
    return peers;
  }
}
