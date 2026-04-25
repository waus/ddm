import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/_bytes.dart';

final class SyncBlobId {
  SyncBlobId(Uint8List bytes)
      : _bytes = _requireSize(bytes, syncBlobIdSize, 'sync blob id');

  final Uint8List _bytes;

  Uint8List toBytes() => copyBytes(_bytes);

  String toHex() => bytesToHex(_bytes);

  @override
  bool operator ==(Object other) {
    return other is SyncBlobId && bytesEqual(other._bytes, _bytes);
  }

  @override
  int get hashCode => _bytesHash(_bytes);

  @override
  String toString() => toHex();

  static SyncBlobId parseHex(String value) {
    return SyncBlobId(
      parseHexBytes(
        value.trim(),
        expectedBytes: syncBlobIdSize,
        label: 'sync blob id',
      ),
    );
  }
}

final class MessageIndexNodeId {
  MessageIndexNodeId(Uint8List bytes)
      : _bytes = _requireSize(
          bytes,
          messageIndexNodeIdSize,
          'message index node id',
        );

  final Uint8List _bytes;

  Uint8List toBytes() => copyBytes(_bytes);

  String toHex() => bytesToHex(_bytes);

  @override
  bool operator ==(Object other) {
    return other is MessageIndexNodeId && bytesEqual(other._bytes, _bytes);
  }

  @override
  int get hashCode => _bytesHash(_bytes);

  @override
  String toString() => toHex();

  static MessageIndexNodeId parseHex(String value) {
    return MessageIndexNodeId(
      parseHexBytes(
        value.trim(),
        expectedBytes: messageIndexNodeIdSize,
        label: 'message index node id',
      ),
    );
  }
}

final class SyncBlob {
  const SyncBlob({required this.id, required this.payload});

  final SyncBlobId id;
  final Uint8List payload;
}

Uint8List _requireSize(Uint8List bytes, int expected, String label) {
  if (bytes.length != expected) {
    throw FormatException(
      '$label must be $expected bytes, got ${bytes.length}',
    );
  }
  return copyBytes(bytes);
}

int _bytesHash(Uint8List bytes) {
  var hash = 17;
  for (final b in bytes) {
    hash = 31 * hash + b;
  }
  return hash;
}
