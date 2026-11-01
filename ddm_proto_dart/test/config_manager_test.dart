import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

void main() {
  test('ConfigManager loads production default config', () {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final storage = _MemoryConfigStorage(
      <ConfigRecord>[ConfigRepository.defaultConfigRecord],
    );
    final manager = ConfigManager(storage: storage, nowUtc: () => now);

    expect(_seqNos(manager.records()), <int>[1]);
    expect(manager.configAtUnix(_unix(now)).seqNo, 1);
  });

  test('ConfigManager ignores known production config record', () async {
    final now = DateTime.utc(2026, 5, 1, 10, 0, 0);
    final initial = ConfigRepository.defaultConfigRecord;
    final storage = _MemoryConfigStorage(<ConfigRecord>[initial]);
    final manager = ConfigManager(storage: storage, nowUtc: () => now);

    await manager.addRecord(initial);
    expect(storage.inserted, isEmpty);
    expect(_seqNos(manager.records()), <int>[1]);
  });
}

List<int> _seqNos(List<ConfigRecord> records) {
  return records
      .map((record) => ConfigV1Payload.fromBytes(configRecordPayload(record)))
      .map((payload) => payload.core.seqNo)
      .toList(growable: false);
}

int _unix(DateTime value) => value.toUtc().millisecondsSinceEpoch ~/ 1000;

final class _MemoryConfigStorage implements ConfigManagerStorage {
  _MemoryConfigStorage(List<ConfigRecord> records)
      : _records = List<ConfigRecord>.from(records);

  final List<ConfigRecord> _records;
  final List<int> inserted = <int>[];

  @override
  List<ConfigRecord> listConfigRecords() {
    return List<ConfigRecord>.from(_records);
  }

  @override
  void insertConfigRecord(ConfigRecord record, ConfigV1Core config) {
    inserted.add(config.seqNo);
    _records.add(record);
  }

  @override
  void deleteConfigRecordsBeforeSeqNo(int seqNo) {
    _records.removeWhere((record) {
      final payload = ConfigV1Payload.fromBytes(configRecordPayload(record));
      return payload.core.seqNo < seqNo;
    });
  }
}
