part of '../p2p.dart';

ConfigRecord _configRecordFromWire(Object? item) {
  if (item is! Uint8List) {
    throw const FormatException('decode config record');
  }
  return parseConfigRecord(item);
}

Object _messageIndexNodeToWire(MessageIndexNode node) {
  node.validate();
  final leaf = node.leaf;
  if (leaf != null) {
    return <Object?>[
      <Object?>[leaf.syncBlobId.toBytes(), leaf.ttl],
      null,
    ];
  }

  final branch = node.branch;
  if (branch == null) {
    throw const FormatException('message index node has no variant');
  }
  return <Object?>[
    null,
    <Object?>[
      branch.prefix,
      branch.childrenCount,
      branch.minTtl,
      branch.maxTtl,
      branch.childrenIds
          .map<Object?>((id) => id?.toBytes())
          .toList(growable: false),
    ],
  ];
}

MessageIndexNode _messageIndexNodeFromWire(Object wire) {
  if (wire is! List<Object?> || wire.length != 2) {
    throw const FormatException('decode message index node');
  }
  final leaf = wire[0];
  final branch = wire[1];
  if (leaf != null && branch != null) {
    throw const FormatException(
      'message index node has both leaf and branch variants',
    );
  }
  if (leaf != null) {
    if (leaf is! List<Object?> || leaf.length != 2) {
      throw const FormatException('decode message index leaf');
    }
    final rawId = leaf[0];
    final ttl = leaf[1];
    if (rawId is! Uint8List || ttl is! int) {
      throw const FormatException('decode message index leaf');
    }
    final node = MessageIndexNode.leaf(
      MessageIndexLeaf(syncBlobId: SyncBlobId(rawId), ttl: ttl),
    );
    node.validate();
    return node;
  }
  if (branch != null) {
    if (branch is! List<Object?> || branch.length != 5) {
      throw const FormatException('decode message index branch');
    }
    final prefix = branch[0];
    final childrenCount = branch[1];
    final minTtl = branch[2];
    final maxTtl = branch[3];
    final rawChildren = branch[4];
    if (prefix is! String ||
        childrenCount is! int ||
        minTtl is! int ||
        maxTtl is! int ||
        rawChildren is! List<Object?>) {
      throw const FormatException('decode message index branch');
    }
    if (rawChildren.length != messageIndexChildSlotCount) {
      throw FormatException(
        'message index branch has ${rawChildren.length} children, want $messageIndexChildSlotCount',
      );
    }
    final children = <MessageIndexNodeId?>[];
    for (var i = 0; i < rawChildren.length; i++) {
      final rawChild = rawChildren[i];
      if (rawChild == null) {
        children.add(null);
        continue;
      }
      if (rawChild is! Uint8List) {
        throw FormatException('parse branch child $i');
      }
      children.add(MessageIndexNodeId(rawChild));
    }
    final node = MessageIndexNode.branch(
      MessageIndexBranch(
        prefix: prefix,
        childrenCount: childrenCount,
        minTtl: minTtl,
        maxTtl: maxTtl,
        childrenIds: children,
      ),
    );
    node.validate();
    return node;
  }
  throw const FormatException('message index node has no variant');
}
