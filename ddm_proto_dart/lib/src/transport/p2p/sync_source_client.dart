part of '../p2p.dart';

final class _P2pSyncSourceClient implements SyncSource {
  _P2pSyncSourceClient({required this.id, required this.backend});

  @override
  final String id;
  final DartLibp2pHostBackend backend;
  bool _stopped = false;

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree |
            syncSourceFlagSupportPeerExchange |
            syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async {
    _ensureOpen();
    final response = await backend.request(
      id,
      const RpcRequest(
        method: rpcMethodGetConfigs,
        syncBlobIds: null,
        nodeId: null,
      ),
    );
    final configs = response.configs ?? const <Object?>[];
    try {
      return configs.map(_configRecordFromWire).toList(growable: false);
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
  }

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    _ensureOpen();
    final response = await backend.request(
      id,
      const RpcRequest(
        method: rpcMethodGetRoot,
        syncBlobIds: null,
        nodeId: null,
      ),
    );
    final wire = response.node;
    if (wire == null) {
      return null;
    }
    try {
      return _messageIndexNodeFromWire(wire);
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    _ensureOpen();
    final response = await backend.request(
      this.id,
      RpcRequest(
        method: rpcMethodGetNode,
        syncBlobIds: null,
        nodeId: id.toBytes(),
      ),
    );
    final wire = response.node;
    if (wire == null) {
      return null;
    }
    MessageIndexNode node;
    try {
      node = _messageIndexNodeFromWire(wire);
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
    final got = node.hash();
    if (got != id) {
      throw SyncSourceException.invalidResponse(
        'node hash mismatch, expected ${id.toHex()} got ${got.toHex()}',
      );
    }
    return node;
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    _ensureOpen();
    if (ids.isEmpty) {
      return const <SyncBlob?>[];
    }
    final response = await backend.request(
      id,
      RpcRequest(
        method: rpcMethodGetSyncBlobs,
        syncBlobIds: ids.map((id) => id.toBytes()).toList(growable: false),
        nodeId: null,
      ),
    );
    final rawBlobs = response.blobs ?? const <Object?>[];
    if (rawBlobs.length != ids.length) {
      throw SyncSourceException.invalidResponse(
        'lookup results count mismatch: got ${rawBlobs.length}, want ${ids.length}',
      );
    }

    final out = <SyncBlob?>[];
    for (var i = 0; i < rawBlobs.length; i++) {
      final item = rawBlobs[i];
      if (item is! List<Object?> || item.length != 2) {
        throw const SyncSourceException.invalidResponse('decode lookup result');
      }
      final rawId = item[0];
      final rawPayload = item[1];
      if (rawId is! Uint8List ||
          (rawPayload != null && rawPayload is! Uint8List)) {
        throw const SyncSourceException.invalidResponse('decode lookup result');
      }
      final payload = rawPayload as Uint8List?;
      final gotId = SyncBlobId(rawId);
      if (gotId != ids[i]) {
        throw SyncSourceException.invalidResponse(
          'lookup result id mismatch at index $i',
        );
      }
      if (payload == null) {
        out.add(null);
        continue;
      }
      if (payload.length > maxSyncBlobLookupPayloadBytes) {
        throw const SyncSourceException.invalidResponse(
          'lookup payload exceeds maximum supported size',
        );
      }
      out.add(SyncBlob(id: gotId, payload: Uint8List.fromList(payload)));
    }
    return out;
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    _ensureOpen();
    await backend.request(
      id,
      RpcRequest(
        method: rpcMethodPushBlob,
        syncBlobIds: null,
        nodeId: null,
        blobId: blob.id.toBytes(),
        blob: Uint8List.fromList(blob.payload),
      ),
    );
  }

  @override
  Future<List<String>> discoverPeers() async {
    _ensureOpen();
    final response = await backend.request(
      id,
      const RpcRequest(
        method: rpcMethodGetDiscoveryPeers,
        syncBlobIds: null,
        nodeId: null,
      ),
    );
    final peers = response.peers ?? const <Object?>[];
    return peers.map((peer) {
      if (peer is! String) {
        throw const FormatException('decode discovery peer');
      }
      return peer;
    }).toList(growable: false);
  }

  @override
  void stop() {
    _stopped = true;
  }

  void _ensureOpen() {
    if (_stopped) {
      throw StateError('p2p sync source is stopped');
    }
  }
}
