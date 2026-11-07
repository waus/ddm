import '../../proto/stream.dart';
import 'dart:async';
import '../../proto/sync_state.dart';

import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/envelope.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';

typedef ImportedEncryptedHandler = FutureOr<void> Function(
    EncryptedMessage encrypted);

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

  Future<void> push(SyncBlob blob);

  Future<List<String>> discoverPeers();

  void stop();
}

abstract interface class SyncStateSource {
  Future<SyncState> getSyncState();
}

Future<SyncState> readSyncState(SyncSource source) async {
  if (source is SyncStateSource) {
    return (source as SyncStateSource).getSyncState();
  }
  return SyncState(
      root: await source.getMessageIndexRoot(), coverage: [StreamPrefix('')]);
}

abstract interface class ShardDiscovery {
  Future<List<SyncSource>> findShardPeers(StreamId stream);
}

abstract interface class PeerIdentitySource {
  String get peerIdentity;
}
