// ignore_for_file: file_names

import 'package:ddm_proto_dart/src/storage/migration.dart';

const StorageMigration migration0001Init = StorageMigration(
  number: 1,
  name: '0001_init',
  sql: '''
CREATE TABLE IF NOT EXISTS config (
  seqno INTEGER PRIMARY KEY,
  payload BLOB NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL COLLATE NOCASE UNIQUE,
  address TEXT NOT NULL UNIQUE,
  public_key BLOB NOT NULL,
  private_key BLOB NOT NULL,
  stream_id INTEGER NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_accounts_stream_id
ON accounts(stream_id);

CREATE TABLE IF NOT EXISTS messages (
  id BLOB PRIMARY KEY,
  sender_address TEXT NOT NULL,
  recipient_address TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  is_read INTEGER NOT NULL,
  ttl_seconds INTEGER NOT NULL,
  payload_type TEXT NOT NULL,
  payload BLOB NOT NULL,
  state TEXT NOT NULL,
  reliable_delivery INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_state
ON messages(state);

CREATE INDEX IF NOT EXISTS idx_messages_created_at
ON messages(created_at);

CREATE INDEX IF NOT EXISTS idx_messages_updated_at
ON messages(updated_at);

CREATE TABLE IF NOT EXISTS contacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  address TEXT NOT NULL,
  account TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  approved INTEGER NOT NULL,
  last_delivery_time TEXT NOT NULL DEFAULT '',
  trust INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(address, account)
);

CREATE INDEX IF NOT EXISTS idx_contacts_account
ON contacts(account);

CREATE INDEX IF NOT EXISTS idx_contacts_updated_at
ON contacts(updated_at);

CREATE TABLE IF NOT EXISTS sync_blobs (
  blob_id BLOB PRIMARY KEY,
  blob BLOB NOT NULL,
  source TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sync_blobs_source
ON sync_blobs(source);

CREATE TABLE IF NOT EXISTS p2p_identity (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  private_key BLOB NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS peers (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  last_online_at TEXT,
  rating REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_peers_last_online_at
ON peers(last_online_at);

CREATE INDEX IF NOT EXISTS idx_peers_rating
ON peers(rating);

INSERT INTO config(seqno, payload, created_at)
SELECT 1,
  X'8201d28443a10127a0588f85011a69f330321903e8191ccd5880dff91e2d2fe04b05c94cd448db087c86c1e8a3aa27147cc6a6a29bfb3dad8d85b24e4a4cc2a1a06531603f15f5a41d52b63a53a6d60d647faeb169a12e78d900f22c14bb32e18ab9d99d37403c1860d5b84c6fc0b53b462b9ef193762a84efe6872f72348e210e0584d521a26ee9f983473e2feefe1ff5470abf0f13ea3e8bbd5840ffaa7fc72e6934f9631e6c866d55e67ea917d861f5915f050774675436be471bb078e733e28662ffff6aed5e878b2b00ee027f2d377649dd7e1dea6db417360b',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE NOT EXISTS (SELECT 1 FROM config);
''',
);
