part of '../sync.dart';

final class BlobIndexInitRecord {
  const BlobIndexInitRecord(
      {required this.syncBlobId, required this.expiresAt});

  final SyncBlobId syncBlobId;
  final int expiresAt;
}

final class BlobIndexRootRecord {
  const BlobIndexRootRecord({
    required this.createdAtUnix,
    required this.id,
    required this.node,
  });

  final int createdAtUnix;
  final MessageIndexNodeId id;
  final MessageIndexNode node;
}

final class BlobIndexAddResult {
  const BlobIndexAddResult({required this.rootId, required this.changed});

  final MessageIndexNodeId rootId;
  final bool changed;
}

final class BlobIndex {
  BlobIndex({
    required UtcNow nowUtc,
    DdmSqliteStorage? storage,
    Iterable<BlobIndexInitRecord> preload = const <BlobIndexInitRecord>[],
    this.rootRetention = blobStorageRootRetention,
    Duration? garbageCollectionInterval,
  })  : _nowUtc = nowUtc,
        _storage = storage {
    _appendRoot(
        _MessageIndexNode.emptyBranch(), syncUnixSeconds(_nowUtc()), null);
    _preload(preload);
    if (garbageCollectionInterval != null) {
      _garbageCollectionTimer = Timer.periodic(
        garbageCollectionInterval,
        (_) => runGarbageCollection(_nowUtc()),
      );
    }
  }

  factory BlobIndex.fromStorage({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
  }) {
    final now = syncUnixSeconds(nowUtc());
    storage.syncBlobs.deleteExpiredSyncBlobs(now);
    final preload = storage.syncBlobs
        .listSyncBlobIndexRecords()
        .where((record) => record.expiresAt > now)
        .map(
          (record) => BlobIndexInitRecord(
            syncBlobId: record.blobId,
            expiresAt: record.expiresAt,
          ),
        )
        .toList(growable: false);
    return BlobIndex(
      storage: storage,
      nowUtc: nowUtc,
      preload: preload,
      garbageCollectionInterval: blobStorageGcInterval,
    );
  }

  final UtcNow _nowUtc;
  final DdmSqliteStorage? _storage;
  final Duration rootRetention;
  final Map<MessageIndexNodeId, _IndexedMessageIndexNode> _hashes =
      <MessageIndexNodeId, _IndexedMessageIndexNode>{};
  final List<_BlobIndexRootEntry> _roots = <_BlobIndexRootEntry>[];
  int _rootsHead = 0;
  Timer? _garbageCollectionTimer;
  bool _closed = false;

  BlobIndexAddResult add(SyncBlobId id, int expiresAt) {
    final now = syncUnixSeconds(_nowUtc());
    final addedNode = _BlobsAddedNodeRecord(
      prefix: id.toHex(),
      expiresAt: expiresAt,
    );
    final previousRoot = _latestRoot();
    final nextRoot = previousRoot.node.node.add(id.toHex(), expiresAt);
    final changed = nextRoot.hash != previousRoot.node.node.hash;
    if (changed) {
      _appendRoot(nextRoot, now, addedNode);
    }
    return BlobIndexAddResult(rootId: nextRoot.hash, changed: changed);
  }

  BlobIndexRootRecord latestRoot() {
    return _snapshotRoot(_latestRoot());
  }

  List<BlobIndexRootRecord> roots() {
    return _roots.skip(_rootsHead).map(_snapshotRoot).toList(growable: false);
  }

  MessageIndexNode? node(MessageIndexNodeId id) {
    return _hashes[id]?.node.toProto();
  }

  List<SyncBlobId> runGarbageCollection(DateTime now) {
    if (_closed) {
      return const <SyncBlobId>[];
    }
    final nowSeconds = syncUnixSeconds(now.toUtc());
    _collectExpiredMessages(nowSeconds);
    final deleted = _collectObsoleteRoots(nowSeconds);
    for (final id in deleted) {
      _storage?.syncBlobs.deleteSyncBlobById(id);
    }
    return deleted;
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _garbageCollectionTimer?.cancel();
    _garbageCollectionTimer = null;
  }

  int get totalBlobs {
    final root = latestRoot().node.branch;
    return root?.childrenCount ?? 0;
  }

  void _preload(Iterable<BlobIndexInitRecord> preload) {
    _MessageIndexNode? root;
    var hasRoot = false;
    for (final record in preload) {
      root = (root ?? _MessageIndexNode.emptyBranch()).add(
        record.syncBlobId.toHex(),
        record.expiresAt,
      );
      hasRoot = true;
    }
    if (hasRoot) {
      _appendRoot(root!, syncUnixSeconds(_nowUtc()), null);
    }
  }

  void _collectExpiredMessages(int threshold) {
    final previousRoot = _latestRoot();
    if (previousRoot.node.node.childrenCount == 0) {
      return;
    }
    final minChildTTL = previousRoot.node.node.minChildTTL;
    if (minChildTTL == 0 || minChildTTL > threshold) {
      return;
    }
    final nextRoot = previousRoot.node.node.collectExpiredGarbage(threshold) ??
        _MessageIndexNode.emptyBranch();
    if (nextRoot.hash != previousRoot.node.node.hash) {
      _appendRoot(nextRoot, threshold, null);
    }
  }

  List<SyncBlobId> _collectObsoleteRoots(int now) {
    if (_liveRootsLen <= 1) {
      return const <SyncBlobId>[];
    }

    final expiredBefore = now - rootRetention.inSeconds;
    final deleted = <SyncBlobId>[];
    while (_liveRootsLen > 1) {
      final root = _roots[_rootsHead];
      if (root.createdAtUnix > expiredBefore) {
        break;
      }
      _releaseIndexedNode(root.node, deleted);
      _rootsHead++;
    }

    if (_liveRootsLen > 0) {
      _roots[_rootsHead] = _roots[_rootsHead].withoutAddMetadata();
    }
    _compactRoots();
    return deleted;
  }

  void _appendRoot(
    _MessageIndexNode root,
    int createdAtUnix,
    _BlobsAddedNodeRecord? createdByAddingNode,
  ) {
    final entry = _retainIndexedNode(root);
    _roots.add(
      _BlobIndexRootEntry(
        createdAtUnix: createdAtUnix,
        node: entry,
        createdByAddingNode: createdByAddingNode,
      ),
    );
  }

  _IndexedMessageIndexNode _retainIndexedNode(_MessageIndexNode node) {
    final entry = _indexNode(node);
    entry.refs++;
    return entry;
  }

  _IndexedMessageIndexNode _indexNode(_MessageIndexNode node) {
    final existing = _hashes[node.hash];
    if (existing != null) {
      return existing;
    }

    final entry = _IndexedMessageIndexNode(node: node);
    _hashes[node.hash] = entry;
    for (final child in node.children) {
      if (child == null) {
        continue;
      }
      final indexedChild = _indexNode(child);
      indexedChild.refs++;
    }
    return entry;
  }

  void _releaseIndexedNode(
    _IndexedMessageIndexNode entry,
    List<SyncBlobId> deleted,
  ) {
    if (entry.refs == 0) {
      throw StateError(
          'message index node ${entry.node.hash} refcount underflow');
    }
    entry.refs--;
    if (entry.refs > 0) {
      return;
    }
    _deleteIndexedNode(entry, deleted);
  }

  void _deleteIndexedNode(
    _IndexedMessageIndexNode entry,
    List<SyncBlobId> deleted,
  ) {
    final stored = _hashes[entry.node.hash];
    if (stored == null) {
      return;
    }
    if (!identical(stored, entry)) {
      throw StateError('message index node ${entry.node.hash} entry mismatch');
    }
    _hashes.remove(entry.node.hash);

    for (final child in entry.node.children) {
      if (child == null) {
        continue;
      }
      final childEntry = _hashes[child.hash];
      if (childEntry == null) {
        throw StateError('message index child ${child.hash} missing');
      }
      _releaseIndexedNode(childEntry, deleted);
    }

    final blobId = entry.node.syncBlobIdOrNull();
    if (blobId != null) {
      deleted.add(blobId);
    }
  }

  BlobIndexRootRecord _snapshotRoot(_BlobIndexRootEntry root) {
    return BlobIndexRootRecord(
      createdAtUnix: root.createdAtUnix,
      id: root.node.node.hash,
      node: root.node.node.toProto(),
    );
  }

  _BlobIndexRootEntry _latestRoot() {
    if (_liveRootsLen == 0) {
      throw StateError('blob index must always have a root');
    }
    return _roots.last;
  }

  int get _liveRootsLen => _roots.length - _rootsHead;

  void _compactRoots() {
    if (_rootsHead == 0 || _rootsHead <= _roots.length ~/ 2) {
      return;
    }
    _roots.removeRange(0, _rootsHead);
    _rootsHead = 0;
  }
}
