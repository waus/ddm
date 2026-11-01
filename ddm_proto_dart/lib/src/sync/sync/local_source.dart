part of '../sync.dart';

final class LocalSyncSource implements SyncSource {
  LocalSyncSource({
    required DdmSqliteStorage storage,
    required ConfigManager configs,
    required UtcNow nowUtc,
    BlobIndex? index,
    ImportedEncryptedHandler? onImportedBlob,
  })  : _storage = storage,
        _configs = configs,
        _nowUtc = nowUtc,
        _onImportedBlob = onImportedBlob,
        index =
            index ?? BlobIndex.fromStorage(storage: storage, nowUtc: nowUtc),
        _ownsIndex = index == null;

  final DdmSqliteStorage _storage;
  final ConfigManager _configs;
  final UtcNow _nowUtc;
  final ImportedEncryptedHandler? _onImportedBlob;
  final BlobIndex index;
  final bool _ownsIndex;

  @override
  String get id => 'local';

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async {
    return _configs.records();
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
    final now = syncUnixSeconds(_nowUtc());
    final out = <SyncBlob?>[];
    for (final id in ids) {
      final blob = _storage.syncBlobs.getSyncBlobById(id);
      if (blob == null || blob.expiresAt <= now) {
        out.add(null);
        continue;
      }
      out.add(SyncBlob(id: id, payload: Uint8List.fromList(blob.blob)));
    }
    return out;
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    final encrypted = encryptedMessageFromPowEnvelope(blob.payload);
    await _onImportedBlob?.call(
      encrypted,
      validationContext: validationContext,
    );

    final record = SyncBlobRecord(
      blobId: blob.id,
      blob: blob.payload,
      source: syncBlobSourceImported,
      expiresAt: encrypted.expiresTime,
    );
    final inserted = _storage.syncBlobs.insertSyncBlob(record);
    if (!inserted) {
      return;
    }
    index.add(record.blobId, record.expiresAt);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {
    if (_ownsIndex) {
      index.close();
    }
  }
}
