import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';
import 'package:ddm_proto_dart/src/proto/stream.dart';

final class Address {
  Address({
    required this.version,
    required this.policy,
    required Uint8List pubkey,
  }) : pubkey = _copy32(pubkey) {
    validate();
  }

  final int version;
  final int policy;
  final Uint8List pubkey;

  static Address newV1(Uint8List publicKey, {int policy = 0}) {
    if (publicKey.length != 32) {
      throw FormatException(
        'public key must be 32 bytes, got ${publicKey.length}',
      );
    }
    return Address(
      version: addressVersionV1,
      policy: policy,
      pubkey: publicKey,
    );
  }

  void validate() {
    if (version != addressVersionV1) {
      throw FormatException('unsupported address version: $version');
    }
    if (!isAddressPolicySupported(policy)) {
      throw FormatException(
        'unsupported address policy bits: 0x${(policy & 0xff).toRadixString(16).padLeft(2, '0')}',
      );
    }
  }

  bool get requiresAck => (policy & addressPolicyAckExpected) != 0;

  StreamId streamId() {
    final digest = sha256Bytes(toBytes());
    final value =
        (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
    return StreamId(value);
  }

  Uint8List toBytes() {
    validate();
    return ddmCborCodec.encode(<Object?>[version, policy, copyBytes(pubkey)]);
  }

  String toText() {
    return base32NoPaddingEncode(_displayBytes()).toLowerCase();
  }

  static Address fromText(String raw) {
    final value = raw.trim();
    final decoded = base32NoPaddingDecode(value);
    return _fromDisplayBytes(decoded);
  }

  static Address fromBytes(Uint8List serialized) {
    final decoded = ddmCborCodec.decode(serialized);
    if (decoded is! List<Object?> || decoded.length != 3) {
      throw const FormatException('invalid address');
    }
    final version = decoded[0];
    final policy = decoded[1];
    final pubkey = decoded[2];
    if (version is! int ||
        policy is! int ||
        pubkey is! Uint8List ||
        pubkey.length != 32) {
      throw const FormatException('invalid address');
    }
    return Address(version: version, policy: policy, pubkey: pubkey);
  }

  Uint8List _displayBytes() {
    validate();
    final out = Uint8List(addressDisplaySize);
    out[0] = version;
    out[1] = policy;
    out.setRange(2, addressDisplayPayloadSize, pubkey);
    out[addressDisplayPayloadSize] = _checksum8(
      out.sublist(0, addressDisplayPayloadSize),
    );
    return out;
  }
}

Uint8List _copy32(Uint8List bytes) {
  if (bytes.length != 32) {
    throw FormatException('value must be 32 bytes, got ${bytes.length}');
  }
  return copyBytes(bytes);
}

Address _fromDisplayBytes(Uint8List display) {
  if (display.length != addressDisplaySize) {
    throw const FormatException('invalid address');
  }
  final checksum = _checksum8(display.sublist(0, addressDisplayPayloadSize));
  if (checksum != display[addressDisplayPayloadSize]) {
    throw const FormatException('invalid address');
  }
  return Address(
    version: display[0],
    policy: display[1],
    pubkey: display.sublist(2, addressDisplayPayloadSize),
  );
}

int _checksum8(Uint8List data) {
  var s = data.length & 0xff;
  for (final b in data) {
    s = ((s << 1) | (s >> 7)) & 0xff;
    s = (s + b) & 0xff;
  }
  return s;
}
