part of '../runtime.dart';

final class RuntimeTransportService {
  RuntimeTransportService({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    required SyncSource localSource,
    required P2pIdentityLoader loadP2pIdentity,
    P2pHostBackend? p2pBackend,
    String p2pListenAddrs = randomP2pListenAddr,
    bool p2pPublicRelay = false,
  })  : _storage = storage,
        _localSource = localSource,
        sources = SourceRegistry(storage: storage, nowUtc: nowUtc) {
    final p2p = P2pSyncTransportServer(
      loadIdentity: loadP2pIdentity,
      source: _localSource,
      backend: p2pBackend,
      rawListenAddrs: p2pListenAddrs,
      publicRelay: p2pPublicRelay,
    );
    _transports.addAll([
      const HttpSyncTransport(),
      FileSyncTransport(nowUtc: nowUtc),
      p2p,
    ]);
    _servers.add(p2p);
  }

  final DdmSqliteStorage _storage;
  final SyncSource _localSource;
  final SourceRegistry sources;
  final List<SyncTransport> _transports = <SyncTransport>[];
  final List<SyncTransportServer> _servers = <SyncTransportServer>[];
  bool _discoveryServersStarted = false;
  bool _closed = false;

  List<String> registeredSourceProtocols() {
    return _transports
        .map((server) => server.protocolName)
        .toSet()
        .toList(growable: false)
      ..sort();
  }

  List<String> sourceIds() => sources.sourceIds();

  Future<HttpSyncSourceServer> startHttpServer({
    required String listenAddress,
  }) async {
    final server = HttpSyncSourceServer(listenAddress: listenAddress);
    await addServer(server);
    return server;
  }

  Future<void> addServer(SyncTransportServer server) async {
    _ensureOpen();
    final protocolName = server.protocolName.trim();
    if (protocolName.isEmpty) {
      throw const FormatException(
          'sync server protocol name must not be empty');
    }
    await server.start(_localSource);
    _servers.add(server);
  }

  Future<void> registerTransport(SyncTransport transport) async {
    _ensureOpen();
    if (transport.protocolName.trim().isEmpty) {
      throw const FormatException(
          'sync transport protocol name must not be empty');
    }
    await _restoreStoredPeerSources(transport);
    _transports.add(transport);
  }

  Future<void> addSource(String raw) async {
    _ensureOpen();
    final id = raw.trim();
    if (id.isEmpty) {
      throw const FormatException('sync source upstream must not be empty');
    }
    final transport = _matchTransport(id);
    if (transport == null) {
      throw FormatException('unsupported sync source upstream: $id');
    }
    final source = await transport.createPeerSource(id);
    if (!sources.add(source)) {
      source.stop();
    }
  }

  Future<List<String>> discoverPeers() async {
    _ensureOpen();
    final out = <String>[];
    for (final transport in _transports.whereType<SyncPeerDiscovery>()) {
      out.addAll(await transport.discoverPeers());
    }
    return out;
  }

  Future<void> restoreRegisteredSources() async {
    _ensureOpen();
    unawaited(
      _startDiscoveryServers().catchError((Object _) {
        _discoveryServersStarted = false;
      }),
    );
    for (final transport in _transports) {
      await _restoreStoredPeerSources(transport);
    }
    await _addDefaultPeerExchangeSources();
  }

  Future<void> stopServers() async {
    final servers = List<SyncTransportServer>.from(_servers);
    // Outgoing P2P sources can restart their shared host after it stops.
    _discoveryServersStarted = false;
    for (final server in servers) {
      await server.stop();
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    final servers = List<SyncTransportServer>.from(_servers);
    _servers.clear();
    for (final server in servers) {
      unawaited(server.stop());
    }
    sources.close();
  }

  Future<void> _restoreStoredPeerSources(SyncTransport transport) async {
    for (final peer in _storage.peers.listPeers()) {
      if (!transport.peerMatch(peer.id)) {
        continue;
      }
      SyncSource source;
      try {
        source = await transport.createPeerSource(peer.id);
      } catch (_) {
        continue;
      }
      if (!sources.addStored(source, peer)) {
        source.stop();
      }
    }
  }

  Future<void> _addDefaultPeerExchangeSources() async {
    final existing = sources.sourceIds().toSet();
    for (final addr in defaultPeerExchangeAddrs) {
      if (existing.contains(addr)) {
        continue;
      }
      await addSource(addr);
      existing.add(addr);
    }
  }

  Future<void> _startDiscoveryServers() async {
    if (_discoveryServersStarted) {
      return;
    }
    _discoveryServersStarted = true;
    try {
      for (final server in _transports.whereType<SyncTransportServer>()) {
        await server.start(_localSource);
      }
    } catch (_) {
      _discoveryServersStarted = false;
      rethrow;
    }
  }

  SyncTransport? _matchTransport(String id) {
    for (final transport in _transports) {
      if (transport.peerMatch(id)) {
        return transport;
      }
    }
    return null;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('runtime transport service is closed');
    }
  }
}
