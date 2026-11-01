import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ddm_proto_dart/src/runtime/runtime/runtime_options.dart';

Future<({Uint8List publicKey, Uint8List privateKey})> newAccountKeys(
  RandomBytes randomBytes,
) async {
  final seed = randomBytes(32);
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  final privateKey = Uint8List(64)
    ..setRange(0, 32, seed)
    ..setRange(32, 64, publicKey.bytes);
  return (
    publicKey: Uint8List.fromList(publicKey.bytes),
    privateKey: privateKey,
  );
}
