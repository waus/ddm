import 'dart:typed_data';

import 'package:ddm_proto_dart/src/storage/messages.dart';
import 'package:ddm_proto_dart/src/storage/sync_blobs.dart';

final class PublishedOutboxMessage {
  PublishedOutboxMessage({
    required this.message,
    required this.syncBlob,
    required this.difficulty,
    required this.powElapsed,
  });

  final MessageRecord message;
  final SyncBlobRecord syncBlob;
  final int difficulty;
  final Duration powElapsed;
}

final class PublishedSyncBlob {
  PublishedSyncBlob({
    required this.syncBlob,
    required this.difficulty,
    required this.powElapsed,
  });

  final SyncBlobRecord syncBlob;
  final int difficulty;
  final Duration powElapsed;
}

final class PreparedPowEnvelopePayload {
  PreparedPowEnvelopePayload({
    required this.payload,
    required this.difficulty,
    required this.powElapsed,
  });

  final Uint8List payload;
  final int difficulty;
  final Duration powElapsed;
}
