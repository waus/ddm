import 'dart:io';

import 'package:ddm_proto_dart/src/proto/constants.dart';

const String httpTransportProtocolName = 'http';
const String fileTransportProtocolName = 'file';
const String syncDatabaseFileName = 'ddm-sync.sqlite';
const String p2pTransportProtocolName = 'p2p';
const String p2pRpcProtocolId = '/ddm/rpc/1.0.0';
const String p2pDiscoveryNamespace = 'ddm/v1';
const String p2pDiscoveryKey =
    '731a7ab2a96a4d7e4972c0413bc1164a9f1ff545a84077105ec424094f99103c';

const int maxSyncBlobLookupRequestIds = 4096;
const int maxSyncBlobLookupResponseBytes = 8 * 1024 * 1024;
const int maxSyncBlobLookupPayloadBytes = 2 * 1024 * 1024;
const int maxSyncBlobPushRequestBytes = 6 * 1024 * 1024;
const int syncSourceClientMaxBodyBytes = 10 * 1024 * 1024;
const int syncSourceClientMaxErrorBodyBytes = 8 * 1024;
const int maxSyncSourceRpcFrameBytes = 10 * 1024 * 1024;

const Duration syncSourceClientTimeout = Duration(seconds: 15);
const Duration syncSourceHTTPShutdownGracePeriod = Duration(seconds: 5);
const Duration syncSourceHTTPIdleTimeout = Duration(seconds: 60);
const Duration syncSourceRpcRequestTimeout = Duration(seconds: 15);
const Duration syncSourceRpcReadDeadline = Duration(seconds: 15);
const Duration syncSourceRpcWriteDeadline = Duration(seconds: 15);
const Duration peerDiscoveryFastPollInterval = Duration(seconds: 10);
const Duration peerDiscoverySlowPollInterval = Duration(minutes: 10);
const Duration peerDiscoveryDhtLookupBudget = Duration(minutes: 3);
const Duration peerDiscoveryDhtProtocolProbeTimeout = Duration(seconds: 15);
const Duration peerDiscoveryDhtPeerQueryTimeout = Duration(seconds: 30);
const Duration peerDiscoveryPingTimeout = Duration(seconds: 10);
const Duration peerDiscoveryAdvertiseRetryInterval = Duration(minutes: 5);
const int peerDiscoveryDhtProviderLimit = 100;
const int peerDiscoveryDhtLookupMaxRounds = 2;
const int peerDiscoveryDhtQueryLimit = 96;
const int peerDiscoveryDhtQueryConcurrency = 8;

const String sqliteHeaderMagic = 'SQLite format 3\x00';
final List<int> sqliteHeaderMagicBytes = sqliteHeaderMagic.codeUnits;

const String defaultP2pListenAddr = '/ip4/0.0.0.0/tcp/23708';
const String randomP2pListenAddr = '/ip4/0.0.0.0/tcp/0';
const int discoveryPeerPoolCapacity = 100;
const int discoveryPeerMaxAddrsPerPeer = 16;

const List<String> defaultPeerExchangeAddrs = <String>[
  // TODO: Add public nodes.
];

//TODO: fix dnsaddr in libp2p
//  '/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN',
//   '/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa',
//   '/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb',
//   '/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt',
const List<String> defaultP2pBootstrapAddrs = <String>[
 '/ip4/54.38.47.166/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb',
  '/ip4/147.135.44.132/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN',
  '/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ',
  '/ip4/104.211.114.82/tcp/4001/p2p/QmSoLnSGccFuZQJzRadHn95W2CrSFmZuTdDWP8HXaHca9z',
  ...defaultPeerExchangeAddrs,
];

const int rpcStatusOk = 0;
const int rpcStatusUnavailable = 1;
const int rpcStatusBadRequest = 2;
const int rpcStatusInternal = 3;
const int rpcMethodGetConfigs = 1;
const int rpcMethodGetSyncBlobs = 2;
const int rpcMethodGetRoot = 3;
const int rpcMethodGetNode = 4;
const int rpcMethodGetDiscoveryPeers = 5;
const int rpcMethodPushBlob = 6;

const String queryCreateFileBlobsTable = '''
CREATE TABLE IF NOT EXISTS blobs (
  blob_id BLOB PRIMARY KEY,
  expires_at INTEGER NOT NULL,
  leaf_node_id BLOB NOT NULL,
  blob BLOB NOT NULL
);
''';

const String queryCreateFileBranchesTable = '''
CREATE TABLE IF NOT EXISTS branches (
  branch_id BLOB PRIMARY KEY,
  prefix TEXT NOT NULL,
  children_count INTEGER NOT NULL,
  min_expires_at INTEGER NOT NULL,
  max_expires_at INTEGER NOT NULL,
  children_hashes BLOB NOT NULL
);
''';

const int childrenHashesEncodedByteLength =
    messageIndexChildSlotCount * messageIndexNodeIdSize;

bool isHttpPeerId(String id) =>
    id.startsWith('http://') || id.startsWith('https://');

bool isFilePeerId(String id) => id.startsWith('file://');

int unixSeconds(DateTime value) {
  final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xffffffff) {
    throw FormatException('unix timestamp out of uint32 range: $seconds');
  }
  return seconds;
}

DateTime defaultUtcNow() => DateTime.now().toUtc();

Future<List<int>> readLimited(HttpClientResponse response, int maxBytes) async {
  final out = <int>[];
  await for (final chunk in response) {
    out.addAll(chunk);
    if (out.length > maxBytes) {
      throw FormatException('response body exceeds $maxBytes bytes');
    }
  }
  return out;
}
