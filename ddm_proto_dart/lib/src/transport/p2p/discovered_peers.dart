part of '../p2p.dart';

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
