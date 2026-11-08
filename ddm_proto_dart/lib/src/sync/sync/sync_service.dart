part of '../sync.dart';

final class SyncService {
  SyncService({
    required SyncBlobStore blobs,
    required ConfigManager configs,
    required BlobValidator validateBlob,
    required UtcNow nowUtc,
    ImportedEncryptedHandler? onImportedBlob,
    BlobIndex? index,
    ShardPolicy? shards,
  })  : _validateBlob = validateBlob,
        _configs = configs,
        localSource = LocalSyncSource(
          index: index,
          shards: shards ?? ShardPolicy(nowUtc: nowUtc),
          blobs: blobs,
          validateBlob: validateBlob,
          configs: configs.records,
          nowUtc: nowUtc,
          onImportedBlob: onImportedBlob,
        );

  final BlobValidator _validateBlob;
  final ConfigManager _configs;
  final LocalSyncSource localSource;
  final _reconciled = Expando<Map<StreamPrefix, _SyncCheckpoint>>();

  int get totalSyncedMessages => localSource.index.totalBlobs;

  Future<int> importFrom({
    required SyncSource source,
    String prefix = '',
  }) async {
    final sourceConfigs = await source.getConfigs();
    for (final record in sourceConfigs) {
      await _configs.addRecord(record);
    }
    if (!source.flags.has(syncSourceFlagSupportTree)) {
      return 0;
    }
    final normalizedPrefix = StreamId.normalizePrefix(prefix);
    await refreshCoverage();
    final state = await readSyncState(source);
    await localSource.shards.select(source, state, _validateBlob);
    final pull = intersectCoverage(
        localSource.shards.coverage, [StreamPrefix(normalizedPrefix)]);
    final push = source.flags.has(syncSourceFlagWritable)
        ? (source.flags.has(syncSourceFlagRouted)
            ? state.coverage
            : [StreamPrefix('')])
        : <StreamPrefix>[];
    final ranges = normalizeCoverage([...pull, ...push]);
    final cache = _reconciled[source] ??= {};
    cache.removeWhere((prefix, _) => !ranges.contains(prefix));
    final root = await localSource.getMessageIndexRoot();
    var imported = 0;
    for (final p in ranges) {
      final left = await _syncSubtree(localSource, root, p.value);
      final right = await _syncSubtree(source, state.root, p.value);
      final checkpoint = (
        local: left?.hash(),
        remote: right?.hash(),
        pull: intersectCoverage(pull, [p]),
        push: intersectCoverage(push, [p]),
      );
      final cached = cache[p];
      if (cached != null &&
          cached.local == checkpoint.local &&
          cached.remote == checkpoint.remote &&
          _sameCoverage(cached.pull, checkpoint.pull) &&
          _sameCoverage(cached.push, checkpoint.push)) {
        continue;
      }
      imported += await _reconcile(left, right, localSource, source,
          checkpoint.pull, checkpoint.push, _validateBlob);
      cache[p] = checkpoint;
    }
    return imported;
  }

  Future<void> refreshCoverage() async {
    await localSource.shards.select(
        localSource, await localSource.getSyncState(), _validateBlob,
        local: true);
  }

  void close() {
    localSource.stop();
  }
}
