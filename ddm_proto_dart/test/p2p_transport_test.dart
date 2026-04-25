import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

void main() {
  test('P2P listen address normalization mirrors Go defaults', () {
    expect(normalizeP2pListenAddrs(const <String>[]), [defaultP2pListenAddr]);
    expect(
      normalizeP2pListenAddrs(const <String>[
        ' /ip4/127.0.0.1/tcp/1, /ip4/127.0.0.1/tcp/2 ',
      ]),
      ['/ip4/127.0.0.1/tcp/1', '/ip4/127.0.0.1/tcp/2'],
    );
  });

  test('P2P peer matching requires multiaddr with transport and peer id', () {
    const upstream =
        '/ip4/203.0.113.10/tcp/23708/p2p/12D3KooWJvfCPgbGPAqsJFo1FsoUDxu6osoRsPxw55J6zsxvqXLa';

    expect(isP2pPeerId(upstream), isTrue);
    final parsed = parseP2pSyncSourceUpstream(upstream);
    expect(
        parsed.peerId, '12D3KooWJvfCPgbGPAqsJFo1FsoUDxu6osoRsPxw55J6zsxvqXLa');
    expect(parsed.transportAddrs, ['/ip4/203.0.113.10/tcp/23708']);

    const relayUpstream =
        '/ip4/203.0.113.20/tcp/23708/p2p/relay-peer/p2p-circuit/p2p/target-peer';
    final relayParsed = parseP2pSyncSourceUpstream(relayUpstream);
    expect(relayParsed.peerId, 'target-peer');
    expect(
      relayParsed.transportAddrs,
      ['/ip4/203.0.113.20/tcp/23708/p2p/relay-peer/p2p-circuit'],
    );

    expect(isP2pPeerId('http://127.0.0.1:8080'), isFalse);
    expect(isP2pPeerId('/p2p/12D3KooWNoTransport'), isFalse);
  });

  test('P2P default bootstrap addresses are separate direct multiaddrs', () {
    for (final addr in defaultP2pBootstrapAddrs) {
      final parsed = parseP2pSyncSourceUpstream(addr);
      expect(parsed.peerId, isNotEmpty);
      expect(parsed.transportAddrs, hasLength(1));
      expect(parsed.transportAddrs.single, isNot(contains('/p2p/')));
    }
  });

  test('P2P discovery pool prefers healthy direct addresses', () {
    final pool = P2pDiscoveryPeerPool(capacity: 4);
    final now = DateTime.utc(2026, 4, 20, 10, 0, 0);
    const peerId = '12D3KooWPeerA';
    const relayAddr =
        '/ip4/203.0.113.11/tcp/4101/p2p/12D3KooWRelay/p2p-circuit';
    const directAddr = '/ip4/203.0.113.10/tcp/4101';

    pool.upsert(
      P2pPeerInfo(id: peerId, addrs: const <String>[relayAddr, directAddr]),
      now,
    );
    pool.markHealthy(peerId, directAddr, now);

    expect(pool.addresses(), [peerAddrWithId(peerId, directAddr)]);
  });

  test('P2P discovery pool evicts oldest peer and caps addresses', () {
    final pool = P2pDiscoveryPeerPool(capacity: 2);
    final now = DateTime.utc(2026, 4, 20, 10, 0, 0);

    pool.upsert(
      P2pPeerInfo(
          id: 'peer-a', addrs: const <String>['/ip4/203.0.113.1/tcp/1']),
      now,
    );
    pool.upsert(
      P2pPeerInfo(
          id: 'peer-b', addrs: const <String>['/ip4/203.0.113.2/tcp/1']),
      now.add(const Duration(seconds: 1)),
    );
    pool.upsert(
      P2pPeerInfo(
          id: 'peer-c', addrs: const <String>['/ip4/203.0.113.3/tcp/1']),
      now.add(const Duration(seconds: 2)),
    );

    expect(pool.size, 2);
    expect(pool.snapshotForPing().map((peer) => peer.id), ['peer-b', 'peer-c']);

    final capped = P2pPeerInfo(
      id: 'peer-many',
      addrs: List<String>.generate(
        discoveryPeerMaxAddrsPerPeer + 4,
        (index) => '/ip4/203.0.113.${index + 1}/tcp/4101',
      ),
    );
    expect(capped.addrs.length, discoveryPeerMaxAddrsPerPeer);
  });

  test('P2P discovery address filters reject public advertisement hazards', () {
    final addrs = const <String>[
      '/ip4/127.0.0.1/tcp/4001',
      '/ip4/10.0.0.7/tcp/4001',
      '/ip4/8.8.8.8/tcp/4001',
      '/dns4/localhost/tcp/4001',
      '/dns4/example.com/tcp/4001',
      '/ip4/0.0.0.0/tcp/4001',
    ];

    expect(filterPublicDiscoveryAddrs(addrs), ['/ip4/8.8.8.8/tcp/4001']);
    expect(
      filterDiscoveryCandidateAddrs(addrs),
      containsAll(<String>[
        '/ip4/127.0.0.1/tcp/4001',
        '/ip4/10.0.0.7/tcp/4001',
        '/ip4/8.8.8.8/tcp/4001',
      ]),
    );
    expect(
      filterDiscoveryCandidateAddrs(addrs),
      isNot(contains('/ip4/0.0.0.0/tcp/4001')),
    );
  });

  test('P2P server abstraction loads identity and delegates to backend',
      () async {
    final source = _EmptySyncSource();
    final backend = _RecordingP2pBackend();
    final privateKey = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final server = P2pSyncTransportServer(
      loadIdentity: () => privateKey,
      backend: backend,
      rawListenAddrs: '/ip4/127.0.0.1/tcp/23708',
      publicRelay: true,
    );

    await server.start(source);
    expect(server.protocolName, p2pTransportProtocolName);
    expect(server.flags.has(serverFlagDiscovery), isTrue);
    expect(server.loadedPrivateKey, privateKey);
    expect(backend.started, isTrue);
    expect(backend.listenAddrs, ['/ip4/127.0.0.1/tcp/23708']);
    expect(backend.publicRelay, isTrue);

    const upstream = '/ip4/203.0.113.10/tcp/23708/p2p/peer-a';
    expect(server.peerMatch(upstream), isTrue);
    expect(await server.createPeerSource(upstream), isA<_EmptySyncSource>());

    await server.stop();
    expect(backend.stopped, isTrue);
  });

  test('P2P discovery starts the backend lazily', () async {
    final source = _EmptySyncSource();
    final backend = _RecordingP2pBackend();
    final privateKey = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final server = P2pSyncTransportServer(
      loadIdentity: () => privateKey,
      source: source,
      backend: backend,
      rawListenAddrs: '/ip4/127.0.0.1/tcp/0',
    );

    final peers = await server.discoverPeers();

    expect(peers, isEmpty);
    expect(backend.started, isTrue);
    expect(backend.discoverCalls, 1);
    expect(backend.listenAddrs, ['/ip4/127.0.0.1/tcp/0']);

    await server.stop();
  });

  test('live Dart libp2p backend serves sync RPCs over TCP', () async {
    final blobId = SyncBlobId(
      Uint8List.fromList(List<int>.generate(syncBlobIdSize, (i) => i)),
    );
    final blob = SyncBlob(
      id: blobId,
      payload: Uint8List.fromList(<int>[10, 20, 30, 40]),
    );
    final sourceA = _MemorySyncSource(id: 'source-a');
    final sourceB = _MemorySyncSource(
      id: 'source-b',
      configs: <ConfigRecord>[
        ConfigRecord(version: 1, payload: Uint8List.fromList(<int>[7, 8, 9])),
      ],
      blobs: <SyncBlob>[blob],
    );
    final backendA = DartLibp2pHostBackend(bootstrapAddrs: const <String>[]);
    final backendB = DartLibp2pHostBackend(bootstrapAddrs: const <String>[]);
    final serverA = P2pSyncTransportServer(
      loadIdentity: generateP2pPrivateKey,
      backend: backendA,
      rawListenAddrs: '/ip4/127.0.0.1/tcp/0',
    );
    final serverB = P2pSyncTransportServer(
      loadIdentity: generateP2pPrivateKey,
      backend: backendB,
      rawListenAddrs: '/ip4/127.0.0.1/tcp/0',
    );
    await serverA.start(sourceA);
    addTearDown(serverA.stop);
    await serverB.start(sourceB);
    addTearDown(serverB.stop);

    final bAddr = backendB.serverAddrs.first;
    final peer = await serverA.createPeerSource(bAddr);

    final configs = await peer.getConfigs();
    expect(configs, hasLength(1));
    expect(configs.single.payload, <int>[7, 8, 9]);

    final root = await peer.getMessageIndexRoot();
    expect(root, isNotNull);
    expect(root!.hash(), sourceB.root!.hash());
    final loadedRoot = await peer.getMessageIndexNode(root.hash());
    expect(loadedRoot, isNotNull);
    expect(loadedRoot!.toBytes(), root.toBytes());

    final blobs = await peer.getSyncBlobs(<SyncBlobId>[
      blobId,
      SyncBlobId(Uint8List.fromList(List<int>.filled(syncBlobIdSize, 0xff))),
    ]);
    expect(blobs[0]?.payload, blob.payload);
    expect(blobs[1], isNull);

    await peer.push(
      SyncBlob(
        id: SyncBlobId(Uint8List.fromList(List<int>.filled(syncBlobIdSize, 3))),
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    expect(sourceB.pushed, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 30)));
}

final class _RecordingP2pBackend implements P2pHostBackend {
  bool started = false;
  bool stopped = false;
  bool publicRelay = false;
  int discoverCalls = 0;
  List<String> listenAddrs = const <String>[];

  @override
  Future<void> start({
    required Uint8List privateKey,
    required SyncSource source,
    required List<String> listenAddrs,
    required bool publicRelay,
    required P2pDiscoveryPeerPool discoveryPool,
  }) async {
    started = true;
    this.listenAddrs = List<String>.from(listenAddrs);
    this.publicRelay = publicRelay;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<SyncSource> createPeerSource(String id) async =>
      _EmptySyncSource(id: id);

  @override
  Future<List<String>> discoverPeers() async {
    discoverCalls++;
    return const <String>[];
  }
}

final class _EmptySyncSource implements SyncSource {
  _EmptySyncSource({this.id = 'empty'});

  @override
  final String id;

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(0);

  @override
  Future<List<ConfigRecord>> getConfigs() async => const <ConfigRecord>[];

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async => null;

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async =>
      null;

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async =>
      List<SyncBlob?>.filled(ids.length, null);

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {}

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}

final class _MemorySyncSource implements SyncSource {
  _MemorySyncSource({
    required this.id,
    List<ConfigRecord> configs = const <ConfigRecord>[],
    List<SyncBlob> blobs = const <SyncBlob>[],
  }) : configs = List<ConfigRecord>.from(configs) {
    for (final blob in blobs) {
      this.blobs[blob.id] = blob;
    }
    if (blobs.isNotEmpty) {
      final first = blobs.first;
      root = MessageIndexNode.leaf(
        MessageIndexLeaf(syncBlobId: first.id, ttl: 3600),
      );
      nodes[root!.hash()] = root!;
    }
  }

  @override
  final String id;
  final List<ConfigRecord> configs;
  final Map<SyncBlobId, SyncBlob> blobs = <SyncBlobId, SyncBlob>{};
  final Map<MessageIndexNodeId, MessageIndexNode> nodes =
      <MessageIndexNodeId, MessageIndexNode>{};
  final List<SyncBlob> pushed = <SyncBlob>[];
  MessageIndexNode? root;

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree |
            syncSourceFlagSupportPeerExchange |
            syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async => configs;

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async => root;

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async =>
      nodes[id];

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async =>
      ids.map((id) => blobs[id]).toList(growable: false);

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    pushed.add(blob);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}
