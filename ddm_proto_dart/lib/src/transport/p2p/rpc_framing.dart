part of '../p2p.dart';

Future<void> _writeRpcFrame(
  p2p_stream.P2PStream stream,
  Uint8List payload,
) async {
  await stream.setWriteDeadline(
    DateTime.now().toUtc().add(syncSourceRpcWriteDeadline),
  );
  await stream.write(
    encodeRpcFrame(payload, maxBytes: maxSyncSourceRpcFrameBytes),
  );
}

Future<Uint8List> _readRpcFrame(p2p_stream.P2PStream stream) async {
  await stream.setReadDeadline(
    DateTime.now().toUtc().add(syncSourceRpcReadDeadline),
  );
  final header = await _readExact(stream, 4);
  final size =
      (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
  if (size == 0) {
    throw const FormatException('rpc frame must not be empty');
  }
  if (size > maxSyncSourceRpcFrameBytes) {
    throw FormatException(
      'rpc frame exceeds limit: got $size bytes, max $maxSyncSourceRpcFrameBytes',
    );
  }
  return _readExact(stream, size);
}

Future<Uint8List> _readExact(p2p_stream.P2PStream stream, int length) async {
  final out = BytesBuilder(copy: false);
  while (out.length < length) {
    final remaining = length - out.length;
    final chunk = await stream.read(remaining);
    if (chunk.isEmpty) {
      throw const FormatException('rpc frame ended early');
    }
    if (chunk.length > remaining) {
      out.add(Uint8List.sublistView(chunk, 0, remaining));
    } else {
      out.add(chunk);
    }
  }
  return out.takeBytes();
}

void _throwIfRpcError(RpcResponse response) {
  switch (response.status) {
    case rpcStatusOk:
      return;
    case rpcStatusUnavailable:
      throw const SyncSourceException.unavailable(
        'p2p sync source unavailable',
      );
    case rpcStatusBadRequest:
    case rpcStatusInternal:
      throw SyncSourceException.requestFailed(
        response.error.isEmpty ? 'status ${response.status}' : response.error,
      );
    default:
      throw SyncSourceException.requestFailed(
        'unsupported status ${response.status}',
      );
  }
}

String _rpcMethodName(int method) {
  switch (method) {
    case rpcMethodGetConfigs:
      return 'get_configs';
    case rpcMethodGetSyncBlobs:
      return 'get_sync_blobs';
    case rpcMethodGetRoot:
      return 'get_root';
    case rpcMethodGetNode:
      return 'get_node';
    case rpcMethodGetDiscoveryPeers:
      return 'get_discovery_peers';
    case rpcMethodPushBlob:
      return 'push_blob';
    default:
      return 'unknown_$method';
  }
}

String _connectionDirectionLabel(p2p_common.Direction direction) {
  switch (direction) {
    case p2p_common.Direction.inbound:
      return 'inbound';
    case p2p_common.Direction.outbound:
      return 'outbound';
    case p2p_common.Direction.unknown:
      return 'unknown';
  }
}

void _p2pDebug(String message) {
  if (_isProductBuild) {
    return;
  }
  stderr.writeln('${DateTime.now().toIso8601String()} [ddm:p2p] $message');
}

void _p2pRpcDebug(String message) {
  if (!_verboseP2pRpcLogs) {
    return;
  }
  _p2pDebug(message);
}

const bool _verboseP2pRpcLogs = bool.fromEnvironment(
  'DDM_VERBOSE_P2P_RPC_LOGS',
);

const bool _isProductBuild = bool.fromEnvironment('dart.vm.product');
