import 'package:ddm_proto_dart/src/proto/config_manager.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/storage/storage_clock.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class ConfigRepository implements ConfigManagerStorage {
  ConfigRepository(this._db, this._nowUtc);

  final Database _db;
  final UtcNow _nowUtc;

  static final ConfigRecord defaultConfigRecord = _buildDefaultConfigRecord();

  @override
  List<ConfigRecord> listConfigRecords() {
    final rows = _db.select(
      '''
SELECT payload
FROM config
ORDER BY seqno ASC;
''',
    );
    return rows.map(_scanConfigRecord).toList(growable: false);
  }

  @override
  void insertConfigRecord(ConfigRecord record, ConfigV1Core config) {
    _db.execute(
      '''
INSERT INTO config(seqno, payload, created_at)
VALUES(?, ?, ?);
''',
      <Object?>[
        config.seqNo,
        record.toBytes(),
        formatStoredTime(_nowUtc()),
      ],
    );
  }

  @override
  void deleteConfigRecordsBeforeSeqNo(int seqNo) {
    _db.execute(
      'DELETE FROM config WHERE seqno < ?;',
      <Object?>[seqNo],
    );
  }

  ConfigRecord _scanConfigRecord(Row row) {
    return parseConfigRecord(asBytes(row['payload'], 'config payload'));
  }
}

ConfigRecord _buildDefaultConfigRecord() {
  return parseConfigRecord(
    decodeHex(
      '8201d28443a10127a0588f85011a69f330321903e8191ccd5880dff91e2d2fe04b05c94cd448db087c86c1e8a3aa27147cc6a6a29bfb3dad8d85b24e4a4cc2a1a06531603f15f5a41d52b63a53a6d60d647faeb169a12e78d900f22c14bb32e18ab9d99d37403c1860d5b84c6fc0b53b462b9ef193762a84efe6872f72348e210e0584d521a26ee9f983473e2feefe1ff5470abf0f13ea3e8bbd5840ffaa7fc72e6934f9631e6c866d55e67ea917d861f5915f050774675436be471bb078e733e28662ffff6aed5e878b2b00ee027f2d377649dd7e1dea6db417360b',
    ),
  );
}
