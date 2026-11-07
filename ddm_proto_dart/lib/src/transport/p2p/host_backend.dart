part of '../p2p.dart';

typedef P2pIdentityLoader = FutureOr<Uint8List> Function();

abstract interface class P2pHostBackend {
  Future<void> start({
    required Uint8List privateKey,
    required SyncSource source,
    required List<String> listenAddrs,
    required bool publicRelay,
    required P2pDiscoveryPeerPool discoveryPool,
  });

  Future<void> stop();

  Future<SyncSource> createPeerSource(String id);

  Future<List<String>> discoverPeers();
}

final class DartLibp2pHostBackend implements P2pHostBackend, ShardDiscovery {
  DartLibp2pHostBackend({
    List<String>? bootstrapAddrs,
  }) : bootstrapAddrs = List<String>.from(
          bootstrapAddrs ?? defaultP2pBootstrapAddrs,
        );

  final List<String> bootstrapAddrs;

  p2p.Host? _host;
  p2p_dht.IpfsDHT? _dht;
  SyncSource? _source;
  P2pDiscoveryPeerPool? _discoveryPool;
  DateTime? _lastDhtAdvertiseAt;
  Timer? _fastDiscoveryTimer;
  Timer? _slowDiscoveryTimer;
  Timer? _advertiseTimer;
  bool _discoveryRefreshRunning = false;
  bool _dhtAdvertiseRunning = false;

  List<String> get serverAddrs {
    final host = _host;
    if (host == null) {
      return const <String>[];
    }
    final addrs =
        host.addrs.isEmpty ? host.network.listenAddresses : host.addrs;
    return addrs
        .map((addr) => peerAddrWithId(host.id.toString(), addr.toString()))
        .toList(growable: false)
      ..sort();
  }

  @override
  Future<void> start({
    required Uint8List privateKey,
    required SyncSource source,
    required List<String> listenAddrs,
    required bool publicRelay,
    required P2pDiscoveryPeerPool discoveryPool,
  }) async {
    if (_host != null) {
      throw StateError('libp2p host is already running');
    }
    _p2pDebug(
      'host start requested listen_addrs=${listenAddrs.join(',')} '
      'public_relay=$publicRelay bootstrap_addrs=${bootstrapAddrs.length}',
    );
    final keyPair = await p2pKeyPairFromPrivateKey(privateKey);
    _p2pDebug('host identity loaded');
    final connectionManager = p2p_connection.ConnectionManager();
    final resourceManager = p2p_resource.ResourceManagerImpl(
      limiter: p2p_limiter.FixedLimiter(),
    );
    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connectionManager),
      p2p_config.Libp2p.transport(
        p2p_tcp.TCPTransport(
          resourceManager: resourceManager,
          connManager: connectionManager,
        ),
      ),
      p2p_config.Libp2p.security(await p2p_noise.NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.listenAddrs(
        listenAddrs.map(p2p_multiaddr.MultiAddr.new).toList(growable: false),
      ),
      p2p_config.Libp2p.addrsFactory((addrs) => List.from(addrs)),
      p2p_config.Libp2p.ping(true),
      p2p_config.Libp2p.relay(publicRelay),
      p2p_config.Libp2p.autoRelay(true),
      p2p_config.Libp2p.autoNAT(true),
      p2p_config.Libp2p.relayServers(bootstrapAddrs),
    ];

    _p2pDebug('creating libp2p host');
    final host = await p2p_config.Libp2p.new_(options);
    _p2pDebug('libp2p host created peer_id=${host.id}');
    host.network.notify(
      p2p_notifiee.NotifyBundle(
        listenF: (_, addr) => _p2pDebug('libp2p listen addr=$addr'),
        listenCloseF: (_, addr) => _p2pDebug('libp2p listen closed addr=$addr'),
        connectedF: (_, conn, {dialLatency}) {
          _p2pDebug(
            'libp2p connection opened direction=${_connectionDirectionLabel(conn.stat.stats.direction)} '
            'remote_peer=${conn.remotePeer} remote_addr=${conn.remoteMultiaddr} '
            'local_addr=${conn.localMultiaddr} dial_latency=${dialLatency ?? 'n/a'}',
          );
        },
        disconnectedF: (_, conn) {
          _p2pDebug(
            'libp2p connection closed direction=${_connectionDirectionLabel(conn.stat.stats.direction)} '
            'remote_peer=${conn.remotePeer} remote_addr=${conn.remoteMultiaddr}',
          );
        },
      ),
    );
    host.setStreamHandler(p2pRpcProtocolId, _handleStream);
    _host = host;
    _source = source;
    _discoveryPool = discoveryPool;
    try {
      await _startDht(host);
      _p2pDebug('starting libp2p host peer_id=${host.id}');
      await host.start();
      _p2pDebug(
        'libp2p host started peer_id=${host.id} '
        'listen=${host.network.listenAddresses.join(',')} '
        'addrs=${host.addrs.join(',')} server_addrs=${serverAddrs.join(',')}',
      );
      await _startDhtNetworking(host);
    } catch (error) {
      final dht = _dht;
      _host = null;
      _dht = null;
      _source = null;
      _discoveryPool = null;
      _p2pDebug(
          'libp2p host start failed, closing peer_id=${host.id} error=$error');
      if (dht != null) {
        await dht.close();
      }
      await host.close();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final host = _host;
    final dht = _dht;
    _host = null;
    _dht = null;
    _source = null;
    _discoveryPool = null;
    _lastDhtAdvertiseAt = null;
    _stopDiscoveryManager();
    if (dht != null) {
      try {
        _p2pDebug('stopping libp2p dht');
        await dht.close();
        _p2pDebug('libp2p dht stopped');
      } catch (error) {
        _p2pDebug('libp2p dht stop failed error=$error');
      }
    }
    if (host != null) {
      _p2pDebug('stopping libp2p host peer_id=${host.id}');
      await host.close();
      _p2pDebug('libp2p host stopped peer_id=${host.id}');
    }
  }

  @override
  Future<SyncSource> createPeerSource(String id) async {
    final normalized = normalizeP2pSyncSourceUpstream(id);
    _p2pDebug('create peer source id=$id');
    await _seedDhtPeer(normalized);
    return _P2pSyncSourceClient(id: normalized, backend: this);
  }

  @override
  Future<List<String>> discoverPeers() async {
    final peers = _discoveryPool?.addresses() ?? const <String>[];
    if (peers.isNotEmpty) {
      _p2pRpcDebug('discover peers exported count=${peers.length}');
    }
    return peers;
  }

  Future<void> _startDht(p2p.Host host) async {
    final dhtBootstrapAddrs = _dhtBootstrapMultiaddrs();
    _p2pDebug(
      'libp2p dht starting before host bootstrap_addrs=${dhtBootstrapAddrs.length} '
      'discovery_key=$p2pDiscoveryKey',
    );
    final dht = p2p_dht.IpfsDHTv2(
      host: host,
      providerStore: p2p_dht.MemoryProviderStore(),
      options: p2p_dht.DHTOptions(
        mode: p2p_dht.DHTMode.server,
        autoRefresh: false,
        bootstrapPeers: dhtBootstrapAddrs,
      ),
    );
    _dht = dht;
    await dht.start();
    _p2pDebug('libp2p dht started implementation=v2');
  }

  Future<void> _startDhtNetworking(p2p.Host host) async {
    final dht = _dht;
    if (dht == null) {
      throw StateError('libp2p dht is not started');
    }
    final dhtBootstrapAddrs = _dhtBootstrapMultiaddrs();
    await _seedDhtBootstrapPeers(host, dht, dhtBootstrapAddrs);
    unawaited(_probeDhtBootstrapPeers(host, dhtBootstrapAddrs));
    _startDiscoveryManager();
    unawaited(_advertiseDht());
  }

  Future<void> _seedDhtBootstrapPeers(
    p2p.Host host,
    p2p_dht.IpfsDHT dht,
    List<p2p_multiaddr.MultiAddr> addrs,
  ) async {
    var seeded = 0;
    var skipped = 0;
    for (final addr in addrs) {
      final rawPeerId = addr.peerId;
      final transportAddr = addr.decapsulate('p2p');
      if (rawPeerId == null || transportAddr == null) {
        skipped++;
        continue;
      }
      try {
        final peerId = p2p_peer.PeerId.fromString(rawPeerId);
        if (peerId == host.id) {
          skipped++;
          continue;
        }
        await host.peerStore.addrBook.addAddrs(
          peerId,
          <p2p_multiaddr.MultiAddr>[transportAddr],
          const Duration(hours: 24),
        );
        await dht.routingTable.tryAddPeer(peerId, queryPeer: false);
        seeded++;
      } catch (error) {
        skipped++;
        _p2pDebug(
            'libp2p dht bootstrap peer seed failed addr=$addr error=$error');
      }
    }
    _p2pDebug(
      'libp2p dht bootstrap peers seeded seeded=$seeded skipped=$skipped',
    );
  }

  Future<void> _probeDhtBootstrapPeers(
    p2p.Host host,
    List<p2p_multiaddr.MultiAddr> addrs,
  ) async {
    final probes = <Future<void>>[];
    var skipped = 0;
    for (final addr in addrs) {
      final rawPeerId = addr.peerId;
      final transportAddr = addr.decapsulate('p2p');
      if (rawPeerId == null || transportAddr == null) {
        skipped++;
        continue;
      }
      final peerId = p2p_peer.PeerId.fromString(rawPeerId);
      if (peerId == host.id) {
        skipped++;
        continue;
      }
      probes.add(_probeDhtBootstrapPeer(host, peerId, transportAddr));
    }
    _p2pDebug(
      'libp2p dht protocol probe started peers=${probes.length} '
      'skipped=$skipped protocol=${p2p_dht.AminoConstants.protocolID} '
      'timeout=$peerDiscoveryDhtProtocolProbeTimeout',
    );
    await Future.wait(probes);
    _p2pDebug('libp2p dht protocol probe completed peers=${probes.length}');
  }

  Future<void> _probeDhtBootstrapPeer(
    p2p.Host host,
    p2p_peer.PeerId peerId,
    p2p_multiaddr.MultiAddr addr,
  ) async {
    final startedAt = DateTime.now().toUtc();
    p2p_stream.P2PStream? stream;
    try {
      stream = await host
          .newStream(
            peerId,
            <String>[p2p_dht.AminoConstants.protocolID],
            p2p_context.Context(),
          )
          .timeout(peerDiscoveryDhtProtocolProbeTimeout);
      final elapsed = DateTime.now().toUtc().difference(startedAt);
      _p2pDebug(
        'libp2p dht protocol probe succeeded peer=$peerId addr=$addr '
        'protocol=${p2p_dht.AminoConstants.protocolID} elapsed=$elapsed',
      );
      await _probeDhtGetProviders(stream, peerId, addr);
    } catch (error) {
      final elapsed = DateTime.now().toUtc().difference(startedAt);
      _p2pDebug(
        'libp2p dht protocol probe failed peer=$peerId addr=$addr '
        'protocol=${p2p_dht.AminoConstants.protocolID} elapsed=$elapsed '
        'error=$error',
      );
    } finally {
      try {
        await stream?.close();
      } catch (error) {
        _p2pDebug(
          'libp2p dht protocol probe stream close failed peer=$peerId '
          'error=$error',
        );
      }
    }
  }

  Future<void> _probeDhtGetProviders(
    p2p_stream.P2PStream stream,
    p2p_peer.PeerId peerId,
    p2p_multiaddr.MultiAddr addr,
  ) async {
    final startedAt = DateTime.now().toUtc();
    try {
      final request = p2p_dht.Message(
        type: p2p_dht.MessageType.getProviders,
        key: _discoveryCid().multihash,
      );
      final payload = p2p_dht_codec.encodeMessage(request);
      await stream.write(payload).timeout(peerDiscoveryDhtProtocolProbeTimeout);
      final response = await _readDhtMessage(stream)
          .timeout(peerDiscoveryDhtProtocolProbeTimeout);
      final elapsed = DateTime.now().toUtc().difference(startedAt);
      _p2pDebug(
        'libp2p dht get_providers probe succeeded peer=$peerId addr=$addr '
        'type=${response.type.name} providers=${response.providerPeers.length} '
        'closer_peers=${response.closerPeers.length} elapsed=$elapsed '
        'provider_ids=${_dhtPeerIds(response.providerPeers).join(',')} '
        'closer_ids=${_dhtPeerIds(response.closerPeers).join(',')}',
      );
    } catch (error) {
      final elapsed = DateTime.now().toUtc().difference(startedAt);
      _p2pDebug(
        'libp2p dht get_providers probe failed peer=$peerId addr=$addr '
        'elapsed=$elapsed error=$error',
      );
    }
  }

  List<String> _dhtPeerIds(List<p2p_dht.Peer> peers) {
    return peers.map((peer) {
      try {
        return p2p_peer.PeerId.fromBytes(peer.id).toString();
      } catch (_) {
        return 'invalid(${peer.id.length}b)';
      }
    }).toList(growable: false);
  }

  Future<p2p_dht.Message> _readDhtMessage(
    p2p_stream.P2PStream stream,
  ) async {
    final prefix = <int>[];
    var length = 0;
    var shift = 0;
    while (true) {
      final chunk = await stream.read(1);
      if (chunk.isEmpty) {
        throw const FormatException('DHT stream closed before frame length');
      }
      final byte = chunk[0];
      prefix.add(byte);
      length |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        break;
      }
      shift += 7;
      if (shift > 28) {
        throw const FormatException('DHT frame length varint is too long');
      }
    }
    final payload = await _readExact(stream, length);
    final framed = Uint8List(prefix.length + payload.length);
    framed.setRange(0, prefix.length, prefix);
    framed.setRange(prefix.length, framed.length, payload);
    return p2p_dht_codec.decodeMessage(framed);
  }

  p2p_addr.AddrInfo? _dhtAddrInfoFromMultiaddr(
    p2p_multiaddr.MultiAddr addr,
  ) {
    final rawPeerId = addr.peerId;
    final transportAddr = addr.decapsulate('p2p');
    if (rawPeerId == null || transportAddr == null) {
      return null;
    }
    try {
      return p2p_addr.AddrInfo(
        p2p_peer.PeerId.fromString(rawPeerId),
        <p2p_multiaddr.MultiAddr>[transportAddr],
      );
    } catch (_) {
      return null;
    }
  }

  p2p_addr.AddrInfo? _dhtAddrInfoFromPeer(p2p_dht.Peer peer) {
    try {
      final peerId = p2p_peer.PeerId.fromBytes(peer.id);
      final addrs = peer.addrs
          .map((addr) => p2p_multiaddr.MultiAddr.fromBytes(addr))
          .toList(growable: false);
      return p2p_addr.AddrInfo(peerId, addrs);
    } catch (_) {
      return null;
    }
  }

  Future<p2p_addr.AddrInfo?> _resolveDhtProviderInfo(
    p2p.Host host,
    p2p_dht.Peer provider,
  ) async {
    final info = _dhtAddrInfoFromPeer(provider);
    if (info == null || info.id == host.id) {
      return null;
    }
    final addrs = <p2p_multiaddr.MultiAddr>[...info.addrs];
    try {
      final peerstoreInfo = await host.peerStore.getPeer(info.id);
      if (peerstoreInfo != null) {
        addrs.addAll(peerstoreInfo.addrs);
      }
    } catch (_) {}
    addrs.addAll(_bootstrapAddrsForPeer(info.id));
    return p2p_addr.AddrInfo(info.id, mergeUniqueMultiaddrs(addrs));
  }

  List<p2p_multiaddr.MultiAddr> _bootstrapAddrsForPeer(
    p2p_peer.PeerId peerId,
  ) {
    final out = <p2p_multiaddr.MultiAddr>[];
    for (final addr in _dhtBootstrapMultiaddrs()) {
      if (addr.peerId != peerId.toString()) {
        continue;
      }
      final transportAddr = addr.decapsulate('p2p');
      if (transportAddr != null) {
        out.add(transportAddr);
      }
    }
    return out;
  }

  List<p2p_multiaddr.MultiAddr> mergeUniqueMultiaddrs(
    Iterable<p2p_multiaddr.MultiAddr> addrs,
  ) {
    final seen = <String>{};
    final out = <p2p_multiaddr.MultiAddr>[];
    for (final addr in addrs) {
      if (seen.add(addr.toString())) {
        out.add(addr);
      }
    }
    return out;
  }

  List<p2p_multiaddr.MultiAddr> _dhtBootstrapMultiaddrs() {
    final out = <p2p_multiaddr.MultiAddr>[];
    for (final raw in bootstrapAddrs) {
      try {
        out.add(p2p_multiaddr.MultiAddr(raw));
      } catch (error) {
        _p2pDebug('libp2p dht bootstrap addr skipped addr=$raw error=$error');
      }
    }
    return out;
  }

  void _startDiscoveryManager() {
    _stopDiscoveryManager();
    unawaited(_refreshDhtDiscovery());
    _fastDiscoveryTimer = Timer.periodic(peerDiscoveryFastPollInterval, (_) {
      final pool = _discoveryPool;
      if (pool != null && pool.alive(DateTime.now().toUtc()) > 0) {
        return;
      }
      unawaited(_refreshDhtDiscovery());
    });
    _slowDiscoveryTimer = Timer.periodic(peerDiscoverySlowPollInterval, (_) {
      final pool = _discoveryPool;
      if (pool == null || pool.size == 0) {
        return;
      }
      unawaited(_refreshDhtDiscovery());
    });
    _advertiseTimer = Timer.periodic(peerDiscoveryAdvertiseRetryInterval, (_) {
      unawaited(_advertiseDht());
    });
  }

  void _stopDiscoveryManager() {
    _fastDiscoveryTimer?.cancel();
    _slowDiscoveryTimer?.cancel();
    _advertiseTimer?.cancel();
    _fastDiscoveryTimer = null;
    _slowDiscoveryTimer = null;
    _advertiseTimer = null;
    _discoveryRefreshRunning = false;
    _dhtAdvertiseRunning = false;
  }

  Future<void> _refreshDhtDiscovery() async {
    if (_discoveryRefreshRunning) {
      return;
    }
    final dht = _dht;
    final pool = _discoveryPool;
    if (dht == null || pool == null) {
      _p2pDebug('libp2p dht discovery skipped: host_not_running');
      return;
    }
    _discoveryRefreshRunning = true;
    await _advertiseDhtIfStale();
    final startedAt = DateTime.now().toUtc();
    final deadline = startedAt.add(peerDiscoveryDhtLookupBudget);
    var rounds = 0;
    var totalCount = 0;
    try {
      _p2pDebug(
        'libp2p dht discovery started key=$p2pDiscoveryKey '
        'budget=$peerDiscoveryDhtLookupBudget '
        'max_rounds=$peerDiscoveryDhtLookupMaxRounds',
      );
      while (rounds < peerDiscoveryDhtLookupMaxRounds &&
          DateTime.now().toUtc().isBefore(deadline)) {
        rounds++;
        final roundStartedAt = DateTime.now().toUtc();
        final providers = await _findDhtProviders(deadline);
        var roundCount = 0;
        for (final peer in providers) {
          if (peer.id == _host?.id) {
            continue;
          }
          final addrs = peer.addrs.map((addr) => addr.toString()).toList();
          if (addrs.isEmpty) {
            continue;
          }
          final filtered = filterDiscoveryCandidateAddrs(addrs);
          if (filtered.isEmpty) {
            continue;
          }
          pool.upsert(
            P2pPeerInfo(id: peer.id.toString(), addrs: filtered),
            DateTime.now().toUtc(),
          );
          roundCount++;
        }
        totalCount += roundCount;
        final elapsed = DateTime.now().toUtc().difference(roundStartedAt);
        _p2pDebug(
          'libp2p dht discovery round completed round=$rounds '
          'peers=$roundCount elapsed=$elapsed',
        );
        if (roundCount > 0) {
          break;
        }
      }
      final elapsed = DateTime.now().toUtc().difference(startedAt);
      _p2pDebug(
        'libp2p dht discovery completed peers=$totalCount rounds=$rounds '
        'elapsed=$elapsed',
      );
    } catch (error) {
      _p2pDebug('libp2p dht discovery failed error=$error');
    } finally {
      _discoveryRefreshRunning = false;
    }
  }

  @override
  Future<List<SyncSource>> findShardPeers(StreamId stream) async {
    final deadline = DateTime.now().toUtc().add(shardDiscoveryTimeout);
    final providers = <String, p2p_addr.AddrInfo>{};
    final batches = await Future.wait(List.generate(
        9,
        (depth) => _findDhtProviders(deadline,
            namespace: _shardKey(stream.toHex().substring(0, depth)))));
    for (final batch in batches) {
      for (final info in batch) {
        if (info.id != _host?.id && info.addrs.isNotEmpty) {
          providers[info.id.toString()] = info;
        }
      }
    }
    final out = <SyncSource>[];
    for (final info in providers.values) {
      final eligible = filterDiscoveryCandidateAddrs(
          info.addrs.map((a) => a.toString()).toList());
      final preferred = selectPreferredP2pAddr(eligible);
      if (preferred != null) {
        out.add(await createPeerSource(
            peerAddrWithId(info.id.toString(), preferred)));
      }
    }
    return out;
  }

  Future<List<p2p_addr.AddrInfo>> _findDhtProviders(DateTime deadline,
      {String namespace = p2pDiscoveryKey}) async {
    final host = _host;
    if (host == null) {
      return const <p2p_addr.AddrInfo>[];
    }
    final pending = <p2p_addr.AddrInfo>[];
    final seen = <String>{};
    final providers = <String, p2p_addr.AddrInfo>{};

    void enqueue(p2p_addr.AddrInfo info) {
      final id = info.id.toString();
      if (info.id == host.id || seen.contains(id) || info.addrs.isEmpty) {
        return;
      }
      seen.add(id);
      pending.add(info);
    }

    for (final addr in _dhtBootstrapMultiaddrs()) {
      final info = _dhtAddrInfoFromMultiaddr(addr);
      if (info != null) {
        enqueue(info);
      }
    }

    var queried = 0;
    while (pending.isNotEmpty &&
        queried < peerDiscoveryDhtQueryLimit &&
        providers.length < peerDiscoveryDhtProviderLimit &&
        DateTime.now().toUtc().isBefore(deadline)) {
      final batch = <p2p_addr.AddrInfo>[];
      while (pending.isNotEmpty &&
          batch.length < peerDiscoveryDhtQueryConcurrency &&
          queried + batch.length < peerDiscoveryDhtQueryLimit) {
        batch.add(pending.removeAt(0));
      }
      queried += batch.length;
      final responses = await Future.wait(
        batch.map((info) => _queryDhtProviders(host, info, namespace)),
      );
      for (final response in responses) {
        if (response == null) {
          continue;
        }
        for (final provider in response.providerPeers) {
          final providerInfo = await _resolveDhtProviderInfo(host, provider);
          if (providerInfo == null) {
            continue;
          }
          providers[providerInfo.id.toString()] = providerInfo;
        }
        for (final closer in response.closerPeers) {
          final closerInfo = _dhtAddrInfoFromPeer(closer);
          if (closerInfo != null) {
            enqueue(closerInfo);
          }
        }
      }
    }
    _p2pDebug(
      'libp2p dht manual discovery completed queried=$queried '
      'providers=${providers.length} pending=${pending.length}',
    );
    return providers.values.toList(growable: false);
  }

  Future<p2p_dht.Message?> _queryDhtProviders(
    p2p.Host host,
    p2p_addr.AddrInfo info,
    String namespace,
  ) async {
    p2p_stream.P2PStream? stream;
    try {
      await host.peerStore.addrBook.addAddrs(
        info.id,
        info.addrs,
        const Duration(minutes: 10),
      );
      stream = await host
          .newStream(
            info.id,
            <String>[p2p_dht.AminoConstants.protocolID],
            p2p_context.Context(),
          )
          .timeout(peerDiscoveryDhtPeerQueryTimeout);
      final request = p2p_dht.Message(
        type: p2p_dht.MessageType.getProviders,
        key: _discoveryCid(namespace).multihash,
      );
      await stream
          .write(p2p_dht_codec.encodeMessage(request))
          .timeout(peerDiscoveryDhtPeerQueryTimeout);
      final response = await _readDhtMessage(stream)
          .timeout(peerDiscoveryDhtPeerQueryTimeout);
      _p2pDebug(
        'libp2p dht manual provider query succeeded peer=${info.id} '
        'providers=${response.providerPeers.length} '
        'closer_peers=${response.closerPeers.length} '
        'provider_ids=${_dhtPeerIds(response.providerPeers).join(',')} '
        'provider_addr_counts=${response.providerPeers.map((peer) => peer.addrs.length).join(',')}',
      );
      return response;
    } catch (error) {
      _p2pDebug(
        'libp2p dht manual provider query failed peer=${info.id} '
        'error=$error',
      );
      return null;
    } finally {
      try {
        await stream?.close();
      } catch (_) {}
    }
  }

  Future<void> _seedDhtPeer(String id) async {
    final pool = _discoveryPool;
    final host = _host;
    final dht = _dht;
    final parsed = parseP2pSyncSourceUpstream(id);
    final fullAddrs = parsed.transportAddrs
        .map((addr) => peerAddrWithId(parsed.peerId, addr))
        .toList(growable: false);
    pool?.upsert(
      P2pPeerInfo(id: parsed.peerId, addrs: fullAddrs),
      DateTime.now().toUtc(),
    );
    if (host == null || dht == null) {
      return;
    }
    try {
      final peerId = p2p_peer.PeerId.fromString(parsed.peerId);
      if (peerId == host.id) {
        return;
      }
      final addrs = parsed.transportAddrs
          .map(p2p_multiaddr.MultiAddr.new)
          .toList(growable: false);
      await host.peerStore.addrBook.addAddrs(
        peerId,
        addrs,
        const Duration(hours: 24),
      );
      final added = await dht.routingTable.tryAddPeer(peerId, queryPeer: false);
      _p2pDebug(
        'libp2p dht peer seeded peer=$peerId addrs=${addrs.join(',')} '
        'routing_added=$added',
      );
    } catch (error) {
      _p2pDebug('libp2p dht peer seed failed id=$id error=$error');
    }
  }

  Future<void> _advertiseDhtIfStale() async {
    final last = _lastDhtAdvertiseAt;
    if (last != null &&
        DateTime.now().toUtc().difference(last) <
            peerDiscoveryAdvertiseRetryInterval) {
      return;
    }
    await _advertiseDht();
  }

  Future<void> _advertiseDht() async {
    final dht = _dht;
    if (dht == null) {
      return;
    }
    if (_dhtAdvertiseRunning) {
      return;
    }
    _dhtAdvertiseRunning = true;
    try {
      await dht.provide(_discoveryCid(), true);
      final source = _source;
      if (source != null) {
        final state = await readSyncState(source);
        for (final prefix in state.coverage) {
          await dht.provide(_discoveryCid(_shardKey(prefix.value)), true);
        }
      }
      _lastDhtAdvertiseAt = DateTime.now().toUtc();
      _p2pDebug('libp2p dht advertised discovery_key=$p2pDiscoveryKey');
    } catch (error) {
      _p2pDebug('libp2p dht advertise failed error=$error');
    } finally {
      _dhtAdvertiseRunning = false;
    }
  }

  Future<RpcResponse> request(String id, RpcRequest request) async {
    final host = _host;
    if (host == null) {
      throw const SyncSourceException.unavailable(
        'p2p sync source unavailable',
      );
    }
    final peer = _addrInfoFromUpstream(id);
    final startedAt = DateTime.now();
    _p2pRpcDebug(
      'rpc request begin method=${_rpcMethodName(request.method)} '
      'peer=${peer.id} addrs=${peer.addrs.map((addr) => addr.toString()).join(',')}',
    );
    try {
      await host.connect(peer, context: p2p_context.Context());
      _p2pRpcDebug(
        'rpc connect ok method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
      );
    } catch (error) {
      _p2pDebug(
        'rpc connect failed method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} error=$error',
      );
      throw SyncSourceException.unavailable(
        'p2p connect failed: $error',
        error,
      );
    }
    p2p_stream.P2PStream stream;
    try {
      stream = await host.newStream(
        peer.id,
        <String>[p2pRpcProtocolId],
        p2p_context.Context(),
      );
      _p2pRpcDebug(
        'rpc stream opened method=${_rpcMethodName(request.method)} peer=${peer.id}',
      );
    } catch (error) {
      _p2pDebug(
        'rpc stream open failed method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} error=$error',
      );
      throw SyncSourceException.unavailable(
        'p2p stream open failed: $error',
        error,
      );
    }
    try {
      final requestPayload = request.toBytes();
      _p2pRpcDebug(
        'rpc write frame method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} bytes=${requestPayload.length}',
      );
      await _writeRpcFrame(stream, requestPayload);
      final responsePayload = await _readRpcFrame(stream);
      _p2pRpcDebug(
        'rpc read frame method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} bytes=${responsePayload.length}',
      );
      RpcResponse response;
      try {
        response = RpcResponse.fromBytes(responsePayload);
      } on FormatException catch (error) {
        throw SyncSourceException.invalidResponse(
          'decode rpc response: ${error.message}',
          details: error,
        );
      }
      _throwIfRpcError(response);
      _p2pRpcDebug(
        'rpc request ok method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} status=${response.status} '
        'elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
      );
      return response;
    } catch (error) {
      _p2pDebug(
        'rpc request failed method=${_rpcMethodName(request.method)} '
        'peer=${peer.id} error=$error',
      );
      await stream.reset();
      if (error is SyncSourceException) {
        rethrow;
      }
      throw SyncSourceException.unavailable(
        'p2p rpc transport failed: $error',
        error,
      );
    } finally {
      if (!stream.isClosed) {
        await stream.close();
      }
    }
  }

  Future<void> _handleStream(
    p2p_stream.P2PStream stream,
    p2p_peer.PeerId remotePeer,
  ) async {
    _p2pRpcDebug('rpc inbound stream remote_peer=$remotePeer');
    final source = _source;
    if (source == null) {
      _p2pDebug('rpc inbound unavailable remote_peer=$remotePeer');
      await _tryWriteRpcFrame(
        stream,
        const RpcResponse(
          status: rpcStatusUnavailable,
          error: 'p2p sync source unavailable',
          peers: null,
          configs: null,
          blobs: null,
          node: null,
        ).toBytes(),
        remotePeer: remotePeer,
        responseKind: 'unavailable',
      );
      await _tryCloseRpcStream(stream, remotePeer);
      return;
    }

    try {
      final payload = await _readRpcFrame(stream);
      final request = RpcRequest.fromBytes(payload);
      _p2pRpcDebug(
        'rpc inbound request remote_peer=$remotePeer '
        'method=${_rpcMethodName(request.method)} bytes=${payload.length}',
      );
      final response = await _handleRpcRequest(source, request, remotePeer);
      _p2pRpcDebug(
        'rpc inbound response remote_peer=$remotePeer '
        'method=${_rpcMethodName(request.method)} status=${response.status}',
      );
      await _tryWriteRpcFrame(
        stream,
        response.toBytes(),
        remotePeer: remotePeer,
        responseKind: 'ok',
      );
      await _tryCloseRpcStream(stream, remotePeer);
    } on FormatException catch (error) {
      _p2pDebug('rpc inbound bad request remote_peer=$remotePeer error=$error');
      await _tryWriteRpcFrame(
        stream,
        RpcResponse(
          status: rpcStatusBadRequest,
          error: error.message,
          peers: null,
          configs: null,
          blobs: null,
          node: null,
        ).toBytes(),
        remotePeer: remotePeer,
        responseKind: 'bad_request',
      );
      await _tryCloseRpcStream(stream, remotePeer);
    } catch (error) {
      _p2pDebug(
          'rpc inbound internal error remote_peer=$remotePeer error=$error');
      await _tryWriteRpcFrame(
        stream,
        const RpcResponse(
          status: rpcStatusInternal,
          error: 'internal server error',
          peers: null,
          configs: null,
          blobs: null,
          node: null,
        ).toBytes(),
        remotePeer: remotePeer,
        responseKind: 'internal',
      );
      await _tryCloseRpcStream(stream, remotePeer);
    }
  }

  Future<bool> _tryWriteRpcFrame(
    p2p_stream.P2PStream stream,
    Uint8List payload, {
    required p2p_peer.PeerId remotePeer,
    required String responseKind,
  }) async {
    if (!stream.isWritable) {
      _p2pDebug(
        'rpc inbound response skipped remote_peer=$remotePeer '
        'kind=$responseKind reason=stream_not_writable',
      );
      return false;
    }
    try {
      await _writeRpcFrame(stream, payload);
      return true;
    } catch (error) {
      _p2pDebug(
        'rpc inbound response write failed remote_peer=$remotePeer '
        'kind=$responseKind error=$error',
      );
      return false;
    }
  }

  Future<void> _tryCloseRpcStream(
    p2p_stream.P2PStream stream,
    p2p_peer.PeerId remotePeer,
  ) async {
    if (stream.isClosed) {
      return;
    }
    try {
      await stream.close();
    } catch (error) {
      _p2pDebug(
        'rpc inbound stream close failed remote_peer=$remotePeer error=$error',
      );
    }
  }

  Future<RpcResponse> _handleRpcRequest(
    SyncSource source,
    RpcRequest request,
    p2p_peer.PeerId remotePeer,
  ) async {
    switch (request.method) {
      case rpcMethodGetConfigs:
        final configs = await source.getConfigs();
        return RpcResponse(
          status: rpcStatusOk,
          error: '',
          peers: null,
          configs: configs
              .map<Object?>(
                (config) => config.toBytes(),
              )
              .toList(growable: false),
          blobs: null,
          node: null,
        );
      case rpcMethodGetSyncBlobs:
        final rawIds = request.syncBlobIds ?? const <Uint8List>[];
        if (rawIds.length > maxSyncBlobLookupRequestIds) {
          return RpcResponse(
            status: rpcStatusBadRequest,
            error: 'too many ids, max $maxSyncBlobLookupRequestIds',
            peers: null,
            configs: null,
            blobs: null,
            node: null,
          );
        }
        final ids = rawIds.map(SyncBlobId.new).toList(growable: false);
        final blobs = await source.getSyncBlobs(ids);
        if (blobs.length != ids.length) {
          return const RpcResponse(
            status: rpcStatusInternal,
            error: 'lookup response size does not match request size',
            peers: null,
            configs: null,
            blobs: null,
            node: null,
          );
        }
        var responseSize = 0;
        final items = <Object?>[];
        for (var i = 0; i < ids.length; i++) {
          final id = ids[i];
          final blob = blobs[i];
          Uint8List? payload;
          if (blob != null) {
            if (blob.id != id) {
              return const RpcResponse(
                status: rpcStatusInternal,
                error: 'lookup response item id does not match request id',
                peers: null,
                configs: null,
                blobs: null,
                node: null,
              );
            }
            if (blob.payload.length > maxSyncBlobLookupPayloadBytes) {
              return const RpcResponse(
                status: rpcStatusBadRequest,
                error: 'lookup payload exceeds maximum supported size',
                peers: null,
                configs: null,
                blobs: null,
                node: null,
              );
            }
            responseSize += id.toBytes().length + blob.payload.length;
            if (responseSize > maxSyncBlobLookupResponseBytes) {
              return const RpcResponse(
                status: rpcStatusBadRequest,
                error: 'lookup response exceeds maximum supported size',
                peers: null,
                configs: null,
                blobs: null,
                node: null,
              );
            }
            payload = Uint8List.fromList(blob.payload);
          }
          items.add(<Object?>[id.toBytes(), payload]);
        }
        return RpcResponse(
          status: rpcStatusOk,
          error: '',
          peers: null,
          configs: null,
          blobs: items,
          node: null,
        );
      case rpcMethodGetState:
        final state = await readSyncState(source);
        return RpcResponse(
            status: rpcStatusOk,
            error: '',
            peers: null,
            coverage: state.coverage.map((p) => p.value).toList(),
            configs: null,
            blobs: null,
            node: state.root == null
                ? null
                : _messageIndexNodeToWire(state.root!));
      case rpcMethodGetRoot:
        final node = await source.getMessageIndexRoot();
        return RpcResponse(
          status: rpcStatusOk,
          error: '',
          peers: null,
          configs: null,
          blobs: null,
          node: node == null ? null : _messageIndexNodeToWire(node),
        );
      case rpcMethodGetNode:
        final rawNodeId = request.nodeId;
        if (rawNodeId == null) {
          return const RpcResponse(
            status: rpcStatusBadRequest,
            error: 'message index node id must not be null',
            peers: null,
            configs: null,
            blobs: null,
            node: null,
          );
        }
        final node = await source.getMessageIndexNode(
          MessageIndexNodeId(rawNodeId),
        );
        return RpcResponse(
          status: rpcStatusOk,
          error: '',
          peers: null,
          configs: null,
          blobs: null,
          node: node == null ? null : _messageIndexNodeToWire(node),
        );
      case rpcMethodGetDiscoveryPeers:
        final peers = filterP2pPeerAddrsExcludingId(
          <String>[...defaultPeerExchangeAddrs, ...await discoverPeers()],
          remotePeer.toString(),
        );
        return RpcResponse(
          status: rpcStatusOk,
          error: '',
          peers: peers,
          configs: null,
          blobs: null,
          node: null,
        );
      case rpcMethodPushBlob:
        final rawBlobId = request.blobId;
        final rawBlob = request.blob;
        if (rawBlobId == null || rawBlob == null) {
          return const RpcResponse(
            status: rpcStatusBadRequest,
            error: 'push blob id and payload must not be null',
            peers: null,
            configs: null,
            blobs: null,
            node: null,
          );
        }
        await source
            .push(SyncBlob(id: SyncBlobId(rawBlobId), payload: rawBlob));
        _p2pDebug("received push");
        return const RpcResponse(
          status: rpcStatusOk,
          error: '',
          peers: null,
          configs: null,
          blobs: null,
          node: null,
        );
      default:
        return RpcResponse(
          status: rpcStatusBadRequest,
          error: 'unsupported rpc method: ${request.method}',
          peers: null,
          configs: null,
          blobs: null,
          node: null,
        );
    }
  }
}
