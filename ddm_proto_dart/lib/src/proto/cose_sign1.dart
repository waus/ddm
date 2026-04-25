import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';

final class CoseSign1 {
  CoseSign1({
    required this.protectedHeaders,
    required this.unprotectedHeaders,
    required Uint8List payload,
    required Uint8List signature,
  })  : payload = copyBytes(payload),
        signature = copyBytes(signature);

  final Map<Object?, Object?> protectedHeaders;
  final Map<Object?, Object?> unprotectedHeaders;
  final Uint8List payload;
  final Uint8List signature;

  Uint8List toBytes() {
    final protected = ddmCborCodec.encode(protectedHeaders);
    return ddmCborCodec.encode(
      CborTag(18, <Object?>[
        protected,
        Map<Object?, Object?>.from(unprotectedHeaders),
        copyBytes(payload),
        copyBytes(signature),
      ]),
    );
  }

  static CoseSign1 fromBytes(Uint8List bytes) {
    final decoded = ddmCborCodec.decode(bytes);
    final unwrapped = decoded is CborTag ? decoded.value : decoded;
    if (unwrapped is! List<Object?> || unwrapped.length != 4) {
      throw const FormatException('decode cose sign1');
    }

    final protectedBytes = unwrapped[0];
    final unprotected = unwrapped[1];
    final payload = unwrapped[2];
    final signature = unwrapped[3];

    if (protectedBytes is! Uint8List ||
        unprotected is! Map<Object?, Object?> ||
        payload is! Uint8List ||
        signature is! Uint8List) {
      throw const FormatException('decode cose sign1');
    }

    final protectedDecoded = ddmCborCodec.decode(protectedBytes);
    if (protectedDecoded is! Map<Object?, Object?>) {
      throw const FormatException('decode cose sign1 protected headers');
    }

    return CoseSign1(
      protectedHeaders: protectedDecoded,
      unprotectedHeaders: unprotected,
      payload: payload,
      signature: signature,
    );
  }
}

Uint8List decodeCosePayload(Uint8List signed) {
  final msg = CoseSign1.fromBytes(signed);
  return copyBytes(msg.payload);
}

Future<Uint8List> signCosePayload({
  required Uint8List payload,
  required Uint8List privateKey,
}) async {
  if (privateKey.length != 64) {
    throw FormatException(
      'private key size: got ${privateKey.length}, want 64',
    );
  }

  final seed = Uint8List.sublistView(privateKey, 0, 32);
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final protected = ddmCborCodec.encode(<Object?, Object?>{
    coseHeaderAlg: coseAlgorithmEdDsa,
  });

  final sigStructure = ddmCborCodec.encode(<Object?>[
    'Signature1',
    protected,
    Uint8List(0),
    copyBytes(payload),
  ]);
  final signature = await algorithm.sign(sigStructure, keyPair: keyPair);

  return CoseSign1(
    protectedHeaders: <Object?, Object?>{coseHeaderAlg: coseAlgorithmEdDsa},
    unprotectedHeaders: const <Object?, Object?>{},
    payload: payload,
    signature: Uint8List.fromList(signature.bytes),
  ).toBytes();
}

Future<void> verifyCosePayload({
  required Uint8List signed,
  required Uint8List publicKey,
  Uint8List? expectedPayload,
}) async {
  if (publicKey.length != 32) {
    throw FormatException('public key size: got ${publicKey.length}, want 32');
  }

  final msg = CoseSign1.fromBytes(signed);
  final protected = ddmCborCodec.encode(msg.protectedHeaders);
  final sigStructure = ddmCborCodec.encode(<Object?>[
    'Signature1',
    protected,
    Uint8List(0),
    copyBytes(msg.payload),
  ]);

  final algorithm = Ed25519();
  final ok = await algorithm.verify(
    sigStructure,
    signature: Signature(
      msg.signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
  if (!ok) {
    throw const FormatException('verify cose sign1');
  }

  if (expectedPayload != null && !bytesEqual(msg.payload, expectedPayload)) {
    throw const FormatException('signed payload does not match message body');
  }
}
