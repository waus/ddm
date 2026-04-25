import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';

final class MessageIndexLeaf {
  const MessageIndexLeaf({required this.syncBlobId, required this.ttl});

  final SyncBlobId syncBlobId;
  final int ttl;
}

final class MessageIndexBranch {
  MessageIndexBranch({
    required this.prefix,
    required this.childrenCount,
    required this.minTtl,
    required this.maxTtl,
    required List<MessageIndexNodeId?> childrenIds,
  }) : childrenIds = List<MessageIndexNodeId?>.from(childrenIds) {
    if (this.childrenIds.length != messageIndexChildSlotCount) {
      throw FormatException(
        'message index branch must have $messageIndexChildSlotCount child slots, got ${this.childrenIds.length}',
      );
    }
  }

  final String prefix;
  final int childrenCount;
  final int minTtl;
  final int maxTtl;
  final List<MessageIndexNodeId?> childrenIds;
}

final class MessageIndexNode {
  const MessageIndexNode.leaf(this.leaf) : branch = null;
  const MessageIndexNode.branch(this.branch) : leaf = null;

  final MessageIndexLeaf? leaf;
  final MessageIndexBranch? branch;

  void validate() {
    if ((leaf == null && branch == null) || (leaf != null && branch != null)) {
      throw const FormatException(
        'message index node must contain exactly one variant',
      );
    }
    if (branch != null) {
      _validateBranch(branch!);
    }
  }

  MessageIndexNodeId hash() {
    if (leaf != null) {
      return MessageIndexNodeId(sha256Bytes(leaf!.syncBlobId.toBytes()));
    }
    final chunks = <int>[];
    for (final child in branch!.childrenIds) {
      if (child == null) {
        continue;
      }
      chunks.addAll(child.toBytes());
    }
    return MessageIndexNodeId(sha256Bytes(Uint8List.fromList(chunks)));
  }

  Uint8List toBytes() {
    validate();
    if (leaf != null) {
      return ddmCborCodec.encode(
        CborTag(messageIndexNodeLeafTagNum, <Object?>[
          leaf!.syncBlobId.toBytes(),
          leaf!.ttl,
        ]),
      );
    }

    final children = <Object?>[];
    for (final child in branch!.childrenIds) {
      children.add(child?.toBytes());
    }

    return ddmCborCodec.encode(
      CborTag(messageIndexNodeBranchTagNum, <Object?>[
        branch!.prefix,
        branch!.childrenCount,
        branch!.minTtl,
        branch!.maxTtl,
        children,
      ]),
    );
  }

  static MessageIndexNode fromBytes(Uint8List data) {
    final decoded = ddmCborCodec.decode(data);
    if (decoded is! CborTag) {
      throw const FormatException('decode message index node');
    }

    if (decoded.number == messageIndexNodeLeafTagNum) {
      final content = decoded.value;
      if (content is! List<Object?> || content.length != 2) {
        throw const FormatException('decode message index leaf tag');
      }
      final syncBlobId = content[0];
      final ttl = content[1];
      if (syncBlobId is! Uint8List || ttl is! int) {
        throw const FormatException('decode message index leaf tag');
      }
      return MessageIndexNode.leaf(
        MessageIndexLeaf(syncBlobId: SyncBlobId(syncBlobId), ttl: ttl),
      );
    }

    if (decoded.number == messageIndexNodeBranchTagNum) {
      final content = decoded.value;
      if (content is! List<Object?> || content.length != 5) {
        throw const FormatException('decode message index branch tag');
      }
      final prefix = content[0];
      final childrenCount = content[1];
      final minTtl = content[2];
      final maxTtl = content[3];
      final childRaw = content[4];
      if (prefix is! String ||
          childrenCount is! int ||
          minTtl is! int ||
          maxTtl is! int ||
          childRaw is! List<Object?>) {
        throw const FormatException('decode message index branch tag');
      }
      if (childRaw.length != messageIndexChildSlotCount) {
        throw FormatException(
          'message index branch must have $messageIndexChildSlotCount child slots, got ${childRaw.length}',
        );
      }
      final children = <MessageIndexNodeId?>[];
      for (final item in childRaw) {
        if (item == null) {
          children.add(null);
          continue;
        }
        if (item is! Uint8List) {
          throw const FormatException('decode message index branch child id');
        }
        children.add(MessageIndexNodeId(item));
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

    throw FormatException(
      'unsupported message index node tag ${decoded.number}, want $messageIndexNodeBranchTagNum or $messageIndexNodeLeafTagNum',
    );
  }
}

void _validateBranch(MessageIndexBranch branch) {
  final validPrefix = streamHexPrefixRe.hasMatch(branch.prefix);
  if (!validPrefix) {
    throw const FormatException(
      'nibble string must contain only lowercase hex chars [0-9a-f]',
    );
  }
  if (branch.prefix.length > syncBlobIdSize * 2) {
    throw FormatException(
      'prefix must be at most ${syncBlobIdSize * 2} nibbles',
    );
  }

  var directChildren = 0;
  for (final child in branch.childrenIds) {
    if (child != null) {
      directChildren++;
    }
  }

  if (branch.childrenCount == 0) {
    if (directChildren != 0) {
      throw const FormatException(
        'message index branch with zero children count must not reference child ids',
      );
    }
    if (branch.minTtl != 0 || branch.maxTtl != 0) {
      throw const FormatException(
        'message index branch with zero children count must have zero ttl bounds',
      );
    }
    return;
  }

  if (directChildren == 0) {
    throw const FormatException(
      'message index branch with children count must reference at least one child id',
    );
  }
  if (branch.childrenCount < directChildren) {
    throw FormatException(
      'message index branch children count ${branch.childrenCount} must cover at least $directChildren direct children',
    );
  }
  if (branch.minTtl == 0) {
    throw const FormatException(
      'message index branch min ttl must be non-zero when children are present',
    );
  }
  if (branch.minTtl > branch.maxTtl) {
    throw FormatException(
      'message index branch min ttl ${branch.minTtl} must not exceed max ttl ${branch.maxTtl}',
    );
  }
}
