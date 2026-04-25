import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/_bytes.dart';

final class CborTag {
  const CborTag(this.number, this.value);

  final int number;
  final Object? value;
}

final class DdmCborCodec {
  const DdmCborCodec({
    this.maxNestedLevels = maxCborNestedLevels,
    this.maxArrayElements = maxCborArrayElements,
    this.maxMapPairs = maxCborMapPairs,
  });

  final int maxNestedLevels;
  final int maxArrayElements;
  final int maxMapPairs;

  Uint8List encode(Object? value) {
    final out = BytesBuilder(copy: false);
    _writeValue(out, value);
    return out.toBytes();
  }

  Object? decode(Uint8List bytes) {
    final reader = _CborReader(
      bytes,
      maxNestedLevels: maxNestedLevels,
      maxArrayElements: maxArrayElements,
      maxMapPairs: maxMapPairs,
    );
    final value = reader.readValue(0);
    if (!reader.isEof) {
      throw FormatException('unexpected ${reader.remaining} trailing bytes');
    }
    return value;
  }

  void _writeValue(BytesBuilder out, Object? value) {
    if (value == null) {
      out.addByte(0xf6);
      return;
    }
    if (value is bool) {
      out.addByte(value ? 0xf5 : 0xf4);
      return;
    }
    if (value is int) {
      _writeInt(out, value);
      return;
    }
    if (value is String) {
      final encoded = Uint8List.fromList(value.codeUnits);
      _writeTypeAndLength(out, 3, encoded.length);
      out.add(encoded);
      return;
    }
    if (value is Uint8List) {
      _writeTypeAndLength(out, 2, value.length);
      out.add(value);
      return;
    }
    if (value is List<Object?>) {
      _writeTypeAndLength(out, 4, value.length);
      for (final item in value) {
        _writeValue(out, item);
      }
      return;
    }
    if (value is CborTag) {
      _writeTypeAndLength(out, 6, value.number);
      _writeValue(out, value.value);
      return;
    }
    if (value is Map<Object?, Object?>) {
      final pairs = <_MapPair>[];
      value.forEach((key, mapValue) {
        final keyBytes = encode(key);
        pairs.add(_MapPair(keyBytes, key, mapValue));
      });
      pairs.sort((a, b) {
        final minLen = a.keyBytes.length < b.keyBytes.length
            ? a.keyBytes.length
            : b.keyBytes.length;
        for (var i = 0; i < minLen; i++) {
          final cmp = a.keyBytes[i].compareTo(b.keyBytes[i]);
          if (cmp != 0) {
            return cmp;
          }
        }
        return a.keyBytes.length.compareTo(b.keyBytes.length);
      });
      _writeTypeAndLength(out, 5, pairs.length);
      for (final pair in pairs) {
        out.add(pair.keyBytes);
        _writeValue(out, pair.value);
      }
      return;
    }

    throw ArgumentError('unsupported cbor value type: ${value.runtimeType}');
  }

  void _writeInt(BytesBuilder out, int value) {
    if (value >= 0) {
      _writeTypeAndLength(out, 0, value);
      return;
    }
    _writeTypeAndLength(out, 1, -1 - value);
  }

  void _writeTypeAndLength(BytesBuilder out, int majorType, int value) {
    if (value < 0) {
      throw ArgumentError('negative cbor length');
    }
    if (value < 24) {
      out.addByte((majorType << 5) | value);
      return;
    }
    if (value <= 0xff) {
      out.add([(majorType << 5) | 24, value]);
      return;
    }
    if (value <= 0xffff) {
      out.addByte((majorType << 5) | 25);
      out.addByte((value >> 8) & 0xff);
      out.addByte(value & 0xff);
      return;
    }
    if (value <= 0xffffffff) {
      out.addByte((majorType << 5) | 26);
      out.addByte((value >> 24) & 0xff);
      out.addByte((value >> 16) & 0xff);
      out.addByte((value >> 8) & 0xff);
      out.addByte(value & 0xff);
      return;
    }
    out.addByte((majorType << 5) | 27);
    final hi = value ~/ 0x100000000;
    final lo = value & 0xffffffff;
    out.addByte((hi >> 24) & 0xff);
    out.addByte((hi >> 16) & 0xff);
    out.addByte((hi >> 8) & 0xff);
    out.addByte(hi & 0xff);
    out.addByte((lo >> 24) & 0xff);
    out.addByte((lo >> 16) & 0xff);
    out.addByte((lo >> 8) & 0xff);
    out.addByte(lo & 0xff);
  }
}

final class _MapPair {
  const _MapPair(this.keyBytes, this.key, this.value);

  final Uint8List keyBytes;
  final Object? key;
  final Object? value;
}

final class _CborReader {
  _CborReader(
    this.bytes, {
    required this.maxNestedLevels,
    required this.maxArrayElements,
    required this.maxMapPairs,
  });

  final Uint8List bytes;
  final int maxNestedLevels;
  final int maxArrayElements;
  final int maxMapPairs;
  int offset = 0;

  bool get isEof => offset == bytes.length;
  int get remaining => bytes.length - offset;

  Object? readValue(int depth) {
    if (depth >= maxNestedLevels) {
      throw FormatException('cbor nesting exceeds limit $maxNestedLevels');
    }
    final head = _readByte();
    final majorType = head >> 5;
    final addInfo = head & 0x1f;

    switch (majorType) {
      case 0:
        return _readLength(addInfo);
      case 1:
        return -1 - _readLength(addInfo);
      case 2:
        final len = _readLength(addInfo);
        return _readBytes(len);
      case 3:
        final len = _readLength(addInfo);
        return String.fromCharCodes(_readBytes(len));
      case 4:
        final len = _readLength(addInfo);
        if (len > maxArrayElements) {
          throw FormatException('cbor array exceeds limit $maxArrayElements');
        }
        final out = <Object?>[];
        for (var i = 0; i < len; i++) {
          out.add(readValue(depth + 1));
        }
        return out;
      case 5:
        final len = _readLength(addInfo);
        if (len > maxMapPairs) {
          throw FormatException('cbor map pairs exceed limit $maxMapPairs');
        }
        final out = <Object?, Object?>{};
        final keyDigests = <String>{};
        final codec = DdmCborCodec(
          maxNestedLevels: maxNestedLevels,
          maxArrayElements: maxArrayElements,
          maxMapPairs: maxMapPairs,
        );
        for (var i = 0; i < len; i++) {
          final key = readValue(depth + 1);
          final digest = bytesToHex(codec.encode(key));
          if (!keyDigests.add(digest)) {
            throw const FormatException('duplicate cbor map key');
          }
          out[key] = readValue(depth + 1);
        }
        return out;
      case 6:
        final tag = _readLength(addInfo);
        final value = readValue(depth + 1);
        return CborTag(tag, value);
      case 7:
        if (addInfo == 20) {
          return false;
        }
        if (addInfo == 21) {
          return true;
        }
        if (addInfo == 22) {
          return null;
        }
        throw FormatException('unsupported cbor simple value: $addInfo');
      default:
        throw FormatException('unsupported cbor major type: $majorType');
    }
  }

  int _readLength(int addInfo) {
    if (addInfo < 24) {
      return addInfo;
    }
    if (addInfo == 31) {
      throw const FormatException('indefinite length cbor is forbidden');
    }
    if (addInfo == 24) {
      return _readByte();
    }
    if (addInfo == 25) {
      final b0 = _readByte();
      final b1 = _readByte();
      return (b0 << 8) | b1;
    }
    if (addInfo == 26) {
      final b0 = _readByte();
      final b1 = _readByte();
      final b2 = _readByte();
      final b3 = _readByte();
      return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }
    if (addInfo == 27) {
      final hi = (_readByte() << 24) |
          (_readByte() << 16) |
          (_readByte() << 8) |
          _readByte();
      final lo = (_readByte() << 24) |
          (_readByte() << 16) |
          (_readByte() << 8) |
          _readByte();
      return (hi * 0x100000000) + lo;
    }
    throw FormatException('unsupported cbor addInfo: $addInfo');
  }

  int _readByte() {
    if (offset >= bytes.length) {
      throw const FormatException('unexpected end of cbor');
    }
    return bytes[offset++];
  }

  Uint8List _readBytes(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw const FormatException('unexpected end of cbor bytes');
    }
    final out = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return Uint8List.fromList(out);
  }
}

const ddmCborCodec = DdmCborCodec();
