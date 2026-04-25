import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/storage/storage.dart';
import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/sync/sync.dart';
import 'package:ddm_proto_dart/src/transport/constants.dart';
import 'package:ddm_proto_dart/src/transport/server.dart';
import 'package:ddm_proto_dart/src/transport/usb.dart';
import 'package:sqlite3/sqlite3.dart';

final class FileSyncSourceClient implements SyncSource {
  FileSyncSourceClient(String upstream, {UtcNow? nowUtc})
      : _nowUtc = nowUtc ?? defaultUtcNow {
    final normalized = normalizeFileSyncSourceUpstream(upstream);
    id = normalized.id;
    _db = sqlite3.open(normalized.path);
    try {
      _initSchema();
      _collectExpired();
      _rootId = _findLiveRootId();
    } catch (_) {
      _db.dispose();
      rethrow;
    }
  }

  late final Database _db;
  final UtcNow _nowUtc;
  MessageIndexNodeId? _rootId;
  bool _closed = false;

  @override
  late final String id;

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async => const <ConfigRecord>[];

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    _requireOpen();
    _collectExpired();
    _rootId = _findLiveRootId();
    final rootId = _rootId;
    if (rootId == null) {
      return null;
    }
    final node = _getMessageIndexNodeAt(rootId, _nowSeconds());
    if (node == null) {
      throw FormatException('root node ${rootId.toHex()} is missing');
    }
    return node;
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    _requireOpen();
    return _getMessageIndexNodeAt(id, _nowSeconds());
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    _requireOpen();
    if (ids.isEmpty) {
      return const <SyncBlob?>[];
    }
    final now = _nowSeconds();
    final out = <SyncBlob?>[];
    for (final id in ids) {
      final rows = _db.select(
        '''
SELECT blob_id, blob
FROM blobs
WHERE blob_id = ? AND expires_at > ?;
''',
        <Object?>[id.toBytes(), now],
      );
      if (rows.isEmpty) {
        out.add(null);
        continue;
      }
      final rawId = SyncBlobId(_asBytes(rows.first['blob_id'], 'blob_id'));
      if (rawId != id) {
        throw FormatException(
          'blob id mismatch, got ${rawId.toHex()} want ${id.toHex()}',
        );
      }
      out.add(
        SyncBlob(
          id: id,
          payload: _asBytes(rows.first['blob'], 'blob'),
        ),
      );
    }
    return out;
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    _requireOpen();
    final encrypted = encryptedMessageFromPowEnvelope(blob.payload);
    final expiresAt = _requireUint32(encrypted.expiresTime, 'expires_at');
    final now = _nowSeconds();
    final leaf = MessageIndexNode.leaf(
      MessageIndexLeaf(syncBlobId: blob.id, ttl: expiresAt),
    );
    final leafId = leaf.hash();

    _db.execute('BEGIN;');
    try {
      _db.execute(
        '''
INSERT INTO blobs(blob_id, expires_at, leaf_node_id, blob)
VALUES(?, ?, ?, ?)
ON CONFLICT(blob_id) DO NOTHING;
''',
        <Object?>[
          blob.id.toBytes(),
          expiresAt,
          leafId.toBytes(),
          Uint8List.fromList(blob.payload),
        ],
      );

      final root = _loadRootTreeForInsert(now);
      final nextRoot = root.add(blob.id.toHex(), expiresAt);
      if (nextRoot.hash != root.hash) {
        final branches = nextRoot.collectBranches();
        for (final branch in branches) {
          _insertBranch(branch);
        }
        _deleteBranchesExcept(branches.map((node) => node.hash).toSet());
      }
      _db.execute('COMMIT;');
      _rootId = nextRoot.hash;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {
    if (_closed) {
      return;
    }
    _closed = true;
    _db.dispose();
  }

  void _initSchema() {
    _db.execute(queryCreateFileBlobsTable);
    _db.execute(queryCreateFileBranchesTable);
  }

  void _collectExpired() {
    final now = _nowSeconds();
    _db.execute(
      '''
DELETE FROM blobs
WHERE expires_at < ?;
''',
      <Object?>[now],
    );
    _db.execute(
      '''
DELETE FROM branches
WHERE max_expires_at < ?;
''',
      <Object?>[now],
    );
  }

  MessageIndexNodeId? _findLiveRootId() {
    final rows = _db.select(
      '''
SELECT branch_id, prefix
FROM branches
WHERE max_expires_at > ?
ORDER BY length(prefix), prefix
LIMIT 1;
''',
      <Object?>[_nowSeconds()],
    );
    if (rows.isEmpty) {
      return null;
    }
    return MessageIndexNodeId(_asBytes(rows.first['branch_id'], 'branch_id'));
  }

  MessageIndexNode? _getMessageIndexNodeAt(MessageIndexNodeId id, int now) {
    final branch = _loadBranchNode(id, now);
    if (branch != null) {
      return branch;
    }
    return _loadLeafNode(id, now);
  }

  MessageIndexNode? _loadBranchNode(MessageIndexNodeId id, int now) {
    final rows = _db.select(
      '''
SELECT prefix, children_count, min_expires_at, max_expires_at, children_hashes
FROM branches
WHERE branch_id = ? AND max_expires_at > ?;
''',
      <Object?>[id.toBytes(), now],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    final node = MessageIndexNode.branch(
      MessageIndexBranch(
        prefix: _asString(row['prefix'], 'prefix'),
        childrenCount: _requireUint32(
          _asInt(row['children_count'], 'children_count'),
          'children_count',
        ),
        minTtl: _requireUint32(
          _asInt(row['min_expires_at'], 'min_expires_at'),
          'min_expires_at',
        ),
        maxTtl: _requireUint32(
          _asInt(row['max_expires_at'], 'max_expires_at'),
          'max_expires_at',
        ),
        childrenIds: _decodeChildrenHashes(
          _asBytes(row['children_hashes'], 'children_hashes'),
        ),
      ),
    );
    node.validate();
    final hash = node.hash();
    if (hash != id) {
      throw FormatException(
        'branch hash mismatch, got ${hash.toHex()} want ${id.toHex()}',
      );
    }
    return node;
  }

  MessageIndexNode? _loadLeafNode(MessageIndexNodeId id, int now) {
    final rows = _db.select(
      '''
SELECT blob_id, expires_at
FROM blobs
WHERE leaf_node_id = ? AND expires_at > ?;
''',
      <Object?>[id.toBytes(), now],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    final node = MessageIndexNode.leaf(
      MessageIndexLeaf(
        syncBlobId: SyncBlobId(_asBytes(row['blob_id'], 'blob_id')),
        ttl: _requireUint32(
            _asInt(row['expires_at'], 'expires_at'), 'expires_at'),
      ),
    );
    node.validate();
    final hash = node.hash();
    if (hash != id) {
      throw FormatException(
        'leaf hash mismatch, got ${hash.toHex()} want ${id.toHex()}',
      );
    }
    return node;
  }

  _FileIndexNode _loadRootTreeForInsert(int now) {
    final rootId = _rootId;
    if (rootId == null) {
      return _FileIndexNode.emptyBranch();
    }
    final root = _loadTreeNode(rootId, now);
    if (root == null) {
      throw FormatException('root node ${rootId.toHex()} is missing');
    }
    return root;
  }

  _FileIndexNode? _loadTreeNode(MessageIndexNodeId id, int now) {
    final branch = _loadBranchNode(id, now);
    if (branch != null) {
      final children = <_FileIndexNode?>[];
      for (final childId in branch.branch!.childrenIds) {
        if (childId == null) {
          children.add(null);
          continue;
        }
        final child = _loadTreeNode(childId, now);
        if (child == null) {
          throw FormatException(
              'message index child ${childId.toHex()} is missing');
        }
        children.add(child);
      }
      return _FileIndexNode.branch(branch.branch!.prefix, children);
    }

    final leaf = _loadLeafNode(id, now);
    if (leaf == null) {
      return null;
    }
    return _FileIndexNode.leaf(
      leaf.leaf!.syncBlobId.toHex(),
      leaf.leaf!.ttl,
    );
  }

  void _insertBranch(_FileIndexNode node) {
    if (node.isLeaf) {
      return;
    }
    _db.execute(
      '''
INSERT INTO branches(
  branch_id, prefix, children_count, min_expires_at, max_expires_at, children_hashes
)
VALUES(?, ?, ?, ?, ?, ?)
ON CONFLICT(branch_id) DO NOTHING;
''',
      <Object?>[
        node.hash.toBytes(),
        node.prefix,
        node.childrenCount,
        node.minChildTtl,
        node.maxChildTtl,
        _encodeChildrenHashes(node.children),
      ],
    );
  }

  void _deleteBranchesExcept(Set<MessageIndexNodeId> keep) {
    if (keep.isEmpty) {
      _db.execute('DELETE FROM branches;');
      return;
    }
    final placeholders = List<String>.filled(keep.length, '?').join(',');
    _db.execute(
      'DELETE FROM branches WHERE branch_id NOT IN ($placeholders);',
      keep.map((id) => id.toBytes()).toList(growable: false),
    );
  }

  int _nowSeconds() => unixSeconds(_nowUtc());

  void _requireOpen() {
    if (_closed) {
      throw StateError('file sync source is closed');
    }
  }
}

final class NormalizedFileSyncSource {
  const NormalizedFileSyncSource({required this.id, required this.path});

  final String id;
  final String path;
}

NormalizedFileSyncSource normalizeFileSyncSourceUpstream(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('sync source upstream URL must not be empty');
  }
  final parsed = Uri.parse(trimmed);
  if (parsed.scheme.isEmpty) {
    throw const FormatException('sync source upstream URL must include scheme');
  }
  if (parsed.scheme != 'file') {
    throw const FormatException('sync source upstream URL scheme must be file');
  }
  if (parsed.userInfo.isNotEmpty) {
    throw const FormatException(
      'sync source upstream URL must not include user credentials',
    );
  }
  if (parsed.host.isNotEmpty && parsed.host != 'localhost') {
    throw const FormatException(
      'sync source upstream URL host must be empty or localhost',
    );
  }
  if (parsed.hasQuery) {
    throw const FormatException(
      'sync source upstream URL must not include query parameters',
    );
  }
  if (parsed.hasFragment) {
    throw const FormatException(
      'sync source upstream URL must not include fragment',
    );
  }

  if (parsed.path.isEmpty) {
    throw const FormatException(
      'sync source upstream URL must include absolute file path',
    );
  }
  final cleanPath = _cleanAbsolutePath(Uri.decodeComponent(parsed.path));
  if (cleanPath.contains('?') || cleanPath.contains('#')) {
    throw const FormatException(
      "sync source URL path must not include reserved characters '?' or '#'",
    );
  }
  final type = FileSystemEntity.typeSync(cleanPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    throw const FormatException('sync source sqlite path must point to a file');
  }
  if (type == FileSystemEntityType.link) {
    throw const FormatException(
        'sync source sqlite path must not be a symlink');
  }
  if (type != FileSystemEntityType.file) {
    throw const FormatException(
      'sync source sqlite path must point to a regular file',
    );
  }
  _validateSQLiteFileHeaderOrEmpty(cleanPath);
  return NormalizedFileSyncSource(
    id: Uri.file(cleanPath).toString(),
    path: cleanPath,
  );
}

SyncTransportServer newFileProtocolServer({UtcNow? nowUtc}) {
  return ProtocolSyncTransportServer(
    protocolName: fileTransportProtocolName,
    flags: ServerFlags(
      supportsExternalStorageDiscovery ? serverFlagDiscovery : serverFlagNone,
    ),
    peerMatch: isFilePeerId,
    createPeerSource: (id) => FileSyncSourceClient(id, nowUtc: nowUtc),
    discoverPeers: findExternalStorageFiles,
  );
}

void _validateSQLiteFileHeaderOrEmpty(String path) {
  final file = File(path);
  final length = file.lengthSync();
  if (length == 0) {
    return;
  }
  if (length < sqliteHeaderMagicBytes.length) {
    throw const FormatException('sync source file is not a sqlite3 database');
  }
  final handle = file.openSync();
  try {
    final header = handle.readSync(sqliteHeaderMagicBytes.length);
    if (!bytesEqual(Uint8List.fromList(header),
        Uint8List.fromList(sqliteHeaderMagicBytes))) {
      throw const FormatException('sync source file is not a sqlite3 database');
    }
  } finally {
    handle.closeSync();
  }
}

String _cleanAbsolutePath(String path) {
  if (!path.startsWith('/')) {
    throw const FormatException(
      'sync source upstream URL must include absolute file path',
    );
  }
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') {
      continue;
    }
    if (part == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      }
      continue;
    }
    parts.add(part);
  }
  return '/${parts.join('/')}';
}

List<MessageIndexNodeId?> _decodeChildrenHashes(Uint8List raw) {
  if (raw.isEmpty) {
    return List<MessageIndexNodeId?>.filled(messageIndexChildSlotCount, null);
  }
  if (raw.length != childrenHashesEncodedByteLength) {
    throw FormatException(
      'children_hashes must be $childrenHashesEncodedByteLength bytes, got ${raw.length}',
    );
  }
  final out = <MessageIndexNodeId?>[];
  for (var slot = 0; slot < messageIndexChildSlotCount; slot++) {
    final start = slot * messageIndexNodeIdSize;
    final bytes =
        Uint8List.fromList(raw.sublist(start, start + messageIndexNodeIdSize));
    if (_allZeroBytes(bytes)) {
      out.add(null);
    } else {
      out.add(MessageIndexNodeId(bytes));
    }
  }
  return out;
}

Uint8List _encodeChildrenHashes(List<_FileIndexNode?> children) {
  final out = Uint8List(childrenHashesEncodedByteLength);
  for (var slot = 0; slot < children.length; slot++) {
    final child = children[slot];
    if (child == null) {
      continue;
    }
    out.setRange(
      slot * messageIndexNodeIdSize,
      (slot + 1) * messageIndexNodeIdSize,
      child.hash.toBytes(),
    );
  }
  return out;
}

bool _allZeroBytes(Uint8List bytes) {
  for (final byte in bytes) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

String _asString(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be string');
  }
  return value;
}

int _asInt(Object? value, String label) {
  if (value is int) {
    return value;
  }
  if (value is BigInt) {
    return value.toInt();
  }
  throw FormatException('$label must be integer');
}

Uint8List _asBytes(Object? value, String label) {
  if (value is Uint8List) {
    return Uint8List.fromList(value);
  }
  if (value is List<int>) {
    return Uint8List.fromList(value);
  }
  throw FormatException('$label must be bytes');
}

int _requireUint32(int value, String label) {
  if (value < 0 || value > 0xffffffff) {
    throw FormatException('$label must fit uint32, got $value');
  }
  return value;
}

enum _FileIndexNodeKind { branch, leaf }

final class _FileIndexNode {
  _FileIndexNode._({
    required this.kind,
    required this.prefix,
    required this.leafTtl,
    required this.childrenCount,
    required this.minChildTtl,
    required this.maxChildTtl,
    required List<_FileIndexNode?> children,
  })  : children = List<_FileIndexNode?>.unmodifiable(children),
        hash = _calculateHash(kind, prefix, children);

  factory _FileIndexNode.emptyBranch() {
    return _FileIndexNode._(
      kind: _FileIndexNodeKind.branch,
      prefix: '',
      leafTtl: 0,
      childrenCount: 0,
      minChildTtl: 0,
      maxChildTtl: 0,
      children: List<_FileIndexNode?>.filled(messageIndexChildSlotCount, null),
    );
  }

  factory _FileIndexNode.leaf(String prefix, int ttl) {
    _validatePrefix(prefix);
    return _FileIndexNode._(
      kind: _FileIndexNodeKind.leaf,
      prefix: prefix,
      leafTtl: ttl,
      childrenCount: 0,
      minChildTtl: 0,
      maxChildTtl: 0,
      children: List<_FileIndexNode?>.filled(messageIndexChildSlotCount, null),
    );
  }

  factory _FileIndexNode.branch(
    String prefix,
    List<_FileIndexNode?> children,
  ) {
    _validatePrefix(prefix);
    var childrenCount = 0;
    var minChildTtl = 0;
    var maxChildTtl = 0;
    for (final child in children) {
      if (child == null) {
        continue;
      }
      childrenCount += child.childrenCountValue;
      minChildTtl = _minTtl(minChildTtl, child.minChildTtlValue);
      maxChildTtl = maxChildTtl > child.maxChildTtlValue
          ? maxChildTtl
          : child.maxChildTtlValue;
    }
    return _FileIndexNode._(
      kind: _FileIndexNodeKind.branch,
      prefix: prefix,
      leafTtl: 0,
      childrenCount: childrenCount,
      minChildTtl: minChildTtl,
      maxChildTtl: maxChildTtl,
      children: children,
    );
  }

  final _FileIndexNodeKind kind;
  final String prefix;
  final int leafTtl;
  final int childrenCount;
  final int minChildTtl;
  final int maxChildTtl;
  final List<_FileIndexNode?> children;
  final MessageIndexNodeId hash;

  bool get isLeaf => kind == _FileIndexNodeKind.leaf;

  int get childrenCountValue => isLeaf ? 1 : childrenCount;

  int get minChildTtlValue => isLeaf ? leafTtl : minChildTtl;

  int get maxChildTtlValue => isLeaf ? leafTtl : maxChildTtl;

  _FileIndexNode add(String nextPrefix, int ttl) {
    _validatePrefix(nextPrefix);
    final sharedLen = _sharedPrefixLen(prefix, nextPrefix);
    if (sharedLen == prefix.length) {
      if (isLeaf) {
        return this;
      }
      final index = _nibbleIndex(nextPrefix.codeUnitAt(sharedLen));
      final copiedChildren = List<_FileIndexNode?>.from(children);
      copiedChildren[index] = copiedChildren[index] == null
          ? _FileIndexNode.leaf(nextPrefix, ttl)
          : copiedChildren[index]!.add(nextPrefix, ttl);
      return _FileIndexNode.branch(prefix, copiedChildren);
    }

    final newChild = _FileIndexNode.leaf(nextPrefix, ttl);
    final nextChildren = List<_FileIndexNode?>.filled(
      messageIndexChildSlotCount,
      null,
    );
    nextChildren[_nibbleIndex(nextPrefix.codeUnitAt(sharedLen))] = newChild;
    nextChildren[_nibbleIndex(prefix.codeUnitAt(sharedLen))] = this;
    return _FileIndexNode.branch(
        nextPrefix.substring(0, sharedLen), nextChildren);
  }

  List<_FileIndexNode> collectBranches() {
    final out = <_FileIndexNode>[];
    _collectBranches(out);
    return out;
  }

  void _collectBranches(List<_FileIndexNode> out) {
    if (isLeaf) {
      return;
    }
    for (final child in children) {
      child?._collectBranches(out);
    }
    out.add(this);
  }

  static MessageIndexNodeId _calculateHash(
    _FileIndexNodeKind kind,
    String prefix,
    List<_FileIndexNode?> children,
  ) {
    if (kind == _FileIndexNodeKind.leaf) {
      return MessageIndexNodeId(
        sha256Bytes(SyncBlobId.parseHex(prefix).toBytes()),
      );
    }
    final chunks = <int>[];
    for (final child in children) {
      if (child != null) {
        chunks.addAll(child.hash.toBytes());
      }
    }
    return MessageIndexNodeId(sha256Bytes(Uint8List.fromList(chunks)));
  }
}

int _minTtl(int a, int b) => a == 0 || b < a ? b : a;

int _sharedPrefixLen(String a, String b) {
  var n = a.length;
  if (b.length < n) {
    n = b.length;
  }
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

int _nibbleIndex(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  throw FormatException('invalid hex nibble ${String.fromCharCode(codeUnit)}');
}

void _validatePrefix(String prefix) {
  if (!streamHexPrefixRe.hasMatch(prefix)) {
    throw const FormatException(
      'nibble string must contain only lowercase hex chars [0-9a-f]',
    );
  }
  if (prefix.length > syncBlobIdSize * 2) {
    throw FormatException(
      'prefix must be at most ${syncBlobIdSize * 2} nibbles',
    );
  }
}
