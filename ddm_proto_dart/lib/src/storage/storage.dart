import 'dart:io';

import 'package:ddm_proto_dart/src/storage/accounts.dart';
import 'package:ddm_proto_dart/src/storage/configuration.dart';
import 'package:ddm_proto_dart/src/storage/contacts.dart';
import 'package:ddm_proto_dart/src/storage/messages.dart';
import 'package:ddm_proto_dart/src/storage/migrations.dart';
import 'package:ddm_proto_dart/src/storage/p2p_identity.dart';
import 'package:ddm_proto_dart/src/storage/peers.dart';
import 'package:ddm_proto_dart/src/storage/storage_clock.dart';
import 'package:ddm_proto_dart/src/storage/sync_blobs.dart';
import 'package:sqlite3/sqlite3.dart';

export 'package:ddm_proto_dart/src/storage/accounts.dart';
export 'package:ddm_proto_dart/src/storage/configuration.dart';
export 'package:ddm_proto_dart/src/storage/contacts.dart';
export 'package:ddm_proto_dart/src/storage/messages.dart';
export 'package:ddm_proto_dart/src/storage/p2p_identity.dart';
export 'package:ddm_proto_dart/src/storage/peers.dart';
export 'package:ddm_proto_dart/src/storage/storage_clock.dart';
export 'package:ddm_proto_dart/src/storage/sync_blobs.dart';

final class DdmSqliteStorage {
  DdmSqliteStorage._(this._db, UtcNow nowUtc)
      : accounts = AccountsRepository(_db, nowUtc),
        contacts = ContactsRepository(_db, nowUtc),
        configs = ConfigRepository(_db, nowUtc),
        messages = MessagesRepository(_db),
        syncBlobs = SyncBlobsRepository(_db),
        p2pIdentity = P2pIdentityRepository(_db, nowUtc),
        peers = PeersRepository(_db);

  final Database _db;
  bool _closed = false;

  final AccountsRepository accounts;
  final ContactsRepository contacts;
  final ConfigRepository configs;
  final MessagesRepository messages;
  final SyncBlobsRepository syncBlobs;
  final P2pIdentityRepository p2pIdentity;
  final PeersRepository peers;

  static DdmSqliteStorage open(String dbPath, {UtcNow? nowUtc}) {
    final dbFile = File(dbPath);
    dbFile.parent.createSync(recursive: true);

    final db = sqlite3.open(dbPath);
    final now = nowUtc ?? defaultStorageUtcNow;
    try {
      runStorageMigrations(db);
      return DdmSqliteStorage._(db, now);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _db.dispose();
  }
}
