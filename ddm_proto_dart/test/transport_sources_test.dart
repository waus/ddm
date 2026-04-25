import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  final fixturesRoot = Directory('test/fixtures/go_v1');

  test('HTTP transport parses Go fixture JSON nodes', () {
    final rootJson = _readJson(fixturesRoot, 'http_sync_root.json');
    final nodeJson = _readJson(fixturesRoot, 'http_sync_node.json');

    final rootMap = _requiredMap(rootJson['root'], 'root');
    final nodeMap = _requiredMap(nodeJson['node'], 'node');
    final root = messageIndexNodeFromHttp(rootMap);
    final node = messageIndexNodeFromHttp(nodeMap);

    expect(root.hash().toHex(), rootMap['hash']);
    expect(root.branch, isNotNull);
    expect(root.branch!.prefix, 'a3');
    expect(node.hash().toHex(), nodeMap['hash']);
    expect(node.leaf, isNotNull);
  });

  test('HTTP client talks to live Dart sync source server', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final fixture = _buildPowBlob(
      streamId: const StreamId(0x01020304),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 1))),
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    );
    final source = _MemorySyncSource(
      index: BlobIndex(nowUtc: () => now)..add(fixture.id, fixture.expiresAt),
      blobs: <SyncBlobId, SyncBlob>{fixture.id: fixture.blob},
      configs: <ConfigRecord>[
        ConfigRecord(version: 1, payload: Uint8List.fromList(<int>[9])),
      ],
    );
    final server = HttpSyncSourceServer(listenAddress: '127.0.0.1:0');
    await server.start(source);
    addTearDown(server.stop);

    final client = HttpSyncSourceClient(server.boundUri.toString());
    addTearDown(client.stop);

    final configs = await client.getConfigs();
    expect(configs.single.version, 1);
    expect(configs.single.payload, <int>[9]);

    final root = await client.getMessageIndexRoot();
    expect(root, isNotNull);
    expect(root!.hash(), source.index.latestRoot().id);

    final blobs = await client.getSyncBlobs(<SyncBlobId>[
      fixture.id,
      SyncBlobId.parseHex('ab' * syncBlobIdSize),
      fixture.id,
    ]);
    expect(blobs.length, 3);
    expect(blobs[0]!.payload, fixture.blob.payload);
    expect(blobs[1], isNull);
    expect(blobs[2]!.id, fixture.id);

    final pushed = _buildPowBlob(
      streamId: const StreamId(0x05060708),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 2))),
      payload: Uint8List.fromList(<int>[4, 5, 6]),
    );
    await client.push(pushed.blob);
    expect(source.pushed.single.id, pushed.id);
  });

  test('HTTP client classifies unavailable source separately', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final uri = Uri(
      scheme: 'http',
      host: server.address.host,
      port: server.port,
      path: '/',
    );
    await server.close(force: true);

    final client = HttpSyncSourceClient(uri.toString());
    addTearDown(client.stop);

    await expectLater(
      client.getMessageIndexRoot(),
      throwsA(
        isA<SyncSourceException>().having(
          (error) => error.kind,
          'kind',
          SyncSourceErrorKind.unavailable,
        ),
      ),
    );
  });

  test('HTTP client classifies malformed response as invalid response',
      () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      await for (final request in server) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.response.write('{"root":');
        await request.response.close();
      }
    }());

    final client = HttpSyncSourceClient(
      Uri(
        scheme: 'http',
        host: server.address.host,
        port: server.port,
        path: '/',
      ).toString(),
    );
    addTearDown(client.stop);

    await expectLater(
      client.getMessageIndexRoot(),
      throwsA(
        isA<SyncSourceException>().having(
          (error) => error.kind,
          'kind',
          SyncSourceErrorKind.invalidResponse,
        ),
      ),
    );
  });

  test('file source reads Go-compatible SQLite export rows', () async {
    final dir = Directory.systemTemp.createTempSync('ddm-file-source-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dbPath = '${dir.path}/sync-source.sqlite';
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final db = sqlite3.open(dbPath);
    try {
      _createFileSourceSchema(db);
      final ttlA = _unix(now.add(const Duration(hours: 2)));
      final ttlB = _unix(now.add(const Duration(hours: 3)));
      final blobIdA = _makeTestBlobId(0x01);
      final blobIdB = _makeTestBlobId(0x10);
      final leafA = MessageIndexNode.leaf(
        MessageIndexLeaf(syncBlobId: blobIdA, ttl: ttlA),
      );
      final leafB = MessageIndexNode.leaf(
        MessageIndexLeaf(syncBlobId: blobIdB, ttl: ttlB),
      );
      final children = List<MessageIndexNodeId?>.filled(
        messageIndexChildSlotCount,
        null,
      );
      children[0] = leafA.hash();
      children[1] = leafB.hash();
      final branch = MessageIndexNode.branch(
        MessageIndexBranch(
          prefix: '',
          childrenCount: 2,
          minTtl: ttlA,
          maxTtl: ttlB,
          childrenIds: children,
        ),
      );
      db.execute(
        'INSERT INTO blobs(blob_id, expires_at, leaf_node_id, blob) VALUES(?, ?, ?, ?);',
        <Object?>[
          blobIdA.toBytes(),
          ttlA,
          leafA.hash().toBytes(),
          Uint8List.fromList(<int>[1])
        ],
      );
      db.execute(
        'INSERT INTO blobs(blob_id, expires_at, leaf_node_id, blob) VALUES(?, ?, ?, ?);',
        <Object?>[
          blobIdB.toBytes(),
          ttlB,
          leafB.hash().toBytes(),
          Uint8List.fromList(<int>[2])
        ],
      );
      db.execute(
        'INSERT INTO branches(branch_id, prefix, children_count, min_expires_at, max_expires_at, children_hashes) VALUES(?, ?, ?, ?, ?, ?);',
        <Object?>[
          branch.hash().toBytes(),
          '',
          2,
          ttlA,
          ttlB,
          _encodeChildrenHashes(children),
        ],
      );
    } finally {
      db.dispose();
    }

    final source = FileSyncSourceClient(_fileUri(dbPath), nowUtc: () => now);
    addTearDown(source.stop);

    expect(await source.getConfigs(), isEmpty);
    final root = await source.getMessageIndexRoot();
    expect(root, isNotNull);
    expect(root!.branch!.childrenCount, 2);
    final blobs = await source.getSyncBlobs(<SyncBlobId>[
      _makeTestBlobId(0x01),
      _makeTestBlobId(0x77),
      _makeTestBlobId(0x10),
      _makeTestBlobId(0x01),
    ]);
    expect(blobs.length, 4);
    expect(blobs[0]!.payload, <int>[1]);
    expect(blobs[1], isNull);
    expect(blobs[2]!.payload, <int>[2]);
    expect(blobs[3]!.id, _makeTestBlobId(0x01));
  });

  test('file source push stores blobs and rewrites branch tree', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final dbPath = _createEmptyFileSourcePathWithCleanup();
    final source = FileSyncSourceClient(_fileUri(dbPath), nowUtc: () => now);
    addTearDown(source.stop);

    final blobA = _buildPowBlob(
      streamId: const StreamId(0x01000000),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 2))),
      payload: Uint8List.fromList(<int>[1]),
    );
    final blobB = _buildPowBlob(
      streamId: const StreamId(0x10000000),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 3))),
      payload: Uint8List.fromList(<int>[2]),
    );

    await source.push(blobA.blob);
    expect(_countRows(dbPath, 'blobs'), 1);
    expect(_countRows(dbPath, 'branches'), 1);

    await source.push(blobB.blob);
    expect(_countRows(dbPath, 'blobs'), 2);
    expect(_countRows(dbPath, 'branches'), 1);

    final root = await source.getMessageIndexRoot();
    expect(root!.branch!.prefix, '');
    expect(root.branch!.childrenCount, 2);
    expect(
        (await source.getSyncBlobs(<SyncBlobId>[blobA.id, blobB.id]))
            .whereType<SyncBlob>()
            .length,
        2);

    await source.push(blobB.blob);
    expect(_countRows(dbPath, 'blobs'), 2);
    expect(_countRows(dbPath, 'branches'), 1);
  });

  test('file source push splits diverging prefixes', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final dbPath = _createEmptyFileSourcePathWithCleanup();
    final source = FileSyncSourceClient(_fileUri(dbPath), nowUtc: () => now);
    addTearDown(source.stop);

    final baseA = _buildPowBlob(
      streamId: const StreamId(0x01000000),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 2))),
      payload: Uint8List.fromList(<int>[1]),
    );
    final baseB = _buildPowBlob(
      streamId: const StreamId(0x02000000),
      ttl: 3600,
      expiresTime: _unix(now.add(const Duration(hours: 3))),
      payload: Uint8List.fromList(<int>[2]),
    );
    final blobA =
        SyncBlob(id: _makeTestBlobId(0x41), payload: baseA.blob.payload);
    final blobB =
        SyncBlob(id: _makeTestBlobId(0x42), payload: baseB.blob.payload);

    await source.push(blobA);
    final oldRoot = await source.getMessageIndexRoot();
    await source.push(blobB);

    expect(_countRows(dbPath, 'blobs'), 2);
    expect(_countRows(dbPath, 'branches'), 2);
    expect(_countBranchById(dbPath, oldRoot!.hash()), 0);

    final root = await source.getMessageIndexRoot();
    expect(root!.branch!.prefix, '');
    final splitBranchId = root.branch!.childrenIds[4];
    expect(splitBranchId, isNotNull);
    final split = await source.getMessageIndexNode(splitBranchId!);
    expect(split!.branch!.prefix, '4');
    expect(split.branch!.childrenCount, 2);
  });

  test('file source rejects symlink and non-SQLite paths', () {
    final dir = Directory.systemTemp.createTempSync('ddm-file-source-invalid-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final target = '${dir.path}/source.sqlite';
    File(target).writeAsBytesSync(Uint8List(0));
    final link = '${dir.path}/source-link.sqlite';
    Link(link).createSync(target);
    expect(() => FileSyncSourceClient(_fileUri(link)), throwsFormatException);

    final textPath = '${dir.path}/not-sqlite.db';
    File(textPath).writeAsStringSync('not a sqlite database');
    expect(
        () => FileSyncSourceClient(_fileUri(textPath)), throwsFormatException);
  });

  test('file server exposes discovery only on supported desktop platforms',
      () async {
    final server = newFileProtocolServer();
    expect(
      server.flags.has(serverFlagDiscovery),
      supportsExternalStorageDiscovery,
    );
    expect(await server.discoverPeers(), isA<List<String>>());
  });
}

Map<String, Object?> _readJson(Directory root, String name) {
  final decoded = jsonDecode(File('${root.path}/$name').readAsStringSync());
  return _requiredMap(decoded, name);
}

Map<String, Object?> _requiredMap(Object? value, String label) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  throw FormatException('$label must be object');
}

void _createFileSourceSchema(Database db) {
  db.execute(queryCreateFileBlobsTable);
  db.execute(queryCreateFileBranchesTable);
}

String _createEmptyFileSourcePathWithCleanup() {
  final dir = Directory.systemTemp.createTempSync('ddm-file-source-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final path = '${dir.path}/sync-source.sqlite';
  File(path).writeAsBytesSync(Uint8List(0));
  return path;
}

({SyncBlobId id, SyncBlob blob, int expiresAt}) _buildPowBlob({
  required StreamId streamId,
  required int ttl,
  required int expiresTime,
  required Uint8List payload,
}) {
  final encrypted = EncryptedMessage(
    version: encryptedMessageVersionV1,
    ttl: ttl,
    expiresTime: expiresTime,
    streamNumber: streamId,
    payload: payload,
  );
  final envelope = PowEnvelope(
    version: powEnvelopeVersionV1,
    algorithm: PowAlgorithm.vdfRsa,
    y: Uint8List(powProofComponentSize),
    pi: Uint8List(powProofComponentSize),
    object: encrypted.toBytes(),
  );
  final bytes = envelope.toBytes();
  final id = deriveSyncBlobId(streamId: streamId, blobPayload: bytes);
  return (
    id: id,
    blob: SyncBlob(id: id, payload: bytes),
    expiresAt: expiresTime
  );
}

SyncBlobId _makeTestBlobId(int seed) {
  return SyncBlobId(
    Uint8List.fromList(
      List<int>.generate(syncBlobIdSize, (index) => (seed + index) & 0xff),
    ),
  );
}

Uint8List _encodeChildrenHashes(List<MessageIndexNodeId?> children) {
  final out = Uint8List(childrenHashesEncodedByteLength);
  for (var slot = 0; slot < children.length; slot++) {
    final child = children[slot];
    if (child == null) {
      continue;
    }
    out.setRange(
      slot * messageIndexNodeIdSize,
      (slot + 1) * messageIndexNodeIdSize,
      child.toBytes(),
    );
  }
  return out;
}

int _countRows(String dbPath, String table) {
  final db = sqlite3.open(dbPath);
  try {
    return db.select('SELECT COUNT(*) AS n FROM $table;').first['n'] as int;
  } finally {
    db.dispose();
  }
}

int _countBranchById(String dbPath, MessageIndexNodeId id) {
  final db = sqlite3.open(dbPath);
  try {
    return db.select(
      'SELECT COUNT(*) AS n FROM branches WHERE branch_id = ?;',
      <Object?>[id.toBytes()],
    ).first['n'] as int;
  } finally {
    db.dispose();
  }
}

String _fileUri(String path) => Uri.file(path).toString();

int _unix(DateTime value) => value.toUtc().millisecondsSinceEpoch ~/ 1000;

final class _MemorySyncSource implements SyncSource {
  _MemorySyncSource({
    required this.index,
    Map<SyncBlobId, SyncBlob>? blobs,
    List<ConfigRecord>? configs,
  })  : _blobs = blobs ?? <SyncBlobId, SyncBlob>{},
        _configs = configs ?? const <ConfigRecord>[];

  final BlobIndex index;
  final Map<SyncBlobId, SyncBlob> _blobs;
  final List<ConfigRecord> _configs;
  final List<SyncBlob> pushed = <SyncBlob>[];

  @override
  String get id => 'memory';

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async => _configs;

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    return index.latestRoot().node;
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    return index.node(id);
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    return ids.map((id) => _blobs[id]).toList(growable: false);
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    pushed.add(blob);
    _blobs[blob.id] = blob;
    index.add(
        blob.id, encryptedMessageFromPowEnvelope(blob.payload).expiresTime);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {}
}
