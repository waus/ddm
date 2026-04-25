import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/cose_sign1.dart';
import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';

final class ConfigRecord {
  ConfigRecord({required this.version, required Uint8List payload})
      : payload = copyBytes(payload);

  final int version;
  final Uint8List payload;

  ConfigRecord clone() => ConfigRecord(version: version, payload: payload);
}

final class ConfigV1Core {
  ConfigV1Core({
    required this.seqNo,
    required this.activeFromUnix,
    required this.powBaseTarget,
    required this.powScaleDivisor,
    required Uint8List powModulus,
  }) : powModulus = _copyFixed(powModulus, powModulusSize, 'pow modulus') {
    validate();
  }

  final int seqNo;
  final int activeFromUnix;
  final int powBaseTarget;
  final int powScaleDivisor;
  final Uint8List powModulus;

  void validate() {
    if (powScaleDivisor == 0) {
      throw const FormatException('pow_scale_divisor must not be zero');
    }
    if (powModulus.length != powModulusSize) {
      throw FormatException('pow_modulus must be $powModulusSize bytes');
    }
    if ((powModulus[0] & 0x80) == 0) {
      throw const FormatException(
        'pow_modulus must be a full-length 1024-bit value',
      );
    }
    if ((powModulus[powModulus.length - 1] & 1) == 0) {
      throw const FormatException('pow_modulus must be odd');
    }
    if (powModulus.every((b) => b == 0)) {
      throw const FormatException('pow_modulus must not be zero');
    }
  }

  Uint8List toBodyBytes() {
    validate();
    return ddmCborCodec.encode(<Object?>[
      seqNo,
      activeFromUnix,
      powBaseTarget,
      powScaleDivisor,
      copyBytes(powModulus),
    ]);
  }

  static ConfigV1Core fromBodyBytes(Uint8List bytes) {
    final decoded = ddmCborCodec.decode(bytes);
    if (decoded is! List<Object?> || decoded.length != 5) {
      throw const FormatException('decode config v1 body');
    }
    final seqNo = decoded[0];
    final activeFromUnix = decoded[1];
    final powBaseTarget = decoded[2];
    final powScaleDivisor = decoded[3];
    final powModulus = decoded[4];
    if (seqNo is! int ||
        activeFromUnix is! int ||
        powBaseTarget is! int ||
        powScaleDivisor is! int ||
        powModulus is! Uint8List) {
      throw const FormatException('decode config v1 body');
    }
    return ConfigV1Core(
      seqNo: seqNo,
      activeFromUnix: activeFromUnix,
      powBaseTarget: powBaseTarget,
      powScaleDivisor: powScaleDivisor,
      powModulus: powModulus,
    );
  }
}

final class ConfigV1Payload {
  ConfigV1Payload({required this.core, required Uint8List signedPayload})
      : signedPayload = copyBytes(signedPayload);

  final ConfigV1Core core;
  final Uint8List signedPayload;

  Uint8List toBytes() {
    if (signedPayload.isEmpty) {
      throw const FormatException('config signature must not be empty');
    }
    return copyBytes(signedPayload);
  }

  Future<void> verifySignature(Uint8List adminPublicKey) {
    return verifyCosePayload(
      signed: signedPayload,
      publicKey: adminPublicKey,
      expectedPayload: core.toBodyBytes(),
    );
  }

  static Future<ConfigV1Payload> build({
    required ConfigV1Core core,
    required Uint8List privateKey,
  }) async {
    final signed = await signCosePayload(
      payload: core.toBodyBytes(),
      privateKey: privateKey,
    );
    return ConfigV1Payload(core: core, signedPayload: signed);
  }

  static ConfigV1Payload fromBytes(Uint8List payload) {
    if (payload.length > maxConfigPayloadBytes) {
      throw FormatException(
        'config payload exceeds limit: got ${payload.length} bytes, max $maxConfigPayloadBytes',
      );
    }
    final body = decodeCosePayload(payload);
    if (body.length > maxConfigPayloadBytes) {
      throw FormatException(
        'config payload body exceeds limit: got ${body.length} bytes, max $maxConfigPayloadBytes',
      );
    }

    final core = ConfigV1Core.fromBodyBytes(body);
    return ConfigV1Payload(core: core, signedPayload: payload);
  }
}

Uint8List _copyFixed(Uint8List value, int expected, String label) {
  if (value.length != expected) {
    throw FormatException(
      '$label must be $expected bytes, got ${value.length}',
    );
  }
  return copyBytes(value);
}
