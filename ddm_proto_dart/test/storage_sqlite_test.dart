import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

void main() {
  test('open seeds default config record', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    final records = storage.configs.listConfigRecords();
    expect(records.length, 1);

    final seeded = records.first;
    final expected = ConfigRepository.defaultConfigRecord;
    expect(seeded.seqNo, expected.seqNo);
    expect(seeded.activeFrom, expected.activeFrom);
    expect(seeded.record.version, expected.record.version);
    expect(seeded.record.payload, expected.record.payload);
  });

  test('account create enforces case-insensitive duplicate names', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    storage.accounts.createAccount(
      AccountInsert(
        name: 'Alice',
        address: 'addr1',
        publicKey: Uint8List.fromList(<int>[1, 2, 3]),
        privateKey: Uint8List.fromList(<int>[4, 5, 6]),
        streamId: const StreamId(0x12345678),
      ),
    );

    expect(
      () => storage.accounts.createAccount(
        AccountInsert(
          name: 'alice',
          address: 'addr2',
          publicKey: Uint8List.fromList(<int>[7, 8, 9]),
          privateKey: Uint8List.fromList(<int>[10, 11, 12]),
          streamId: const StreamId(0x12345678),
        ),
      ),
      throwsA(isA<AccountNameExistsException>()),
    );
  });

  test('mailbox queries and counts match sender and recipient filters', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    final now = DateTime.utc(2026, 3, 4, 5, 6, 7);
    final senderA = _testAddress(0x10).toText();
    final senderB = _testAddress(0x20).toText();
    final recipientX = _testAddress(0x30).toText();
    final recipientY = _testAddress(0x40).toText();
    final first = MessageRecord(
      id: MessageId(_bytes16(0x10)),
      senderAddress: senderA,
      recipientAddress: recipientX,
      createdAt: now,
      updatedAt: now.add(const Duration(seconds: 10)),
      expiresAt: now.add(const Duration(hours: 1)),
      isRead: false,
      ttlSeconds: 3600,
      payloadType: MessageType.plain,
      payload: Uint8List.fromList(<int>[1]),
      state: messageStateCreated,
      reliableDelivery: true,
    );
    final second = MessageRecord(
      id: MessageId(_bytes16(0x20)),
      senderAddress: senderA,
      recipientAddress: recipientY,
      createdAt: now.add(const Duration(seconds: 1)),
      expiresAt: now.add(const Duration(hours: 2)),
      isRead: true,
      ttlSeconds: 3600,
      payloadType: MessageType.plain,
      payload: Uint8List.fromList(<int>[2]),
      state: messageStateDelivered,
      reliableDelivery: false,
    );
    final third = MessageRecord(
      id: MessageId(_bytes16(0x30)),
      senderAddress: senderB,
      recipientAddress: recipientX,
      createdAt: now.add(const Duration(seconds: 2)),
      expiresAt: now.add(const Duration(hours: 3)),
      isRead: false,
      ttlSeconds: 3600,
      payloadType: MessageType.plain,
      payload: Uint8List.fromList(<int>[3]),
      state: messageStateReceived,
      reliableDelivery: false,
    );

    storage.messages.insertMessage(first);
    storage.messages.insertMessage(second);
    storage.messages.insertMessage(third);

    final byRecipient = storage.messages.listMessagesByRecipientAddress(
      recipientX,
    );
    expect(byRecipient.length, 2);
    expect(byRecipient.first.id, first.id);
    expect(byRecipient.first.updatedAt, now.add(const Duration(seconds: 10)));
    expect(byRecipient.first.reliableDelivery, isTrue);
    expect(byRecipient.last.id, third.id);

    final bySender = storage.messages.listMessagesBySenderAddress(senderA);
    expect(bySender.length, 2);
    expect(bySender.first.id, first.id);
    expect(bySender.last.id, second.id);

    expect(storage.messages.countMessagesByRecipientAddress(recipientX), 2);
    expect(storage.messages.countMessagesBySenderAddress(senderA), 2);
  });

  test('sync blob dedup, index preload and expiry cleanup are preserved', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    final expiredId = _syncBlobId(streamPrefix: 0x11111111, seed: 0x41);
    final freshId = _syncBlobId(streamPrefix: 0x22222222, seed: 0x61);

    final firstInsert = storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: expiredId,
        blob: Uint8List.fromList('not-a-pow-envelope'.codeUnits),
        source: syncBlobSourceLocal,
        expiresAt: 100,
      ),
    );
    final secondInsert = storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: freshId,
        blob: Uint8List.fromList(<int>[9, 9, 9]),
        source: syncBlobSourceImported,
        expiresAt: 200,
      ),
    );
    final duplicateInsert = storage.syncBlobs.insertSyncBlob(
      SyncBlobRecord(
        blobId: expiredId,
        blob: Uint8List.fromList(<int>[1, 2, 3]),
        source: syncBlobSourceLocal,
        expiresAt: 300,
      ),
    );

    expect(firstInsert, isTrue);
    expect(secondInsert, isTrue);
    expect(duplicateInsert, isFalse);

    final indexRows = storage.syncBlobs.listSyncBlobIndexRecords();
    expect(indexRows.length, 2);

    final deleted = storage.syncBlobs.deleteExpiredSyncBlobs(150);
    expect(deleted, 1);
    expect(storage.syncBlobs.getSyncBlobById(expiredId), isNull);
    expect(storage.syncBlobs.getSyncBlobById(freshId), isNotNull);
  });

  test('upsert p2p private key overwrites previous value', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    expect(storage.p2pIdentity.getPrivateKey(), isNull);

    storage.p2pIdentity.upsertPrivateKey(
      Uint8List.fromList('first-private-key'.codeUnits),
    );
    expect(
      storage.p2pIdentity.getPrivateKey(),
      Uint8List.fromList('first-private-key'.codeUnits),
    );

    storage.p2pIdentity.upsertPrivateKey(
      Uint8List.fromList('second-private-key'.codeUnits),
    );
    expect(
      storage.p2pIdentity.getPrivateKey(),
      Uint8List.fromList('second-private-key'.codeUnits),
    );
  });

  test('peer upsert stores metadata and preserves created_at', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    final createdAt = DateTime.utc(2026, 3, 4, 5, 6, 7);
    final firstOnlineAt = createdAt.add(const Duration(minutes: 1));
    final secondOnlineAt = createdAt.add(const Duration(minutes: 2));

    storage.peers.upsertPeers(<PeerRecord>[
      PeerRecord(
        id: 'peer-a',
        createdAt: createdAt,
        lastOnlineAt: firstOnlineAt,
        rating: 1.25,
      ),
    ]);
    storage.peers.upsertPeers(<PeerRecord>[
      PeerRecord(
        id: 'peer-a',
        createdAt: createdAt.add(const Duration(hours: 1)),
        lastOnlineAt: secondOnlineAt,
        rating: 1.5,
      ),
    ]);

    final peers = storage.peers.listPeers();
    expect(peers.length, 1);
    expect(peers.first.id, 'peer-a');
    expect(peers.first.createdAt, createdAt);
    expect(peers.first.lastOnlineAt, secondOnlineAt);
    expect(peers.first.rating, 1.5);
  });

  test('peer cleanup removes only old online peers', () {
    final storage = _openStorage();
    addTearDown(storage.close);

    final now = DateTime.utc(2026, 3, 4, 5, 6, 7);
    storage.peers.upsertPeers(<PeerRecord>[
      PeerRecord(
        id: 'stale',
        createdAt: now.subtract(const Duration(hours: 72)),
        lastOnlineAt: now.subtract(const Duration(hours: 49)),
        rating: 1,
      ),
      PeerRecord(
        id: 'fresh',
        createdAt: now.subtract(const Duration(hours: 72)),
        lastOnlineAt: now.subtract(const Duration(hours: 47)),
        rating: 1,
      ),
    ]);

    final deleted = storage.peers.deletePeersLastOnlineBefore(
      now.subtract(const Duration(hours: 48)),
    );
    expect(deleted, 1);

    final peers = storage.peers.listPeers();
    expect(peers.map((peer) => peer.id), <String>['fresh']);
  });
}

DdmSqliteStorage _openStorage() {
  final dir = Directory.systemTemp.createTempSync('ddm-proto-storage-');
  final dbPath = '${dir.path}/$defaultFileName';
  return DdmSqliteStorage.open(dbPath);
}

Uint8List _bytes16(int seed) {
  final out = Uint8List(16);
  for (var i = 0; i < out.length; i++) {
    out[i] = (seed + i) & 0xff;
  }
  return out;
}

Address _testAddress(int seed) {
  final publicKey = Uint8List(32);
  for (var i = 0; i < publicKey.length; i++) {
    publicKey[i] = (seed + i) & 0xff;
  }
  return Address.newV1(publicKey);
}

SyncBlobId _syncBlobId({required int streamPrefix, required int seed}) {
  final out = Uint8List(syncBlobIdSize);
  out[0] = (streamPrefix >> 24) & 0xff;
  out[1] = (streamPrefix >> 16) & 0xff;
  out[2] = (streamPrefix >> 8) & 0xff;
  out[3] = streamPrefix & 0xff;
  for (var i = 4; i < out.length; i++) {
    out[i] = (seed + i) & 0xff;
  }
  return SyncBlobId(out);
}
