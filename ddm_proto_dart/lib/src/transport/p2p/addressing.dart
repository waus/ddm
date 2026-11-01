part of '../p2p.dart';

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
