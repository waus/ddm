import 'dart:async';

import 'package:ddm_proto_dart/src/sync/sync.dart';

final class ServerFlags {
  const ServerFlags(this.value);

  final int value;

  bool has(int flag) => value & flag == flag;
}

const int serverFlagNone = 0;
const int serverFlagDiscovery = 1 << 0;

abstract interface class SyncTransportServer {
  String get protocolName;

  ServerFlags get flags;

  Future<void> start(SyncSource source);

  Future<void> stop();

  bool peerMatch(String id);

  Future<SyncSource> createPeerSource(String id);

  Future<List<String>> discoverPeers();
}

final class SyncTransportServerRegistry {
  SyncTransportServerRegistry(Iterable<SyncTransportServer> servers) {
    for (final server in servers) {
      _servers.add(server);
    }
  }

  final List<SyncTransportServer> _servers = <SyncTransportServer>[];

  Future<SyncSource?> createPeerSource(String id) async {
    for (final server in _servers) {
      if (server.peerMatch(id)) {
        return server.createPeerSource(id);
      }
    }
    return null;
  }

  Future<List<String>> discoverPeers() async {
    final out = <String>[];
    for (final server in _servers) {
      if (!server.flags.has(serverFlagDiscovery)) {
        continue;
      }
      out.addAll(await server.discoverPeers());
    }
    return out;
  }

  Future<void> stop() async {
    for (final server in _servers) {
      await server.stop();
    }
  }
}

typedef SyncSourceFactory = FutureOr<SyncSource> Function(String id);

final class ProtocolSyncTransportServer implements SyncTransportServer {
  ProtocolSyncTransportServer({
    required this.protocolName,
    required bool Function(String id) peerMatch,
    required SyncSourceFactory createPeerSource,
    FutureOr<List<String>> Function()? discoverPeers,
    this.flags = const ServerFlags(serverFlagNone),
  })  : _peerMatch = peerMatch,
        _createPeerSource = createPeerSource,
        _discoverPeers = discoverPeers;

  @override
  final String protocolName;

  @override
  final ServerFlags flags;

  final bool Function(String id) _peerMatch;
  final SyncSourceFactory _createPeerSource;
  final FutureOr<List<String>> Function()? _discoverPeers;

  @override
  Future<void> start(SyncSource source) async {}

  @override
  Future<void> stop() async {}

  @override
  bool peerMatch(String id) => _peerMatch(id);

  @override
  Future<SyncSource> createPeerSource(String id) async {
    return _createPeerSource(id);
  }

  @override
  Future<List<String>> discoverPeers() async {
    return await _discoverPeers?.call() ?? const <String>[];
  }
}
