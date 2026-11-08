part of '../sync.dart';

typedef _SyncCheckpoint = ({
  MessageIndexNodeId? local,
  MessageIndexNodeId? remote,
  List<StreamPrefix> pull,
  List<StreamPrefix> push,
});

bool _sameCoverage(List<StreamPrefix> a, List<StreamPrefix> b) =>
    a.length == b.length && a.indexed.every((entry) => entry.$2 == b[entry.$1]);

String _nodeKey(MessageIndexNode node) =>
    node.leaf?.syncBlobId.toHex() ?? node.branch!.prefix;

bool _overlapsCoverage(String key, List<StreamPrefix> coverage) => coverage.any(
    (prefix) => key.startsWith(prefix.value) || prefix.value.startsWith(key));

// Compare captured subtrees in both directions, aligning compressed paths.
Future<int> _reconcile(
    MessageIndexNode? left,
    MessageIndexNode? right,
    SyncSource local,
    SyncSource remote,
    List<StreamPrefix> pull,
    List<StreamPrefix> push,
    BlobValidator validate) async {
  left?.validate();
  right?.validate();
  if (left == null && right == null) return 0;
  if (left != null && right != null && left.hash() == right.hash()) return 0;
  if (left == null) {
    if (!_overlapsCoverage(_nodeKey(right!), pull)) return 0;
    if (await local.getMessageIndexNode(right.hash()) != null) return 0;
    if (right.leaf != null) {
      return await importLeaf(
              leaf: right.leaf!,
              from: remote,
              to: local,
              validateBlob: validate)
          ? 1
          : 0;
    }
  }
  if (right == null) {
    if (!_overlapsCoverage(_nodeKey(left!), push)) return 0;
    if (await remote.getMessageIndexNode(left.hash()) != null) return 0;
    if (left.leaf != null) {
      await importLeaf(
          leaf: left.leaf!, from: local, to: remote, validateBlob: validate);
      return 0;
    }
  }
  final key = _nodeKey(left ?? right!);
  var depth = key.length;
  if (left != null && right != null) {
    final other = _nodeKey(right);
    depth = 0;
    while (depth < key.length &&
        depth < other.length &&
        key[depth] == other[depth]) {
      depth++;
    }
  }
  final prefix = key.substring(0, depth);
  if (!_overlapsCoverage(prefix, pull) && !_overlapsCoverage(prefix, push)) {
    return 0;
  }
  final localChildren = await _reconcileChildren(local, left, depth);
  final remoteChildren = await _reconcileChildren(remote, right, depth);
  var imported = 0;
  // Vary traversal order to spread concurrent exchanges across subtrees.
  final slots = List.generate(messageIndexChildSlotCount, (slot) => slot)
    ..shuffle();
  for (final slot in slots) {
    imported += await _reconcile(localChildren[slot], remoteChildren[slot],
        local, remote, pull, push, validate);
  }
  return imported;
}

// A compressed path stays intact until its branch depth is reached.
Future<List<MessageIndexNode?>> _reconcileChildren(
    SyncSource source, MessageIndexNode? node, int depth) async {
  if (node?.branch != null && node!.branch!.prefix.length == depth) {
    return _checkSourceLoadChildren(source, node.branch!);
  }
  final children =
      List<MessageIndexNode?>.filled(messageIndexChildSlotCount, null);
  if (node != null) {
    children[int.parse(_nodeKey(node)[depth], radix: 16)] = node;
  }
  return children;
}

// Import a captured source snapshot through the shared reconciliation algorithm.
Future<int> importSnapshot({
  required String prefix,
  required MessageIndexNode node,
  required SyncSource from,
  required SyncSource to,
  required BlobValidator validateBlob,
}) async {
  final local = await to.getMessageIndexRoot();
  return _reconcile(local, node, to, from,
      [StreamPrefix(StreamId.normalizePrefix(prefix))], const [], validateBlob);
}

bool _syncPrefixMatchesLeaf(String syncPrefix, SyncBlobId id) {
  if (syncPrefix.isEmpty) {
    return true;
  }
  return id.toHex().startsWith(syncPrefix);
}

Future<MessageIndexNode?> _syncSubtree(
    SyncSource source, MessageIndexNode? node, String prefix) async {
  while (node != null) {
    node.validate();
    final leaf = node.leaf;
    if (leaf != null) {
      return _syncPrefixMatchesLeaf(prefix, leaf.syncBlobId) ? node : null;
    }
    final branch = node.branch!;
    if (branch.prefix.startsWith(prefix)) return node;
    if (!prefix.startsWith(branch.prefix)) return null;
    final children = await _checkSourceLoadChildren(source, branch);
    node = children[int.parse(prefix[branch.prefix.length], radix: 16)];
  }
  return null;
}
