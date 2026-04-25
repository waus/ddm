import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';

final class RpcRequest {
  const RpcRequest({
    required this.method,
    required this.syncBlobIds,
    required this.nodeId,
    this.blobId,
    this.blob,
  });

  final int method;
  final List<Uint8List>? syncBlobIds;
  final Uint8List? nodeId;
  final Uint8List? blobId;
  final Uint8List? blob;

  Uint8List toBytes() {
    return ddmCborCodec.encode(<Object?>[
      method,
      syncBlobIds
          ?.map<Uint8List>((v) => Uint8List.fromList(v))
          .toList(growable: false),
      nodeId == null ? null : Uint8List.fromList(nodeId!),
      blobId == null ? null : Uint8List.fromList(blobId!),
      blob == null ? null : Uint8List.fromList(blob!),
    ]);
  }

  static RpcRequest fromBytes(Uint8List payload) {
    final decoded = ddmCborCodec.decode(payload);
    if (decoded is! List<Object?> ||
        (decoded.length != 3 && decoded.length != 5)) {
      throw const FormatException('decode rpc request');
    }

    final method = decoded[0];
    final ids = decoded[1];
    final nodeId = decoded[2];
    final blobId = decoded.length == 5 ? decoded[3] : null;
    final blob = decoded.length == 5 ? decoded[4] : null;
    if (method is! int || (ids != null && ids is! List<Object?>)) {
      throw const FormatException('decode rpc request');
    }

    List<Uint8List>? outIds;
    if (ids is List<Object?>) {
      outIds = <Uint8List>[];
      for (final item in ids) {
        if (item is! Uint8List) {
          throw const FormatException('decode rpc request ids');
        }
        outIds.add(Uint8List.fromList(item));
      }
    }

    if (nodeId != null && nodeId is! Uint8List) {
      throw const FormatException('decode rpc request node id');
    }
    if (blobId != null && blobId is! Uint8List) {
      throw const FormatException('decode rpc request blob id');
    }
    if (blob != null && blob is! Uint8List) {
      throw const FormatException('decode rpc request blob');
    }

    return RpcRequest(
      method: method,
      syncBlobIds: outIds,
      nodeId: nodeId as Uint8List?,
      blobId: blobId as Uint8List?,
      blob: blob as Uint8List?,
    );
  }
}

final class RpcResponse {
  const RpcResponse({
    required this.status,
    required this.error,
    required this.peers,
    required this.configs,
    required this.blobs,
    required this.node,
  });

  final int status;
  final String error;
  final List<Object?>? peers;
  final List<Object?>? configs;
  final List<Object?>? blobs;
  final Object? node;

  Uint8List toBytes() {
    return ddmCborCodec.encode(<Object?>[
      status,
      error,
      peers,
      configs,
      blobs,
      node,
    ]);
  }

  static RpcResponse fromBytes(Uint8List payload) {
    final decoded = ddmCborCodec.decode(payload);
    if (decoded is! List<Object?> || decoded.length != 6) {
      throw const FormatException('decode rpc response');
    }
    final status = decoded[0];
    final error = decoded[1];
    final peers = decoded[2];
    final configs = decoded[3];
    final blobs = decoded[4];
    final node = decoded[5];
    if (status is! int ||
        error is! String ||
        (peers != null && peers is! List<Object?>) ||
        (configs != null && configs is! List<Object?>) ||
        (blobs != null && blobs is! List<Object?>)) {
      throw const FormatException('decode rpc response');
    }
    return RpcResponse(
      status: status,
      error: error,
      peers: peers as List<Object?>?,
      configs: configs as List<Object?>?,
      blobs: blobs as List<Object?>?,
      node: node,
    );
  }
}

Uint8List encodeRpcFrame(Uint8List payload, {required int maxBytes}) {
  if (payload.isEmpty) {
    throw const FormatException('rpc frame must not be empty');
  }
  if (payload.length > maxBytes) {
    throw FormatException(
      'rpc frame exceeds limit: got ${payload.length} bytes, max $maxBytes',
    );
  }
  final out = Uint8List(4 + payload.length);
  out[0] = (payload.length >> 24) & 0xff;
  out[1] = (payload.length >> 16) & 0xff;
  out[2] = (payload.length >> 8) & 0xff;
  out[3] = payload.length & 0xff;
  out.setRange(4, out.length, payload);
  return out;
}

Uint8List decodeRpcFrame(Uint8List frameBytes, {required int maxBytes}) {
  if (frameBytes.length < 5) {
    throw const FormatException('rpc frame must not be empty');
  }
  final size = (frameBytes[0] << 24) |
      (frameBytes[1] << 16) |
      (frameBytes[2] << 8) |
      frameBytes[3];
  if (size == 0) {
    throw const FormatException('rpc frame must not be empty');
  }
  if (size > maxBytes) {
    throw FormatException(
      'rpc frame exceeds limit: got $size bytes, max $maxBytes',
    );
  }
  if (frameBytes.length != 4 + size) {
    throw const FormatException('rpc frame size mismatch');
  }
  return Uint8List.sublistView(frameBytes, 4);
}
