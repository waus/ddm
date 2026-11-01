import 'dart:async';

import 'package:ddm_proto_dart/src/proto/config_manager.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/envelope.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/sync_blob.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';

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
