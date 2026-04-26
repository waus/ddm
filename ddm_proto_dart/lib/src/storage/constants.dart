const String defaultFileName = 'ddmdb.sqlite';

const String messageStateReceived = 'rcv';
const String messageStateCreated = 'new';
const String messageStatePowSynced = 'pws';
const String messageStateDelivered = 'dlv';

const String syncBlobSourceLocal = 'local';
const String syncBlobSourceImported = 'imported';

const List<String> schemaStatements = <String>[
  '''
CREATE TABLE IF NOT EXISTS config (
  seqno INTEGER PRIMARY KEY,
  active_from TEXT NOT NULL,
  version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  created_at TEXT NOT NULL
);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_config_active_from
ON config(active_from);
''',
  '''
CREATE TABLE IF NOT EXISTS accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL COLLATE NOCASE UNIQUE,
  address TEXT NOT NULL UNIQUE,
  public_key BLOB NOT NULL,
  private_key BLOB NOT NULL,
  stream_id INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_accounts_stream_id
ON accounts(stream_id);
''',
  '''
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
''',
  '''
CREATE INDEX IF NOT EXISTS idx_messages_state
ON messages(state);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_messages_created_at
ON messages(created_at);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_messages_updated_at
ON messages(updated_at);
''',
  '''
CREATE TABLE IF NOT EXISTS sync_blobs (
  blob_id BLOB PRIMARY KEY,
  blob BLOB NOT NULL,
  source TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_sync_blobs_source
ON sync_blobs(source);
''',
  '''
CREATE TABLE IF NOT EXISTS p2p_identity (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  private_key BLOB NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''',
  '''
CREATE TABLE IF NOT EXISTS peers (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  last_online_at TEXT,
  rating REAL NOT NULL
);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_peers_last_online_at
ON peers(last_online_at);
''',
  '''
CREATE INDEX IF NOT EXISTS idx_peers_rating
ON peers(rating);
''',
];
