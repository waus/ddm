part of '../p2p.dart';

final class P2pSyncTransportServer
    implements SyncTransportServer, SyncTransport, SyncPeerDiscovery {
  P2pSyncTransportServer({
    required P2pIdentityLoader loadIdentity,
    SyncSource? source,
    P2pHostBackend? backend,
    String rawListenAddrs = '',
    this.publicRelay = false,
    P2pDiscoveryPeerPool? discoveryPool,
  })  : _loadIdentity = loadIdentity,
        _configuredSource = source,
        _backend = backend ?? DartLibp2pHostBackend(),
        listenAddrs = normalizeP2pListenAddrs(
          rawListenAddrs.isEmpty ? const <String>[] : <String>[rawListenAddrs],
        ),
        discoveryPool = discoveryPool ??
            P2pDiscoveryPeerPool(capacity: discoveryPeerPoolCapacity);

  final P2pIdentityLoader _loadIdentity;
  final P2pHostBackend _backend;
  final bool publicRelay;
  final List<String> listenAddrs;
  final P2pDiscoveryPeerPool discoveryPool;
  SyncSource? _configuredSource;
  Uint8List? _privateKey;
  Future<void>? _starting;
  bool _running = false;

  Uint8List? get loadedPrivateKey {
    final key = _privateKey;
    return key == null ? null : Uint8List.fromList(key);
  }

  @override
  String get protocolName => p2pTransportProtocolName;

  @override
  Future<void> start(SyncSource source) async {
    if (_running) {
      return;
    }
    final starting = _starting;
    if (starting != null) {
      await starting;
      return;
    }
    final started = _start(source);
    _starting = started;
    try {
      await started;
    } finally {
      _starting = null;
    }
  }

  Future<void> _start(SyncSource source) async {
    if (_running) {
      return;
    }
    _configuredSource = source;
    final privateKey = await _loadIdentity();
    if (privateKey.isEmpty) {
      throw const FormatException('p2p private key must not be empty');
    }
    _privateKey = Uint8List.fromList(privateKey);
    await _backend.start(
      privateKey: Uint8List.fromList(privateKey),
      source: source,
      listenAddrs: listenAddrs,
      publicRelay: publicRelay,
      discoveryPool: discoveryPool,
    );
    _running = true;
  }

  @override
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    await _backend.stop();
    discoveryPool.reset();
  }

  @override
  bool peerMatch(String id) => isP2pPeerId(id);

  @override
  Future<SyncSource> createPeerSource(String id) async {
    normalizeP2pSyncSourceUpstream(id);
    await _ensureRunning();
    return _backend.createPeerSource(id);
  }

  @override
  Future<List<String>> discoverPeers() async {
    await _ensureRunning();
    return _backend.discoverPeers();
  }

  Future<void> _ensureRunning() async {
    if (_running) {
      return;
    }
    final starting = _starting;
    if (starting != null) {
      await starting;
      return;
    }
    final source = _configuredSource;
    if (source == null) {
      throw StateError('p2p server source is not configured');
    }
    await start(source);
  }
}
