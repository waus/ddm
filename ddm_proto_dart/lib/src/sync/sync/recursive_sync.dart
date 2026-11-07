part of '../sync.dart';

Future<void> checkSource({
  required SyncSource source,
  required BlobValidator validateBlob,
  Random? random,
  MessageIndexNode? snapshot,
}) async {
  final root = snapshot ?? await source.getMessageIndexRoot();
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
      validateBlob: validateBlob,
    );
  }
}

Future<void> _checkSourceSample({
  required SyncSource source,
  required MessageIndexNode node,
  required int rank,
  required BlobValidator validateBlob,
}) async {
  var current = node;
  var currentRank = rank;
  while (true) {
    final leaf = current.leaf;
    if (leaf != null) {
      await _checkSourceLeaf(
        source: source,
        leaf: leaf,
        validateBlob: validateBlob,
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
      throw SyncSourceException.unavailable(
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
  required BlobValidator validateBlob,
}) async {
  final results = await source.getSyncBlobs(<SyncBlobId>[leaf.syncBlobId]);
  if (results.length != 1) {
    throw SyncSourceException.invalidResponse(
      'sync source ${source.id} returned ${results.length} sync blobs, want 1',
    );
  }
  final blob = results.single;
  if (blob == null) {
    throw SyncSourceException.unavailable(
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
    validated = await validateBlob(blob.payload);
  } on ExpiredSyncBlob {
    rethrow;
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

Future<int> recursiveSync({
  required String prefix,
  required MessageIndexNode node,
  required SyncSource from,
  required SyncSource to,
  required BlobValidator validateBlob,
  SyncLimit? remaining,
}) async {
  if (remaining != null && remaining.value <= 0) {
    return 0;
  }
  node.validate();
  final existing = await to.getMessageIndexNode(node.hash());
  if (existing != null) {
    return 0;
  }

  final leaf = node.leaf;
  if (leaf != null) {
    if (!_syncPrefixMatchesLeaf(prefix, leaf.syncBlobId)) {
      return 0;
    }
    remaining?.value--;
    final imported = await importLeaf(
      leaf: leaf,
      from: from,
      to: to,
      validateBlob: validateBlob,
    );
    return imported ? 1 : 0;
  }

  final children = await _checkSourceLoadChildren(from, node.branch!);
  var imported = 0;
  for (final child in children) {
    if (child == null) continue;
    final branch = child.branch;
    if (branch != null &&
        !branch.prefix.startsWith(prefix) &&
        !prefix.startsWith(branch.prefix)) {
      continue;
    }
    imported += await recursiveSync(
      prefix: prefix,
      node: child,
      from: from,
      to: to,
      validateBlob: validateBlob,
      remaining: remaining,
    );
    if (remaining != null && remaining.value <= 0) return imported;
  }

  return imported;
}

bool _syncPrefixMatchesLeaf(String syncPrefix, SyncBlobId id) {
  if (syncPrefix.isEmpty) {
    return true;
  }
  return id.toHex().startsWith(syncPrefix);
}
