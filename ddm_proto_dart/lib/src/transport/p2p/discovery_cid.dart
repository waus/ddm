part of '../p2p.dart';

CID _discoveryCid() {
  return CID.fromData(
    CID.V1,
    'raw',
    Uint8List.fromList(utf8.encode(p2pDiscoveryKey)),
  );
}
