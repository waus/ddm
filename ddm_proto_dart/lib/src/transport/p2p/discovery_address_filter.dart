part of '../p2p.dart';

bool _isPublicDiscoveryAddr(String addr) {
  final ip = _multiaddrIp(addr);
  if (ip == null) {
    return false;
  }
  return !_isDeniedDiscoveryIp(ip);
}

bool _isDiscoveryCandidateAddr(String addr) {
  final ip = _multiaddrIp(addr);
  if (ip == null) {
    return false;
  }
  if (ip.type == InternetAddressType.IPv4 &&
      ip.rawAddress.every((b) => b == 0)) {
    return false;
  }
  return true;
}

InternetAddress? _multiaddrIp(String addr) {
  final parts = addr.split('/').where((part) => part.isNotEmpty).toList();
  for (var i = 0; i + 1 < parts.length; i += 2) {
    if (parts[i] == 'ip4' || parts[i] == 'ip6') {
      return InternetAddress.tryParse(parts[i + 1]);
    }
  }
  return null;
}

bool _isDeniedDiscoveryIp(InternetAddress ip) {
  if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) {
    return true;
  }
  final raw = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    final a = raw[0];
    final b = raw[1];
    return a == 0 ||
        a == 10 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && (b == 0 || b == 168)) ||
        (a == 198 && (b == 18 || b == 19 || b == 51)) ||
        (a == 203 && b == 0) ||
        a >= 224;
  }
  return raw.every((b) => b == 0) ||
      (raw[0] & 0xfe) == 0xfc ||
      (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) ||
      raw[0] == 0xff ||
      _bytesEqualPrefix(raw, const <int>[0x20, 0x01, 0x0d, 0xb8]);
}

bool _bytesEqualPrefix(List<int> value, List<int> prefix) {
  if (value.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (value[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
