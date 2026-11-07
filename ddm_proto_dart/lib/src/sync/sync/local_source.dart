part of '../sync.dart';

final class LocalSyncSource
    implements SyncSource, SyncStateSource, _ValidatedBlobSink {
  LocalSyncSource({
    required SyncBlobStore blobs,
    required List<ConfigRecord> Function() configs,
    required BlobValidator validateBlob,
    required UtcNow nowUtc,
    BlobIndex? index,
    ShardPolicy? shards,
    ImportedEncryptedHandler? onImportedBlob,
  })  : shards = shards ?? ShardPolicy(nowUtc: nowUtc),
        _blobs = blobs,
        _validateBlob = validateBlob,
        _configs = configs,
        _nowUtc = nowUtc,
        _onImportedBlob = onImportedBlob,
        index = index ?? loadBlobIndex(blobs: blobs, nowUtc: nowUtc) {
    _gcTimer = Timer.periodic(blobStorageGcInterval, (_) => collectGarbage());
  }

  final ShardPolicy shards;
  @override
  Future<SyncState> getSyncState() async =>
      SyncState(root: index.latestRoot().node, coverage: shards.coverage);
  final SyncBlobStore _blobs;
  final BlobValidator _validateBlob;
  late final Timer _gcTimer;
  final List<ConfigRecord> Function() _configs;
  final UtcNow _nowUtc;
  final ImportedEncryptedHandler? _onImportedBlob;
  final BlobIndex index;

  @override
  String get id => 'local';

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async {
    return _configs();
  }

  @override
  Future<MessageIndexNode> getMessageIndexRoot() async {
    return index.latestRoot().node;
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    return index.node(id);
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    final out = <SyncBlob?>[];
    for (final id in ids) {
      final blob = _blobs.getSyncBlobById(id);
      if (blob == null) {
        out.add(null);
        continue;
      }
      out.add(SyncBlob(id: id, payload: Uint8List.fromList(blob.blob)));
    }
    return out;
  }

  @override
  Future<void> push(SyncBlob blob) async {
    final validated = await _validateBlob(blob.payload);
    if (validated.id != blob.id) {
      throw const FormatException('sync blob ID does not match payload');
    }
    await _storeValidatedBlob(blob, validated.encrypted);
  }

  @override
  Future<void> _storeValidatedBlob(
      SyncBlob blob, EncryptedMessage encrypted) async {
    await _onImportedBlob?.call(encrypted);

    final record = SyncBlobRecord(
      blobId: blob.id,
      blob: blob.payload,
      source: syncBlobSourceImported,
      expiresAt: encrypted.expiresTime,
    );
    final inserted = _blobs.insertSyncBlob(record);
    if (!inserted) {
      return;
    }
    index.add(record.blobId, record.expiresAt);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  void collectGarbage() {
    for (final id in index.runGarbageCollection(_nowUtc())) {
      _blobs.deleteSyncBlobById(id);
    }
  }

  @override
  void stop() {
    _gcTimer.cancel();
  }
}

BlobIndex loadBlobIndex(
    {required SyncBlobStore blobs, required UtcNow nowUtc}) {
  final now = syncUnixSeconds(nowUtc());
  blobs.deleteExpiredSyncBlobs(now);
  return BlobIndex(
      nowUtc: nowUtc,
      preload: blobs
          .listSyncBlobIndexRecords()
          .where((record) => record.expiresAt > now)
          .map((record) => BlobIndexInitRecord(
              syncBlobId: record.blobId, expiresAt: record.expiresAt)));
}
