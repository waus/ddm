part of '../sync.dart';

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
    validateSyncPrefix(prefix);
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
    validateSyncPrefix(nextPrefix);
    final sharedLen = sharedSyncPrefixLength(prefix, nextPrefix);
    _MessageIndexNode next;

    if (sharedLen == prefix.length) {
      if (isLeaf) {
        return this;
      }
      final index = syncNibbleIndex(nextPrefix.codeUnitAt(sharedLen));
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
      nextChildren[syncNibbleIndex(nextPrefix.codeUnitAt(sharedLen))] =
          newChild;
      nextChildren[syncNibbleIndex(prefix.codeUnitAt(sharedLen))] = this;
      next = _MessageIndexNode.branch(
          nextPrefix.substring(0, sharedLen), nextChildren);
    }
    return next;
  }

  factory _MessageIndexNode.branch(
    String prefix,
    List<_MessageIndexNode?> children,
  ) {
    validateSyncPrefix(prefix);
    var childrenCount = 0;
    var minChildTTL = 0;
    var maxChildTTL = 0;
    for (final child in children) {
      if (child == null) {
        continue;
      }
      childrenCount += child.childrenCountValue;
      minChildTTL = minSyncTtl(minChildTTL, child.minChildTTLValue);
      maxChildTTL = maxSyncTtl(maxChildTTL, child.maxChildTTLValue);
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
