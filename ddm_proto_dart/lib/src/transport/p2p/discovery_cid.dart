part of '../p2p.dart';

CID _discoveryCid([String namespace = p2pDiscoveryKey]) {
  return CID.fromData(
    CID.V1,
    'raw',
    Uint8List.fromList(utf8.encode(namespace)),
  );
}

String _shardKey(String prefix) => bytesToHex(sha256Bytes(
    Uint8List.fromList(utf8.encode('$shardDiscoveryNamespace$prefix'))));
