import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/config_manager.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/envelope.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';
import 'package:ddm_proto_dart/src/proto/sync_blob.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/storage/constants.dart';
import 'package:ddm_proto_dart/src/storage/storage.dart';
import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/transport/errors.dart';

typedef ImportedEncryptedHandler = FutureOr<void> Function(
  EncryptedMessage encrypted, {
  ImportValidationContext? validationContext,
});

typedef SourcePermutation = List<int> Function(int length);

final class SyncSourceFlags {
  const SyncSourceFlags(this.value);

  final int value;

  bool has(int flag) => value & flag == flag;
}

abstract interface class SyncSource {
  String get id;

  SyncSourceFlags get flags;

  Future<List<ConfigRecord>> getConfigs();

  Future<MessageIndexNode?> getMessageIndexRoot();

  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id);

  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids);

  Future<void> push(SyncBlob blob,
      {ImportValidationContext? validationContext});

  Future<List<String>> discoverPeers();

  void stop();
}

final class ImportValidationContext {
  const ImportValidationContext({
    required this.configs,
    required this.verifyPow,
  });

  final ConfigManager configs;
  final PowProofVerifier verifyPow;
}

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
    _appendRoot(_MessageIndexNode.emptyBranch(), _unixSeconds(_nowUtc()), null);
    _preload(preload);
    if (garbageCollectionInterval != null) {
      _garbageCollectionTimer = Timer.periodic(
        garbageCollectionInterval,
        (_) => runGarbageCollection(_nowUtc()),
      );
    }
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
    final now = _unixSeconds(_nowUtc());
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
    final nowSeconds = _unixSeconds(now.toUtc());
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
      _appendRoot(root!, _unixSeconds(_nowUtc()), null);
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
        index = index ?? _buildIndex(storage: storage, nowUtc: nowUtc),
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
    final now = _unixSeconds(_nowUtc());
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

    try {
      await _onImportedBlob?.call(
        encrypted,
        validationContext: validationContext,
      );
    } catch (error) {
      _storage.syncBlobs.deleteSyncBlobById(record.blobId);
      rethrow;
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

final class SyncService {
  SyncService({
    required DdmSqliteStorage storage,
    required ConfigManager configs,
    required UtcNow nowUtc,
    ImportedEncryptedHandler? onImportedBlob,
  })  : _storage = storage,
        _configs = configs,
        _nowUtc = nowUtc,
        localSource = LocalSyncSource(
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
    final currentUnixSeconds = _unixSeconds(_nowUtc());
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
        remaining: _SyncLimit(reverseSyncPushLimit),
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

Future<int> recursiveSync({
  required String prefix,
  required MessageIndexNode node,
  required SyncSource from,
  required SyncSource to,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
}) async {
  return _recursiveSyncWithLimit(
    prefix: prefix,
    node: node,
    from: from,
    to: to,
    currentUnixSeconds: currentUnixSeconds,
    configs: configs,
    verifyPow: verifyPow,
  );
}

Future<void> checkSource({
  required SyncSource source,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
  Random? random,
}) async {
  final root = await source.getMessageIndexRoot();
  if (root == null) {
    return;
  }
  try {
    root.validate();
  } on FormatException catch (error) {
    throw SyncSourceException.invalidResponse(
      'validate root: ${error.message}',
      details: error,
    );
  }
  if (root.branch != null && root.branch!.childrenCount == 0) {
    return;
  }

  final sampler = random ?? Random();
  for (var i = 0; i < sourceCheckSampleCount; i++) {
    final rank = _sourceCheckRandomRank(root, sampler);
    await _checkSourceSample(
      source: source,
      node: root,
      rank: rank,
      currentUnixSeconds: currentUnixSeconds,
      configs: configs,
      verifyPow: verifyPow,
    );
  }
}

Future<void> _checkSourceSample({
  required SyncSource source,
  required MessageIndexNode node,
  required int rank,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
}) async {
  var current = node;
  var currentRank = rank;
  while (true) {
    final leaf = current.leaf;
    if (leaf != null) {
      await _checkSourceLeaf(
        source: source,
        leaf: leaf,
        currentUnixSeconds: currentUnixSeconds,
        configs: configs,
        verifyPow: verifyPow,
      );
      return;
    }

    final branch = current.branch;
    if (branch == null) {
      throw const SyncSourceException.invalidResponse(
        'message index node must be leaf or branch',
      );
    }
    if (branch.childrenCount == 0) {
      throw SyncSourceException.invalidResponse(
        'sampled empty branch with prefix ${branch.prefix}',
      );
    }

    final children = await _checkSourceLoadChildren(source, branch);
    var offset = 0;
    MessageIndexNode? selected;
    for (final child in children) {
      if (child == null) {
        continue;
      }
      final childSize = _sourceCheckSubtreeSize(child);
      if (currentRank < offset + childSize) {
        selected = child;
        currentRank -= offset;
        break;
      }
      offset += childSize;
    }
    if (selected == null) {
      throw SyncSourceException.invalidResponse(
        'rank $rank is outside branch ${branch.prefix} children count ${branch.childrenCount}',
      );
    }
    current = selected;
  }
}

Future<List<MessageIndexNode?>> _checkSourceLoadChildren(
  SyncSource source,
  MessageIndexBranch branch,
) async {
  final out = List<MessageIndexNode?>.filled(messageIndexChildSlotCount, null);
  var sum = 0;
  var minTtl = 0;
  var maxTtl = 0;

  for (var slot = 0; slot < branch.childrenIds.length; slot++) {
    final childId = branch.childrenIds[slot];
    if (childId == null) {
      continue;
    }
    final child = await source.getMessageIndexNode(childId);
    if (child == null) {
      throw SyncSourceException.invalidResponse(
        'sync source ${source.id} returned nil message index node ${childId.toHex()}',
      );
    }
    try {
      child.validate();
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(
        'validate child node ${childId.toHex()}: ${error.message}',
        details: error,
      );
    }
    final childHash = child.hash();
    if (childHash != childId) {
      throw SyncSourceException.invalidResponse(
        'child node hash ${childHash.toHex()} does not match referenced id ${childId.toHex()}',
      );
    }
    _checkSourceChildSlot(branch.prefix, slot, child);

    final childSize = _sourceCheckSubtreeSize(child);
    if (childSize == 0) {
      throw SyncSourceException.invalidResponse(
        'child node ${childId.toHex()} has zero subtree size',
      );
    }
    sum += childSize;
    final (childMinTtl, childMaxTtl) = _sourceCheckTtlBounds(child);
    if (minTtl == 0 || childMinTtl < minTtl) {
      minTtl = childMinTtl;
    }
    if (childMaxTtl > maxTtl) {
      maxTtl = childMaxTtl;
    }
    out[slot] = child;
  }

  if (sum != branch.childrenCount) {
    throw SyncSourceException.invalidResponse(
      'branch ${branch.prefix} children count ${branch.childrenCount} does not match direct child sum $sum',
    );
  }
  if (minTtl != branch.minTtl || maxTtl != branch.maxTtl) {
    throw SyncSourceException.invalidResponse(
      'branch ${branch.prefix} ttl bounds min=${branch.minTtl} max=${branch.maxTtl} do not match direct child bounds min=$minTtl max=$maxTtl',
    );
  }
  return out;
}

Future<void> _checkSourceLeaf({
  required SyncSource source,
  required MessageIndexLeaf leaf,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
}) async {
  final results = await source.getSyncBlobs(<SyncBlobId>[leaf.syncBlobId]);
  if (results.length != 1) {
    throw SyncSourceException.invalidResponse(
      'sync source ${source.id} returned ${results.length} sync blobs, want 1',
    );
  }
  final blob = results.single;
  if (blob == null) {
    throw SyncSourceException.invalidResponse(
      'sync source ${source.id} returned nil sync blob ${leaf.syncBlobId.toHex()}',
    );
  }
  if (blob.id != leaf.syncBlobId) {
    throw SyncSourceException.invalidResponse(
      'sync source ${source.id} returned sync blob ${blob.id.toHex()}, want ${leaf.syncBlobId.toHex()}',
    );
  }

  ({SyncBlobId id, EncryptedMessage encrypted}) validated;
  try {
    final configTime = _syncBlobConfigTime(blob.payload);
    validated = await parseAndValidateBlob(
      blobPayload: blob.payload,
      currentConfig: configs.configAtUnix(configTime),
      currentUnixSeconds: configTime,
      verifyPow: verifyPow,
    );
  } on FormatException catch (error) {
    throw SyncSourceException.invalidResponse(
      'validate sampled sync blob ${leaf.syncBlobId.toHex()}: ${error.message}',
      details: error,
    );
  }
  if (validated.id != leaf.syncBlobId) {
    throw SyncSourceException.invalidResponse(
      'validated sync blob id ${validated.id.toHex()} does not match sampled leaf ${leaf.syncBlobId.toHex()}',
    );
  }
  if (validated.encrypted.expiresTime != leaf.ttl) {
    throw SyncSourceException.invalidResponse(
      'sync blob ${validated.id.toHex()} ttl mismatch: tree=${leaf.ttl} blob=${validated.encrypted.expiresTime}',
    );
  }
}

int _sourceCheckRandomRank(MessageIndexNode root, Random random) {
  final size = _sourceCheckSubtreeSize(root);
  if (size <= 1) {
    return 0;
  }
  return random.nextInt(size);
}

int _sourceCheckSubtreeSize(MessageIndexNode node) {
  if (node.leaf != null) {
    return 1;
  }
  return node.branch!.childrenCount;
}

(int, int) _sourceCheckTtlBounds(MessageIndexNode node) {
  final leaf = node.leaf;
  if (leaf != null) {
    return (leaf.ttl, leaf.ttl);
  }
  final branch = node.branch!;
  return (branch.minTtl, branch.maxTtl);
}

void _checkSourceChildSlot(
  String parentPrefix,
  int slot,
  MessageIndexNode child,
) {
  final expected = parentPrefix + '0123456789abcdef'[slot];
  final leaf = child.leaf;
  if (leaf != null) {
    if (!_syncPrefixMatchesLeaf(expected, leaf.syncBlobId)) {
      throw SyncSourceException.invalidResponse(
        'leaf ${leaf.syncBlobId.toHex()} does not belong to parent slot $expected',
      );
    }
    return;
  }

  final branch = child.branch;
  if (branch == null) {
    throw const SyncSourceException.invalidResponse(
      'message index child must be leaf or branch',
    );
  }
  if (branch.prefix.length <= parentPrefix.length ||
      !branch.prefix.startsWith(expected)) {
    throw SyncSourceException.invalidResponse(
      'branch prefix ${branch.prefix} does not belong to parent slot $expected',
    );
  }
}

Future<int> _recursiveSyncWithLimit({
  required String prefix,
  required MessageIndexNode node,
  required SyncSource from,
  required SyncSource to,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
  _SyncLimit? remaining,
}) async {
  if (remaining != null && remaining.value <= 0) {
    return 0;
  }
  final existing = await to.getMessageIndexNode(node.hash());
  if (existing != null) {
    return 0;
  }

  final leaf = node.leaf;
  if (leaf != null) {
    if (!_syncPrefixMatchesLeaf(prefix, leaf.syncBlobId)) {
      return 0;
    }
    if (leaf.ttl <= currentUnixSeconds) {
      return 0;
    }
    remaining?.value--;
    await importLeaf(
      leaf: leaf,
      from: from,
      to: to,
      currentUnixSeconds: currentUnixSeconds,
      configs: configs,
      verifyPow: verifyPow,
    );
    return 1;
  }

  final branch = node.branch;
  if (branch == null) {
    throw const FormatException('message index node must be leaf or branch');
  }
  if (branch.maxTtl < currentUnixSeconds) {
    return 0;
  }
  if (branch.childrenCount == 0) {
    return 0;
  }

  if (branch.prefix.length < prefix.length) {
    if (!prefix.startsWith(branch.prefix)) {
      return 0;
    }
    final childIndex = _nibbleIndex(prefix.codeUnitAt(branch.prefix.length));
    final childId = branch.childrenIds[childIndex];
    if (childId == null) {
      return 0;
    }
    final child = await from.getMessageIndexNode(childId);
    if (child == null) {
      throw FormatException(
        'sync source ${from.id} returned nil message index node ${childId.toHex()}',
      );
    }
    return _recursiveSyncWithLimit(
      prefix: prefix,
      node: child,
      from: from,
      to: to,
      currentUnixSeconds: currentUnixSeconds,
      configs: configs,
      verifyPow: verifyPow,
      remaining: remaining,
    );
  }

  if (!branch.prefix.startsWith(prefix)) {
    return 0;
  }

  var imported = 0;
  for (final childId in branch.childrenIds) {
    if (childId == null) {
      continue;
    }
    final child = await from.getMessageIndexNode(childId);
    if (child == null) {
      throw FormatException(
        'sync source ${from.id} returned nil message index node ${childId.toHex()}',
      );
    }
    imported += await _recursiveSyncWithLimit(
      prefix: prefix,
      node: child,
      from: from,
      to: to,
      currentUnixSeconds: currentUnixSeconds,
      configs: configs,
      verifyPow: verifyPow,
      remaining: remaining,
    );
    if (remaining != null && remaining.value <= 0) {
      return imported;
    }
  }
  return imported;
}

final class _SyncLimit {
  _SyncLimit(this.value);

  int value;
}

Future<void> importLeaf({
  required MessageIndexLeaf leaf,
  required SyncSource from,
  required SyncSource to,
  required int currentUnixSeconds,
  required ConfigManager configs,
  required PowProofVerifier verifyPow,
}) async {
  final results = await from.getSyncBlobs(<SyncBlobId>[leaf.syncBlobId]);
  if (results.length != 1) {
    throw FormatException(
      'sync source ${from.id} returned ${results.length} sync blobs, want 1',
    );
  }
  final blob = results.single;
  if (blob == null) {
    throw FormatException(
      'sync source ${from.id} returned nil sync blob ${leaf.syncBlobId.toHex()}',
    );
  }
  if (blob.id != leaf.syncBlobId) {
    throw FormatException(
      'sync source ${from.id} returned sync blob ${blob.id.toHex()}, want ${leaf.syncBlobId.toHex()}',
    );
  }

  final configTime = _syncBlobConfigTime(blob.payload);
  final validated = await parseAndValidateBlob(
    blobPayload: blob.payload,
    currentConfig: configs.configAtUnix(configTime),
    currentUnixSeconds: configTime,
    verifyPow: verifyPow,
  );
  if (validated.id != leaf.syncBlobId) {
    throw FormatException(
      'validated sync blob id ${validated.id.toHex()} does not match tree leaf ${leaf.syncBlobId.toHex()}',
    );
  }
  if (validated.encrypted.expiresTime != leaf.ttl) {
    throw FormatException(
      'sync blob ${validated.id.toHex()} ttl mismatch: tree=${leaf.ttl} blob=${validated.encrypted.expiresTime}',
    );
  }
  await to.push(
    blob,
    validationContext: ImportValidationContext(
      configs: configs,
      verifyPow: verifyPow,
    ),
  );
}

EncryptedMessage encryptedMessageFromPowEnvelope(Uint8List blobPayload) {
  final envelope = PowEnvelope.fromBytes(blobPayload);
  return EncryptedMessage.fromBytes(envelope.object);
}

int _syncBlobConfigTime(Uint8List blobPayload) {
  return encryptedConfigTimeUnix(parseSyncBlobPayload(blobPayload).encrypted);
}

final class RegisteredSource implements SyncSource {
  RegisteredSource({
    required SyncSource source,
    required DateTime createdAt,
    required double rating,
    DateTime? lastOnlineAt,
    DateTime? lastSavedAt,
  })  : _source = source,
        createdAt = createdAt.toUtc(),
        lastOnlineAt = lastOnlineAt?.toUtc(),
        lastSavedAt = lastSavedAt?.toUtc(),
        rating = rating.isNaN ? ratingDefault : rating;

  final SyncSource _source;
  final DateTime createdAt;
  DateTime? lastOnlineAt;
  DateTime? lastSavedAt;
  double rating;

  @override
  String get id => _source.id;

  @override
  SyncSourceFlags get flags => _source.flags;

  void decreaseRatingMul(double coefficient) {
    rating /= coefficient;
    if (rating.isNaN) {
      rating = 0;
    }
  }

  void increaseRatingConst(double coefficient) {
    rating += coefficient;
    if (rating.isNaN) {
      rating = ratingDefault;
    }
  }

  void markOnline(DateTime now) {
    final utc = now.toUtc();
    if (lastOnlineAt == null || utc.isAfter(lastOnlineAt!)) {
      lastOnlineAt = utc;
    }
  }

  bool onlineSince(DateTime cutoff) {
    final onlineAt = lastOnlineAt;
    return onlineAt != null && !onlineAt.isBefore(cutoff.toUtc());
  }

  bool shouldDrop(DateTime staleBefore, DateTime offlineStartupBefore) {
    final onlineAt = lastOnlineAt;
    if (onlineAt == null) {
      return createdAt.isBefore(offlineStartupBefore.toUtc());
    }
    return onlineAt.isBefore(staleBefore.toUtc());
  }

  PeerRecord? peerRecordForSave() {
    final onlineAt = lastOnlineAt;
    if (onlineAt == null) {
      return null;
    }
    final savedAt = lastSavedAt;
    if (savedAt != null && !onlineAt.isAfter(savedAt)) {
      return null;
    }
    return PeerRecord(
      id: id,
      createdAt: createdAt,
      lastOnlineAt: onlineAt,
      rating: rating,
    );
  }

  void markSaved(DateTime savedOnlineAt) {
    final onlineAt = lastOnlineAt;
    if (onlineAt != null && !onlineAt.isAfter(savedOnlineAt.toUtc())) {
      lastSavedAt = savedOnlineAt.toUtc();
    }
  }

  @override
  Future<List<ConfigRecord>> getConfigs() => _source.getConfigs();

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    final root = await _source.getMessageIndexRoot();
    if (root != null) {
      markOnline(DateTime.now().toUtc());
    }
    return root;
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) {
    return _source.getMessageIndexNode(id);
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) {
    return _source.getSyncBlobs(ids);
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) =>
      _source.push(blob, validationContext: validationContext);

  @override
  Future<List<String>> discoverPeers() => _source.discoverPeers();

  @override
  void stop() => _source.stop();
}

final class SourceRegistry {
  SourceRegistry({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    SourcePermutation? permutation,
  })  : _storage = storage,
        _nowUtc = nowUtc,
        _permutation = permutation ?? _randomPermutation;

  final DdmSqliteStorage _storage;
  final UtcNow _nowUtc;
  final SourcePermutation _permutation;
  final Map<String, RegisteredSource> _sources = <String, RegisteredSource>{};

  bool add(SyncSource source) {
    if (_sources.containsKey(source.id)) {
      return false;
    }
    _sources[source.id] = _newRegisteredSource(source);
    return true;
  }

  RegisteredSource addOrGet(SyncSource source) {
    final existing = _sources[source.id];
    if (existing != null) {
      source.stop();
      return existing;
    }
    final registered = _newRegisteredSource(source);
    _sources[source.id] = registered;
    return registered;
  }

  bool addStored(SyncSource source, PeerRecord peer) {
    if (_sources.containsKey(source.id)) {
      return false;
    }
    _sources[source.id] = RegisteredSource(
      source: source,
      createdAt: peer.createdAt,
      lastOnlineAt: peer.lastOnlineAt,
      lastSavedAt: peer.lastOnlineAt,
      rating: peer.rating,
    );
    return true;
  }

  List<RegisteredSource> getActive(int count) {
    final now = _nowUtc();
    final staleBefore = now.subtract(sourceRetention);
    final offlineStartupBefore = now.subtract(sourceOfflineStartup);
    final removed = <String>[];
    for (final item in _sources.entries) {
      if (item.value.shouldDrop(staleBefore, offlineStartupBefore)) {
        item.value.stop();
        removed.add(item.key);
      }
    }
    for (final id in removed) {
      _sources.remove(id);
    }
    return selectActiveSources(
      _sources.values.toList(growable: false),
      now,
      count,
      permutation: _permutation,
    );
  }

  int onlineCountSince(DateTime cutoff) {
    return _sources.values.where((source) => source.onlineSince(cutoff)).length;
  }

  List<SyncSource> peerExchangeSources() {
    return _sources.values
        .where((source) => source.flags.has(syncSourceFlagSupportPeerExchange))
        .toList(growable: false);
  }

  List<String> sourceIds() {
    return _sources.keys.toList(growable: false)..sort();
  }

  void saveUpdatedPeers() {
    final records = <PeerRecord>[];
    for (final source in _sources.values) {
      final record = source.peerRecordForSave();
      if (record != null) {
        records.add(record);
      }
    }
    _storage.peers.upsertPeers(records);
    _storage.peers
        .deletePeersLastOnlineBefore(_nowUtc().subtract(sourceRetention));
    for (final record in records) {
      _sources[record.id]?.markSaved(record.lastOnlineAt!);
    }
  }

  void close() {
    for (final source in _sources.values) {
      source.stop();
    }
  }

  RegisteredSource _newRegisteredSource(SyncSource source) {
    return RegisteredSource(
      source: source,
      createdAt: _nowUtc(),
      rating: ratingDefault,
    );
  }
}

List<RegisteredSource> selectActiveSources(
  List<RegisteredSource> sources,
  DateTime now,
  int count, {
  SourcePermutation? permutation,
}) {
  if (count <= 0 || sources.isEmpty) {
    return const <RegisteredSource>[];
  }
  final limit = count > sources.length ? sources.length : count;
  final recentSince = now.toUtc().subtract(sourceOnlineWindow);
  final bad = <RegisteredSource>[];
  final old = <RegisteredSource>[];
  final healthyRecent = <RegisteredSource>[];
  final healthyOld = <RegisteredSource>[];

  for (final source in sources) {
    final onlineAt = source.lastOnlineAt;
    final recent = onlineAt != null && !onlineAt.isBefore(recentSince);
    if (source.rating < ratingDefault) {
      bad.add(source);
    }
    if (!recent) {
      old.add(source);
    }
    if (source.rating >= ratingDefault && recent) {
      healthyRecent.add(source);
    }
    if (source.rating >= ratingDefault && !recent) {
      healthyOld.add(source);
    }
  }

  final selected = <RegisteredSource>[];
  final seen = <RegisteredSource>{};
  final perm = permutation ?? _randomPermutation;
  _pickRandom(selected, seen, bad, limit ~/ 10, limit, perm);
  _pickRandom(selected, seen, old, limit ~/ 10, limit, perm);
  _pickRandom(
    selected,
    seen,
    healthyRecent,
    limit - selected.length,
    limit,
    perm,
  );
  _pickRandom(
    selected,
    seen,
    healthyOld,
    limit - selected.length,
    limit,
    perm,
  );
  _pickRandom(selected, seen, sources, limit - selected.length, limit, perm);
  return selected;
}

BlobIndex _buildIndex({
  required DdmSqliteStorage storage,
  required UtcNow nowUtc,
}) {
  final now = _unixSeconds(nowUtc());
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

bool _syncPrefixMatchesLeaf(String syncPrefix, SyncBlobId id) {
  if (syncPrefix.isEmpty) {
    return true;
  }
  return id.toHex().startsWith(syncPrefix);
}

void _pickRandom(
  List<RegisteredSource> out,
  Set<RegisteredSource> seen,
  List<RegisteredSource> candidates,
  int quota,
  int limit,
  SourcePermutation permutation,
) {
  if (quota <= 0 || out.length >= limit) {
    return;
  }
  var picked = 0;
  for (final idx in permutation(candidates.length)) {
    final item = candidates[idx];
    if (seen.contains(item)) {
      continue;
    }
    out.add(item);
    seen.add(item);
    picked++;
    if (out.length >= limit || picked >= quota) {
      return;
    }
  }
}

List<int> _randomPermutation(int length) {
  final values = List<int>.generate(length, (idx) => idx);
  final random = Random.secure();
  for (var i = values.length - 1; i > 0; i--) {
    final j = random.nextInt(i + 1);
    final tmp = values[i];
    values[i] = values[j];
    values[j] = tmp;
  }
  return values;
}

int _unixSeconds(DateTime value) {
  final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xffffffff) {
    throw FormatException('unix timestamp out of uint32 range: $seconds');
  }
  return seconds;
}

int _nibbleIndex(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  throw FormatException('invalid nibble ${String.fromCharCode(codeUnit)}');
}

int _sharedPrefixLen(String a, String b) {
  var n = a.length;
  if (b.length < n) {
    n = b.length;
  }
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

int _minTtl(int a, int b) => a == 0 || b < a ? b : a;

int _maxTtl(int a, int b) => a > b ? a : b;

enum _MessageIndexNodeKind { branch, leaf }

final class _MessageIndexNode {
  _MessageIndexNode._({
    required this.kind,
    required this.prefix,
    required this.leafTTL,
    required this.childrenCount,
    required this.minChildTTL,
    required this.maxChildTTL,
    required List<_MessageIndexNode?> children,
  })  : children = List<_MessageIndexNode?>.unmodifiable(children),
        hash = _calculateHash(kind, prefix, children);

  factory _MessageIndexNode.emptyBranch() {
    return _MessageIndexNode._(
      kind: _MessageIndexNodeKind.branch,
      prefix: '',
      leafTTL: 0,
      childrenCount: 0,
      minChildTTL: 0,
      maxChildTTL: 0,
      children:
          List<_MessageIndexNode?>.filled(messageIndexChildSlotCount, null),
    );
  }

  factory _MessageIndexNode.leaf(String prefix, int ttl) {
    _validatePrefix(prefix);
    return _MessageIndexNode._(
      kind: _MessageIndexNodeKind.leaf,
      prefix: prefix,
      leafTTL: ttl,
      childrenCount: 0,
      minChildTTL: 0,
      maxChildTTL: 0,
      children:
          List<_MessageIndexNode?>.filled(messageIndexChildSlotCount, null),
    );
  }

  final _MessageIndexNodeKind kind;
  final String prefix;
  final int leafTTL;
  final int childrenCount;
  final int minChildTTL;
  final int maxChildTTL;
  final List<_MessageIndexNode?> children;
  final MessageIndexNodeId hash;

  bool get isLeaf => kind == _MessageIndexNodeKind.leaf;

  _MessageIndexNode add(String nextPrefix, int ttl) {
    _validatePrefix(nextPrefix);
    final sharedLen = _sharedPrefixLen(prefix, nextPrefix);
    _MessageIndexNode next;

    if (sharedLen == prefix.length) {
      if (isLeaf) {
        return this;
      }
      final index = _nibbleIndex(nextPrefix.codeUnitAt(sharedLen));
      final copiedChildren = List<_MessageIndexNode?>.from(children);
      final nextChild = copiedChildren[index] == null
          ? _MessageIndexNode.leaf(nextPrefix, ttl)
          : copiedChildren[index]!.add(nextPrefix, ttl);
      copiedChildren[index] = nextChild;
      next = _MessageIndexNode.branch(prefix, copiedChildren);
    } else {
      final newChild = _MessageIndexNode.leaf(nextPrefix, ttl);
      final nextChildren = List<_MessageIndexNode?>.filled(
        messageIndexChildSlotCount,
        null,
      );
      nextChildren[_nibbleIndex(nextPrefix.codeUnitAt(sharedLen))] = newChild;
      nextChildren[_nibbleIndex(prefix.codeUnitAt(sharedLen))] = this;
      next = _MessageIndexNode.branch(
          nextPrefix.substring(0, sharedLen), nextChildren);
    }
    return next;
  }

  factory _MessageIndexNode.branch(
    String prefix,
    List<_MessageIndexNode?> children,
  ) {
    _validatePrefix(prefix);
    var childrenCount = 0;
    var minChildTTL = 0;
    var maxChildTTL = 0;
    for (final child in children) {
      if (child == null) {
        continue;
      }
      childrenCount += child.childrenCountValue;
      minChildTTL = _minTtl(minChildTTL, child.minChildTTLValue);
      maxChildTTL = _maxTtl(maxChildTTL, child.maxChildTTLValue);
    }
    return _MessageIndexNode._(
      kind: _MessageIndexNodeKind.branch,
      prefix: prefix,
      leafTTL: 0,
      childrenCount: childrenCount,
      minChildTTL: minChildTTL,
      maxChildTTL: maxChildTTL,
      children: children,
    );
  }

  _MessageIndexNode? collectExpiredGarbage(int lessOrEqualTTL) {
    if (isLeaf) {
      return leafTTL <= lessOrEqualTTL ? null : this;
    }
    if (minChildTTL > lessOrEqualTTL && minChildTTL != 0) {
      return this;
    }

    final copiedChildren = List<_MessageIndexNode?>.filled(
      messageIndexChildSlotCount,
      null,
    );
    var directChildren = 0;
    _MessageIndexNode? onlyChild;
    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      if (child == null) {
        continue;
      }
      final nextChild = child.collectExpiredGarbage(lessOrEqualTTL);
      if (nextChild == null) {
        continue;
      }
      copiedChildren[index] = nextChild;
      directChildren++;
      onlyChild = nextChild;
    }
    final copied = _MessageIndexNode.branch(prefix, copiedChildren);
    if (copied.childrenCount == 0) {
      return null;
    }
    if (directChildren == 1 && onlyChild != null) {
      return onlyChild;
    }
    return copied;
  }

  int get childrenCountValue => isLeaf ? 1 : childrenCount;

  int get minChildTTLValue => isLeaf ? leafTTL : minChildTTL;

  int get maxChildTTLValue => isLeaf ? leafTTL : maxChildTTL;

  SyncBlobId? syncBlobIdOrNull() {
    if (!isLeaf) {
      return null;
    }
    return SyncBlobId.parseHex(prefix);
  }

  MessageIndexNode toProto() {
    if (isLeaf) {
      return MessageIndexNode.leaf(
        MessageIndexLeaf(syncBlobId: SyncBlobId.parseHex(prefix), ttl: leafTTL),
      );
    }
    final childIds = <MessageIndexNodeId?>[];
    for (final child in children) {
      childIds.add(child?.hash);
    }
    return MessageIndexNode.branch(
      MessageIndexBranch(
        prefix: prefix,
        childrenCount: childrenCount,
        minTtl: minChildTTL,
        maxTtl: maxChildTTL,
        childrenIds: childIds,
      ),
    );
  }

  static MessageIndexNodeId _calculateHash(
    _MessageIndexNodeKind kind,
    String prefix,
    List<_MessageIndexNode?> children,
  ) {
    if (kind == _MessageIndexNodeKind.leaf) {
      return MessageIndexNodeId(
          sha256Bytes(SyncBlobId.parseHex(prefix).toBytes()));
    }
    final chunks = <int>[];
    for (final child in children) {
      if (child != null) {
        chunks.addAll(child.hash.toBytes());
      }
    }
    return MessageIndexNodeId(sha256Bytes(Uint8List.fromList(chunks)));
  }
}

final class _IndexedMessageIndexNode {
  _IndexedMessageIndexNode({required this.node});

  final _MessageIndexNode node;
  int refs = 0;
}

final class _BlobsAddedNodeRecord {
  const _BlobsAddedNodeRecord({required this.prefix, required this.expiresAt});

  final String prefix;
  final int expiresAt;
}

final class _BlobIndexRootEntry {
  const _BlobIndexRootEntry({
    required this.createdAtUnix,
    required this.node,
    required this.createdByAddingNode,
  });

  final int createdAtUnix;
  final _IndexedMessageIndexNode node;
  final _BlobsAddedNodeRecord? createdByAddingNode;

  _BlobIndexRootEntry withoutAddMetadata() {
    return _BlobIndexRootEntry(
      createdAtUnix: createdAtUnix,
      node: node,
      createdByAddingNode: null,
    );
  }
}

void _validatePrefix(String prefix) {
  if (!streamHexPrefixRe.hasMatch(prefix)) {
    throw const FormatException(
      'nibble string must contain only lowercase hex chars [0-9a-f]',
    );
  }
  if (prefix.length > syncBlobIdSize * 2) {
    throw FormatException(
        'prefix must be at most ${syncBlobIdSize * 2} nibbles');
  }
}
