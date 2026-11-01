import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart' as p2p_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart' as p2p_keys;
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as p2p_crypto_pb;

Uint8List generateP2pPrivateKey() {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256), growable: false),
  );
}

Future<p2p_keys.KeyPair> p2pKeyPairFromPrivateKey(Uint8List privateKey) async {
  final raw = Uint8List.fromList(privateKey);
  if (raw.length == 32) {
    final key = await p2p_ed25519.Ed25519PrivateKey.fromRawBytes(raw);
    return p2p_keys.KeyPair(key.publicKey, key);
  }
  if (raw.length == 64) {
    final seed = Uint8List.sublistView(raw, 0, 32);
    final key = await p2p_ed25519.Ed25519PrivateKey.fromRawBytes(seed);
    return p2p_keys.KeyPair(key.publicKey, key);
  }

  try {
    final decoded = p2p_crypto_pb.PrivateKey.fromBuffer(raw);
    if (decoded.type != p2p_crypto_pb.KeyType.Ed25519) {
      throw const FormatException('p2p private key must be Ed25519');
    }
    final data = Uint8List.fromList(decoded.data);
    if (data.length < 32) {
      throw FormatException(
        'p2p Ed25519 private key data must be at least 32 bytes, got ${data.length}',
      );
    }
    final key = await p2p_ed25519.Ed25519PrivateKey.fromRawBytes(
      Uint8List.sublistView(data, 0, 32),
    );
    return p2p_keys.KeyPair(key.publicKey, key);
  } catch (_) {
    final key = await p2p_ed25519.Ed25519PrivateKey.unmarshal(raw);
    return p2p_keys.KeyPair(key.publicKey, key);
  }
}
