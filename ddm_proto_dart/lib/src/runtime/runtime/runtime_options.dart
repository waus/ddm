import 'dart:async';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/transport/constants.dart';
import 'package:ddm_proto_dart/src/transport/p2p.dart';

typedef RandomBytes = Uint8List Function(int length);
typedef DurationJitterDraw = Duration Function(Duration max);
typedef P2pPrivateKeyGenerator = FutureOr<Uint8List> Function();

final class RuntimeP2pOptions {
  const RuntimeP2pOptions({
    this.backend,
    this.listenAddrs = randomP2pListenAddr,
    this.publicRelay = false,
  });

  final P2pHostBackend? backend;
  final String listenAddrs;
  final bool publicRelay;
}

final class RuntimeTransportOptions {
  const RuntimeTransportOptions({
    this.backgroundSyncEnabled = true,
    this.backgroundSyncInterval = const Duration(seconds: 5),
    this.discoveryInterval = const Duration(seconds: 10),
    this.peerExchangeInterval = const Duration(minutes: 1),
  });

  final bool backgroundSyncEnabled;
  final Duration backgroundSyncInterval;
  final Duration discoveryInterval;
  final Duration peerExchangeInterval;
}
