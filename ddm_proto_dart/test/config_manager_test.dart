import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

const String _adminPrivateKeyHex =
    '0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f'
    'd9bf2148748a85c89da5aad8ee0b0fc2d105fd39d41a4c796536354f0ae2900c';

void main() {
  test('ConfigManager sorts records and finds historical configs', () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final configs = <ConfigRecord>[
      await _record(seqNo: 3, activeFromUnix: _unix(now)),
      await _record(
        seqNo: 1,
        activeFromUnix: _unix(now.subtract(const Duration(days: 10))),
      ),
      await _record(
        seqNo: 2,
        activeFromUnix: _unix(now.subtract(const Duration(days: 1))),
      ),
    ];
    final storage = _MemoryConfigStorage(configs);
    final manager = ConfigManager(storage: storage, nowUtc: () => now);

    expect(_seqNos(manager.records()), <int>[1, 2, 3]);
    expect(manager.configAtUnix(_unix(now)).seqNo, 3);
    expect(
      manager.configAtUnix(_unix(now.subtract(const Duration(hours: 2)))).seqNo,
      2,
    );
  });

  test('ConfigManager ignores known records and persists new signed records',
      () async {
    final now = DateTime.utc(2026, 4, 19, 10, 0, 0);
    final initial = await _record(seqNo: 1, activeFromUnix: _unix(now));
    final storage = _MemoryConfigStorage(<ConfigRecord>[initial]);
    final manager = ConfigManager(storage: storage, nowUtc: () => now);

    await manager.addRecord(initial);
    expect(storage.inserted, isEmpty);

    final next = await _record(
      seqNo: 2,
      activeFromUnix: _unix(now.add(const Duration(days: 1))),
    );
    await manager.addRecord(next);

    expect(storage.inserted, <int>[2]);
    expect(_seqNos(manager.records()), <int>[1, 2]);
  });
}

Future<ConfigRecord> _record({
  required int seqNo,
  required int activeFromUnix,
}) async {
  final payload = await ConfigV1Payload.build(
    core: ConfigV1Core(
      seqNo: seqNo,
      activeFromUnix: activeFromUnix,
      powBaseTarget: 1,
      powScaleDivisor: 1,
      powModulus: _modulus(),
    ),
    privateKey: _decodeHex(_adminPrivateKeyHex),
  );
  return parseConfigRecord(
    Uint8List.fromList(
        <int>[0x82, configRecordVersionV1, ...payload.toBytes()]),
  );
}

List<int> _seqNos(List<ConfigRecord> records) {
  return records
      .map((record) => ConfigV1Payload.fromBytes(configRecordPayload(record)))
      .map((payload) => payload.core.seqNo)
      .toList(growable: false);
}

Uint8List _modulus() {
  return Uint8List(powModulusSize)
    ..[0] = 0x80
    ..[powModulusSize - 1] = 1;
}

int _unix(DateTime value) => value.toUtc().millisecondsSinceEpoch ~/ 1000;

Uint8List _decodeHex(String value) {
  final normalized = value.trim().toLowerCase();
  final out = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < normalized.length; i += 2) {
    out[i ~/ 2] = int.parse(normalized.substring(i, i + 2), radix: 16);
  }
  return out;
}

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
