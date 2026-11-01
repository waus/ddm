part of '../sync.dart';

final class SyncService {
  SyncService({
    required DdmSqliteStorage storage,
    required ConfigManager configs,
    required UtcNow nowUtc,
    ImportedEncryptedHandler? onImportedBlob,
    BlobIndex? index,
  })  : _storage = storage,
        _configs = configs,
        _nowUtc = nowUtc,
        localSource = LocalSyncSource(
          index: index,
          storage: storage,
          configs: configs,
          nowUtc: nowUtc,
          onImportedBlob: onImportedBlob,
        );

  final DdmSqliteStorage _storage;
  final ConfigManager _configs;
  final UtcNow _nowUtc;
  final LocalSyncSource localSource;

  int get totalSyncedMessages => localSource.index.totalBlobs;

  Future<int> importFrom({
    required SyncSource source,
    required PowProofVerifier verifyPow,
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
    final currentUnixSeconds = syncUnixSeconds(_nowUtc());
    final root = await source.getMessageIndexRoot();
    var imported = 0;
    if (root != null) {
      imported = await recursiveSync(
        prefix: normalizedPrefix,
        node: root,
        from: source,
        to: localSource,
        currentUnixSeconds: currentUnixSeconds,
        configs: _configs,
        verifyPow: verifyPow,
      );
    }
    if (source.flags.has(syncSourceFlagWritable)) {
      final localRoot = await localSource.getMessageIndexRoot();
      await _recursiveSyncWithLimit(
        prefix: normalizedPrefix,
        node: localRoot,
        from: localSource,
        to: source,
        currentUnixSeconds: currentUnixSeconds,
        configs: _configs,
        verifyPow: verifyPow,
        remaining: SyncLimit(reverseSyncPushLimit),
      );
    }
    return imported;
  }

  Future<List<ConfigRecord>> getConfigs() => localSource.getConfigs();

  List<PeerRecord> listStoredPeers() => _storage.peers.listPeers();

  void close() {
    localSource.stop();
  }
}
