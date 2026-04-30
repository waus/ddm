import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dcid/dcid.dart';
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as p2p_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart' as p2p_keys;
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as p2p_crypto_pb;
import 'package:dart_libp2p/core/multiaddr.dart' as p2p_multiaddr;
import 'package:dart_libp2p/core/network/common.dart' as p2p_common;
import 'package:dart_libp2p/core/network/context.dart' as p2p_context;
import 'package:dart_libp2p/core/network/notifiee.dart' as p2p_notifiee;
import 'package:dart_libp2p/core/network/stream.dart' as p2p_stream;
import 'package:dart_libp2p/core/peer/addr_info.dart' as p2p_addr;
import 'package:dart_libp2p/core/peer/peer_id.dart' as p2p_peer;
import 'package:dart_libp2p/dart_libp2p.dart' as p2p;
import 'package:dart_libp2p_kad_dht/dart_libp2p_kad_dht.dart' as p2p_dht;
// ignore: implementation_imports
import 'package:dart_libp2p_kad_dht/src/pb/dht_codec.dart' as p2p_dht_codec;
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart'
    as p2p_limiter;
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart'
    as p2p_resource;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart'
    as p2p_noise;
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_connection;
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart' as p2p_tcp;
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/p2p_rpc.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/sync/sync.dart';
import 'package:ddm_proto_dart/src/transport/constants.dart';
import 'package:ddm_proto_dart/src/transport/errors.dart';
import 'package:ddm_proto_dart/src/transport/server.dart';

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

final class DartLibp2pHostBackend implements P2pHostBackend {
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

  Future<List<p2p_addr.AddrInfo>> _findDhtProviders(DateTime deadline) async {
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
        batch.map((info) => _queryDhtProviders(host, info)),
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
        key: _discoveryCid().multihash,
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

final class P2pSyncTransportServer implements SyncTransportServer {
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
  ServerFlags get flags => const ServerFlags(serverFlagDiscovery);

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

Uint8List generateP2pPrivateKey() {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256), growable: false),
  );
}

Future<p2p_keys.KeyPair> p2pKeyPairFromPrivateKey(Uint8List privateKey) async {
  final raw = Uint8List.fromList(privateKey);
  if (raw.length == 32) {
    final key = await p2p_ed25519.Ed25519PrivateKey.fromRawBytes(raw);
    return p2p_keys.KeyPair(key.publicKey, key);
  }
  if (raw.length == 64) {
    final seed = Uint8List.sublistView(raw, 0, 32);
    final key = await p2p_ed25519.Ed25519PrivateKey.fromRawBytes(seed);
    return p2p_keys.KeyPair(key.publicKey, key);
  }

  try {
    final decoded = p2p_crypto_pb.PrivateKey.fromBuffer(raw);
    if (decoded.type != p2p_crypto_pb.KeyType.Ed25519) {
      throw const FormatException('p2p private key must be Ed25519');
    }
    final data = Uint8List.fromList(decoded.data);
    if (data.length < 32) {
      throw FormatException(
        'p2p Ed25519 private key data must be at least 32 bytes, got ${data.length}',
      );
    }
    final key = await p2p_ed25519.Ed25519PrivateKey.fromRawBytes(
      Uint8List.sublistView(data, 0, 32),
    );
    return p2p_keys.KeyPair(key.publicKey, key);
  } catch (_) {
    final key = await p2p_ed25519.Ed25519PrivateKey.unmarshal(raw);
    return p2p_keys.KeyPair(key.publicKey, key);
  }
}

final class P2pPeerInfo {
  P2pPeerInfo({required this.id, required Iterable<String> addrs})
      : addrs = mergeUniqueP2pAddrs(addrs) {
    if (id.trim().isEmpty) {
      throw const FormatException('p2p peer id must not be empty');
    }
    if (this.addrs.isEmpty) {
      throw const FormatException('p2p peer must have at least one address');
    }
  }

  final String id;
  final List<String> addrs;
}

final class P2pDiscoveredPeer {
  P2pDiscoveredPeer({
    required this.id,
    required Iterable<String> addrs,
    required DateTime lastSeenAt,
    DateTime? lastPingAt,
    String? lastPingAddr,
  })  : addrs = mergeUniqueP2pAddrs(addrs),
        lastSeenAt = lastSeenAt.toUtc(),
        lastPingAt = lastPingAt?.toUtc(),
        lastPingAddr = lastPingAddr?.trim();

  final String id;
  List<String> addrs;
  DateTime lastSeenAt;
  DateTime? lastPingAt;
  String? lastPingAddr;

  P2pDiscoveredPeer snapshot() {
    return P2pDiscoveredPeer(
      id: id,
      addrs: addrs,
      lastSeenAt: lastSeenAt,
      lastPingAt: lastPingAt,
      lastPingAddr: lastPingAddr,
    );
  }
}

final class P2pDiscoveryPeerPool {
  P2pDiscoveryPeerPool({required this.capacity}) {
    if (capacity <= 0) {
      throw const FormatException(
          'discovery peer pool capacity must be positive');
    }
  }

  final int capacity;
  final Map<String, P2pDiscoveredPeer> _peers = <String, P2pDiscoveredPeer>{};

  int get size => _peers.length;

  void reset() {
    _peers.clear();
  }

  int alive(DateTime now) {
    final cutoff = now.toUtc().subtract(peerDiscoverySlowPollInterval * 2);
    return _peers.values
        .where((peer) => peer.lastSeenAt.isAfter(cutoff))
        .length;
  }

  void upsert(P2pPeerInfo info, DateTime now) {
    final existing = _peers[info.id];
    if (existing != null) {
      existing.addrs = mergeUniqueP2pAddrs(<String>[
        ...existing.addrs,
        ...info.addrs,
        if (existing.lastPingAddr != null) existing.lastPingAddr!,
      ]);
      existing.lastSeenAt = now.toUtc();
      return;
    }

    if (_peers.length >= capacity) {
      _evictOldest();
    }
    _peers[info.id] = P2pDiscoveredPeer(
      id: info.id,
      addrs: info.addrs,
      lastSeenAt: now,
    );
  }

  void markHealthy(String id, String? preferredAddr, DateTime now) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }
    peer.lastPingAt = now.toUtc();
    final clean = preferredAddr?.trim();
    if (clean != null && clean.isNotEmpty) {
      peer.lastPingAddr = clean;
      peer.addrs = mergeUniqueP2pAddrs(<String>[...peer.addrs, clean]);
    }
  }

  void remove(String id) {
    _peers.remove(id);
  }

  List<P2pDiscoveredPeer> snapshotForPing() {
    final out = _peers.values.map((peer) => peer.snapshot()).toList();
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  List<String> addresses() {
    final out = <String>[];
    for (final peer in _peers.values) {
      final preferred = peer.lastPingAddr ?? selectPreferredP2pAddr(peer.addrs);
      if (preferred == null || preferred.isEmpty) {
        continue;
      }
      out.add(peerAddrWithId(peer.id, preferred));
    }
    out.sort();
    return out;
  }

  void _evictOldest() {
    String? evictId;
    DateTime? evictFresh;
    for (final peer in _peers.values) {
      var fresh = peer.lastSeenAt;
      final pingAt = peer.lastPingAt;
      if (pingAt != null && pingAt.isAfter(fresh)) {
        fresh = pingAt;
      }
      if (evictFresh == null ||
          fresh.isBefore(evictFresh) ||
          (fresh.isAtSameMomentAs(evictFresh) &&
              (evictId == null || peer.id.compareTo(evictId) < 0))) {
        evictFresh = fresh;
        evictId = peer.id;
      }
    }
    if (evictId != null) {
      _peers.remove(evictId);
    }
  }
}

CID _discoveryCid() {
  return CID.fromData(
    CID.V1,
    'raw',
    Uint8List.fromList(utf8.encode(p2pDiscoveryKey)),
  );
}

List<String> normalizeP2pListenAddrs(Iterable<String> raw) {
  final out = <String>[];
  for (final item in raw) {
    for (final part in item.split(',')) {
      final clean = part.trim();
      if (clean.isNotEmpty) {
        out.add(clean);
      }
    }
  }
  return out.isEmpty ? const <String>[defaultP2pListenAddr] : out;
}

String normalizeP2pSyncSourceUpstream(String upstream) {
  final clean = upstream.trim();
  if (clean.isEmpty) {
    throw const FormatException('sync source upstream must not be empty');
  }
  final parsed = parseP2pSyncSourceUpstream(clean);
  if (parsed.transportAddrs.isEmpty) {
    throw const FormatException(
      'sync source multiaddr must include transport address',
    );
  }
  return clean;
}

bool isP2pPeerId(String id) {
  try {
    normalizeP2pSyncSourceUpstream(id);
    return true;
  } on FormatException {
    return false;
  }
}

({String peerId, List<String> transportAddrs}) parseP2pSyncSourceUpstream(
  String upstream,
) {
  final clean = upstream.trim();
  if (!clean.startsWith('/')) {
    throw const FormatException('sync source multiaddr must start with /');
  }
  final parts = clean.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.length < 4) {
    throw const FormatException('invalid sync source multiaddr');
  }

  var p2pIndex = -1;
  for (var i = parts.length - 2; i >= 0; i--) {
    if (parts[i] == 'p2p') {
      p2pIndex = i;
      break;
    }
  }
  if (p2pIndex < 0 || p2pIndex + 1 >= parts.length) {
    throw const FormatException('sync source multiaddr must include /p2p/{id}');
  }
  final peerId = parts[p2pIndex + 1];
  if (peerId.isEmpty) {
    throw const FormatException('p2p peer id must not be empty');
  }
  final transportParts = parts.sublist(0, p2pIndex);
  if (transportParts.length < 2) {
    throw const FormatException(
      'sync source multiaddr must include transport address',
    );
  }
  return (
    peerId: peerId,
    transportAddrs: <String>['/${transportParts.join('/')}'],
  );
}

String peerAddrWithId(String id, String addr) {
  final cleanId = id.trim();
  final cleanAddr = addr.trim();
  if (cleanId.isEmpty) {
    throw const FormatException('p2p peer id must not be empty');
  }
  if (cleanAddr.isEmpty) {
    throw const FormatException('p2p peer address must not be empty');
  }
  return '$cleanAddr/p2p/$cleanId';
}

List<String> mergeUniqueP2pAddrs(Iterable<String> addrs) {
  final unique = <String>{};
  for (final addr in addrs) {
    final clean = addr.trim();
    if (clean.isNotEmpty) {
      unique.add(clean);
    }
  }
  final out = unique.toList();
  out.sort((a, b) {
    final leftRelay = isP2pRelayAddr(a);
    final rightRelay = isP2pRelayAddr(b);
    if (leftRelay != rightRelay) {
      return leftRelay ? 1 : -1;
    }
    return a.compareTo(b);
  });
  if (out.length > discoveryPeerMaxAddrsPerPeer) {
    return out.sublist(0, discoveryPeerMaxAddrsPerPeer);
  }
  return out;
}

String? selectPreferredP2pAddr(Iterable<String> addrs) {
  String? relayAddr;
  for (final addr in mergeUniqueP2pAddrs(addrs)) {
    if (!isP2pRelayAddr(addr)) {
      return addr;
    }
    relayAddr ??= addr;
  }
  return relayAddr;
}

bool isP2pRelayAddr(String addr) => addr.contains('/p2p-circuit');

List<String> filterP2pPeerAddrsExcludingId(
  Iterable<String> addrs,
  String excludedPeerId,
) {
  if (excludedPeerId.trim().isEmpty) {
    return addrs
        .map((addr) => addr.trim())
        .where((addr) => addr.isNotEmpty)
        .toList();
  }
  final out = <String>[];
  for (final addr in addrs) {
    try {
      final parsed = parseP2pSyncSourceUpstream(addr);
      if (parsed.peerId == excludedPeerId) {
        continue;
      }
    } on FormatException {
      // Keep unparsable peer exchange entries so callers can decide how to log.
    }
    out.add(addr);
  }
  return out;
}

List<String> filterPublicDiscoveryAddrs(Iterable<String> addrs) {
  return addrs.where(_isPublicDiscoveryAddr).toList(growable: false);
}

List<String> filterDiscoveryCandidateAddrs(Iterable<String> addrs) {
  return addrs.where(_isDiscoveryCandidateAddr).toList(growable: false);
}

p2p_addr.AddrInfo _addrInfoFromUpstream(String upstream) {
  final parsed = parseP2pSyncSourceUpstream(upstream);
  return p2p_addr.AddrInfo(
    p2p_peer.PeerId.fromString(parsed.peerId),
    parsed.transportAddrs
        .map(p2p_multiaddr.MultiAddr.new)
        .toList(growable: false),
  );
}

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

ConfigRecord _configRecordFromWire(Object? item) {
  if (item is! Uint8List) {
    throw const FormatException('decode config record');
  }
  return parseConfigRecord(item);
}

Object _messageIndexNodeToWire(MessageIndexNode node) {
  node.validate();
  final leaf = node.leaf;
  if (leaf != null) {
    return <Object?>[
      <Object?>[leaf.syncBlobId.toBytes(), leaf.ttl],
      null,
    ];
  }

  final branch = node.branch;
  if (branch == null) {
    throw const FormatException('message index node has no variant');
  }
  return <Object?>[
    null,
    <Object?>[
      branch.prefix,
      branch.childrenCount,
      branch.minTtl,
      branch.maxTtl,
      branch.childrenIds
          .map<Object?>((id) => id?.toBytes())
          .toList(growable: false),
    ],
  ];
}

MessageIndexNode _messageIndexNodeFromWire(Object wire) {
  if (wire is! List<Object?> || wire.length != 2) {
    throw const FormatException('decode message index node');
  }
  final leaf = wire[0];
  final branch = wire[1];
  if (leaf != null && branch != null) {
    throw const FormatException(
      'message index node has both leaf and branch variants',
    );
  }
  if (leaf != null) {
    if (leaf is! List<Object?> || leaf.length != 2) {
      throw const FormatException('decode message index leaf');
    }
    final rawId = leaf[0];
    final ttl = leaf[1];
    if (rawId is! Uint8List || ttl is! int) {
      throw const FormatException('decode message index leaf');
    }
    final node = MessageIndexNode.leaf(
      MessageIndexLeaf(syncBlobId: SyncBlobId(rawId), ttl: ttl),
    );
    node.validate();
    return node;
  }
  if (branch != null) {
    if (branch is! List<Object?> || branch.length != 5) {
      throw const FormatException('decode message index branch');
    }
    final prefix = branch[0];
    final childrenCount = branch[1];
    final minTtl = branch[2];
    final maxTtl = branch[3];
    final rawChildren = branch[4];
    if (prefix is! String ||
        childrenCount is! int ||
        minTtl is! int ||
        maxTtl is! int ||
        rawChildren is! List<Object?>) {
      throw const FormatException('decode message index branch');
    }
    if (rawChildren.length != messageIndexChildSlotCount) {
      throw FormatException(
        'message index branch has ${rawChildren.length} children, want $messageIndexChildSlotCount',
      );
    }
    final children = <MessageIndexNodeId?>[];
    for (var i = 0; i < rawChildren.length; i++) {
      final rawChild = rawChildren[i];
      if (rawChild == null) {
        children.add(null);
        continue;
      }
      if (rawChild is! Uint8List) {
        throw FormatException('parse branch child $i');
      }
      children.add(MessageIndexNodeId(rawChild));
    }
    final node = MessageIndexNode.branch(
      MessageIndexBranch(
        prefix: prefix,
        childrenCount: childrenCount,
        minTtl: minTtl,
        maxTtl: maxTtl,
        childrenIds: children,
      ),
    );
    node.validate();
    return node;
  }
  throw const FormatException('message index node has no variant');
}

bool _isPublicDiscoveryAddr(String addr) {
  final ip = _multiaddrIp(addr);
  if (ip == null) {
    return false;
  }
  return !_isDeniedDiscoveryIp(ip);
}

bool _isDiscoveryCandidateAddr(String addr) {
  final ip = _multiaddrIp(addr);
  if (ip == null) {
    return false;
  }
  if (ip.type == InternetAddressType.IPv4 &&
      ip.rawAddress.every((b) => b == 0)) {
    return false;
  }
  return true;
}

InternetAddress? _multiaddrIp(String addr) {
  final parts = addr.split('/').where((part) => part.isNotEmpty).toList();
  for (var i = 0; i + 1 < parts.length; i += 2) {
    if (parts[i] == 'ip4' || parts[i] == 'ip6') {
      return InternetAddress.tryParse(parts[i + 1]);
    }
  }
  return null;
}

bool _isDeniedDiscoveryIp(InternetAddress ip) {
  if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) {
    return true;
  }
  final raw = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    final a = raw[0];
    final b = raw[1];
    return a == 0 ||
        a == 10 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && (b == 0 || b == 168)) ||
        (a == 198 && (b == 18 || b == 19 || b == 51)) ||
        (a == 203 && b == 0) ||
        a >= 224;
  }
  return raw.every((b) => b == 0) ||
      (raw[0] & 0xfe) == 0xfc ||
      (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) ||
      raw[0] == 0xff ||
      _bytesEqualPrefix(raw, const <int>[0x20, 0x01, 0x0d, 0xb8]);
}

bool _bytesEqualPrefix(List<int> value, List<int> prefix) {
  if (value.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (value[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
