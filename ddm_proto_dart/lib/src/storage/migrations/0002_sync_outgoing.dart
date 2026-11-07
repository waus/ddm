// ignore_for_file: file_names
import '../migration.dart';

const migration0002SyncOutgoing =
    StorageMigration(number: 2, name: '0002_sync_outgoing', sql: '''
CREATE TABLE sync_outgoing (
  blob_id BLOB PRIMARY KEY,
  next_attempt INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE sync_deliveries (
  blob_id BLOB NOT NULL,
  peer_id TEXT NOT NULL,
  PRIMARY KEY (blob_id, peer_id)
);
CREATE TRIGGER sync_outgoing_insert AFTER INSERT ON sync_blobs
WHEN NEW.source = 'local'
BEGIN
  INSERT OR IGNORE INTO sync_outgoing(blob_id) VALUES (NEW.blob_id);
END;
CREATE TRIGGER sync_outgoing_delete AFTER DELETE ON sync_blobs
BEGIN
  DELETE FROM sync_outgoing WHERE blob_id = OLD.blob_id;
  DELETE FROM sync_deliveries WHERE blob_id = OLD.blob_id;
END;
INSERT OR IGNORE INTO sync_outgoing(blob_id)
SELECT blob_id FROM sync_blobs WHERE source = 'local';
''');
