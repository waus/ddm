import 'package:ddm_proto_dart/src/sync/sync.dart';

abstract interface class SyncTransport {
  String get protocolName;

  bool peerMatch(String id);

  Future<SyncSource> createPeerSource(String id);
}

abstract interface class SyncPeerDiscovery {
  Future<List<String>> discoverPeers();
}

abstract interface class SyncTransportServer {
  String get protocolName;

  Future<void> start(SyncSource source);

  Future<void> stop();
}
