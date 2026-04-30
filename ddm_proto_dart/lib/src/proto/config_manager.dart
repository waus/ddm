import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';

typedef ConfigManagerNow = DateTime Function();

abstract interface class ConfigManagerStorage {
  List<ConfigRecord> listConfigRecords();

  void insertConfigRecord(ConfigRecord record, ConfigV1Core config);

  void deleteConfigRecordsBeforeSeqNo(int seqNo);
}

final class ConfigManager {
  ConfigManager({
    required ConfigManagerStorage storage,
    ConfigManagerNow? nowUtc,
  })  : _storage = storage,
        _nowUtc = nowUtc ?? _defaultUtcNow {
    final records = _storage.listConfigRecords();
    for (final record in records) {
      final hash = _crc64Iso(record.toBytes());
      if (_known.contains(hash)) {
        continue;
      }
      _known.add(hash);
      _records.add(_ManagedConfigRecord(
        record: record,
        config: _decodeRecordCore(record),
      ));
    }
    _refresh();
  }

  final ConfigManagerStorage _storage;
  final ConfigManagerNow _nowUtc;
  final Set<BigInt> _known = <BigInt>{};
  final List<_ManagedConfigRecord> _records = <_ManagedConfigRecord>[];
  int _activeIndex = -1;
  Timer? _timer;

  List<ConfigRecord> records() {
    return _records.map((record) => record.record).toList(growable: false);
  }

  ConfigV1Core configAtUnix(int unixTimestamp) {
    if (_activeIndex < 0) {
      throw const FormatException('active config not found');
    }
    for (var i = min(_activeIndex, _records.length - 1); i >= 0; i--) {
      final config = _records[i].config;
      if (config.activeFromUnix <= unixTimestamp) {
        return config;
      }
    }
    throw FormatException('config not found for unix timestamp $unixTimestamp');
  }

  Future<void> addRecord(ConfigRecord record) async {
    final hash = _crc64Iso(record.toBytes());
    if (_known.contains(hash)) {
      return;
    }

    final config = _decodeRecordCore(record);
    final payload = ConfigV1Payload.fromBytes(configRecordPayload(record));
    await payload.verifySignature(_defaultConfigAdminPublicKey);

    final minActiveFrom = _unixSeconds(_nowUtc()) - _configRetention.inSeconds;
    if (config.activeFromUnix < minActiveFrom) {
      throw const FormatException('config is outside retention window');
    }

    final next = _ManagedConfigRecord(record: record, config: config);
    var index = 0;
    while (index < _records.length &&
        _records[index].config.seqNo < config.seqNo) {
      index++;
    }
    if (index < _records.length &&
        _records[index].config.seqNo == config.seqNo) {
      throw FormatException('config seqno ${config.seqNo} already exists');
    }
    if (index > 0 &&
        _records[index - 1].config.activeFromUnix >= config.activeFromUnix) {
      throw FormatException(
        'config seqno ${config.seqNo} activation time must be after previous config',
      );
    }
    if (index < _records.length &&
        config.activeFromUnix >= _records[index].config.activeFromUnix) {
      throw FormatException(
        'config seqno ${config.seqNo} activation time must be before next config',
      );
    }

    _storage.insertConfigRecord(record, config);
    _records.insert(index, next);
    _known.add(hash);
    _refresh();
  }

  void _refresh() {
    _records.sort((a, b) => a.config.seqNo.compareTo(b.config.seqNo));
    _validateOrder();
    _prune();
    _activeIndex = _findActiveIndex(_unixSeconds(_nowUtc()));
    _resetTimer();
  }

  void _validateOrder() {
    for (var i = 1; i < _records.length; i++) {
      final previous = _records[i - 1].config;
      final current = _records[i].config;
      if (previous.seqNo == current.seqNo) {
        throw FormatException('duplicate config seqno ${current.seqNo}');
      }
      if (previous.activeFromUnix >= current.activeFromUnix) {
        throw FormatException(
          'config active_from must increase with seqno ${current.seqNo}',
        );
      }
    }
  }

  void _prune() {
    final cutoff = _unixSeconds(_nowUtc()) - _configRetention.inSeconds;
    var keepFrom = 0;
    for (var i = 0; i < _records.length; i++) {
      if (_records[i].config.activeFromUnix < cutoff) {
        keepFrom = i;
      }
    }
    if (keepFrom == 0) {
      return;
    }
    final seqNo = _records[keepFrom].config.seqNo;
    _storage.deleteConfigRecordsBeforeSeqNo(seqNo);
    _records.removeRange(0, keepFrom);
  }

  int _findActiveIndex(int now) {
    var active = -1;
    for (var i = 0; i < _records.length; i++) {
      if (_records[i].config.activeFromUnix <= now) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  void _resetTimer() {
    _timer?.cancel();
    _timer = null;
    final nextIndex = _activeIndex + 1;
    if (nextIndex < 0 || nextIndex >= _records.length) {
      return;
    }
    final now = _unixSeconds(_nowUtc());
    final next = _records[nextIndex].config.activeFromUnix;
    final delaySeconds = next - now;
    if (delaySeconds <= 0) {
      scheduleMicrotask(_refresh);
      return;
    }
    _timer = Timer(Duration(seconds: delaySeconds), _refresh);
  }
}

final class _ManagedConfigRecord {
  const _ManagedConfigRecord({required this.record, required this.config});

  final ConfigRecord record;
  final ConfigV1Core config;
}

ConfigV1Core _decodeRecordCore(ConfigRecord record) {
  final version = configRecordVersion(record);
  if (version != configRecordVersionV1) {
    throw FormatException('unsupported config version: $version');
  }
  return ConfigV1Payload.fromBytes(configRecordPayload(record)).core;
}

int _unixSeconds(DateTime value) =>
    value.toUtc().millisecondsSinceEpoch ~/ 1000;

DateTime _defaultUtcNow() => DateTime.now().toUtc();

final Uint8List _defaultConfigAdminPublicKey = parseHexBytes(
  '28791c5afb2c1ae4da98bb58331e0e7ca386a8e5bbc04c07b66c02b316b7cde0',
  expectedBytes: 32,
  label: 'default config admin public key',
);

const Duration _configRetention = Duration(days: 40);
final List<BigInt> _crc64IsoTable = _buildCrc64IsoTable();
final BigInt _crc64Mask = (BigInt.one << 64) - BigInt.one;

BigInt _crc64Iso(Uint8List bytes) {
  var crc = BigInt.zero;
  for (final byte in bytes) {
    final index = ((crc.toInt() ^ byte) & 0xff);
    crc = _crc64IsoTable[index] ^ (crc >> 8);
  }
  return crc & _crc64Mask;
}

List<BigInt> _buildCrc64IsoTable() {
  final poly = BigInt.parse('d800000000000000', radix: 16);
  return List<BigInt>.generate(256, (i) {
    var crc = BigInt.from(i);
    for (var j = 0; j < 8; j++) {
      if ((crc & BigInt.one) != BigInt.zero) {
        crc = poly ^ (crc >> 1);
      } else {
        crc >>= 1;
      }
    }
    return crc & _crc64Mask;
  }, growable: false);
}
