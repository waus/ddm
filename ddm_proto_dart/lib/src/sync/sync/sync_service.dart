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
    var ranges = intersectCoverage(localSource.shards.coverage, state.coverage);
    ranges = intersectCoverage(ranges, [StreamPrefix(normalizedPrefix)]);
    var imported = 0;
    for (final p in ranges) {
      if (state.root != null) {
        imported += await recursiveSync(
            prefix: p.value,
            node: state.root!,
            from: source,
            to: localSource,
            validateBlob: _validateBlob);
      }
    }
    if (source.flags.has(syncSourceFlagWritable)) {
      if (!source.flags.has(syncSourceFlagRouted)) ranges = [StreamPrefix('')];
      final root = await localSource.getMessageIndexRoot();
      for (final p in ranges) {
        await recursiveSync(
            prefix: p.value,
            node: root,
            from: localSource,
            to: source,
            validateBlob: _validateBlob);
      }
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
