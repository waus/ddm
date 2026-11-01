import 'package:ddm_proto_dart/src/proto/constants.dart';

void validateSyncPrefix(String prefix) {
  if (!streamHexPrefixRe.hasMatch(prefix)) {
    throw const FormatException(
      'nibble string must contain only lowercase hex chars [0-9a-f]',
    );
  }
  if (prefix.length > syncBlobIdSize * 2) {
    throw FormatException(
        'prefix must be at most ${syncBlobIdSize * 2} nibbles');
  }
}

int syncNibbleIndex(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  throw FormatException('invalid nibble ${String.fromCharCode(codeUnit)}');
}

int sharedSyncPrefixLength(String a, String b) {
  var n = a.length;
  if (b.length < n) {
    n = b.length;
  }
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

int minSyncTtl(int a, int b) => a == 0 || b < a ? b : a;

int maxSyncTtl(int a, int b) => a > b ? a : b;
