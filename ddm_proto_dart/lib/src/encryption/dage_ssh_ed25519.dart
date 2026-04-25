import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dage/dage.dart';
import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/address.dart';

const String _sshEd25519RecipientPrefix = 'ssh-ed25519';
const String _sshEd25519Label = 'age-encryption.org/v1/ssh-ed25519';
final BigInt _ed25519Prime = (BigInt.one << 255) - BigInt.from(19);
bool _sshEd25519PluginRegistered = false;

typedef RecipientPayloadEncryptor = FutureOr<Uint8List> Function({
  required Address recipient,
  required Uint8List plaintext,
});

typedef RecipientPayloadDecryptor = FutureOr<Uint8List> Function({
  required Uint8List privateKey,
  required Uint8List publicKey,
  required Uint8List ciphertext,
});

Future<Uint8List> encryptForRecipientWithDage({
  required Address recipient,
  required Uint8List plaintext,
}) async {
  registerSshEd25519AgePlugin();
  final chunks = await encrypt(
    Stream<List<int>>.value(copyBytes(plaintext)),
    <AgeRecipient>[_sshEd25519Recipient(recipient.pubkey)],
  ).toList();
  return Uint8List.fromList(chunks.expand((chunk) => chunk).toList());
}

Future<Uint8List> decryptForRecipientWithDage({
  required Uint8List privateKey,
  required Uint8List publicKey,
  required Uint8List ciphertext,
}) async {
  registerSshEd25519AgePlugin();
  final keyPair = AgeKeyPair(
    AgeIdentity(_sshEd25519RecipientPrefix, _ed25519PrivateKeySeed(privateKey)),
    AgeRecipient(_sshEd25519RecipientPrefix, copyBytes(publicKey)),
  );
  final chunks = await decrypt(
    Stream<List<int>>.value(copyBytes(ciphertext)),
    <AgeKeyPair>[keyPair],
  ).toList();
  return Uint8List.fromList(chunks.expand((chunk) => chunk).toList());
}

void registerSshEd25519AgePlugin() {
  if (_sshEd25519PluginRegistered) {
    return;
  }
  AgePlugin.registerPlugin(const SshEd25519AgePlugin());
  _sshEd25519PluginRegistered = true;
}

final class SshEd25519AgePlugin extends AgePlugin {
  const SshEd25519AgePlugin();

  @override
  Future<AgeKeyPair?> identityToKeyPair(AgeIdentity identity) async {
    if (identity.bytes.length != 32) {
      return null;
    }
    final edKeyPair = await Ed25519().newKeyPairFromSeed(identity.bytes);
    final publicKey = await edKeyPair.extractPublicKey();
    return AgeKeyPair(
      identity,
      AgeRecipient(
        _sshEd25519RecipientPrefix,
        Uint8List.fromList(publicKey.bytes),
      ),
    );
  }

  @override
  Future<AgeStanza?> parseStanza(
    List<String> arguments,
    List<int> body, {
    PassphraseProvider passphraseProvider = const PassphraseProvider(),
  }) async {
    if (arguments.length != 3 || arguments[0] != _sshEd25519RecipientPrefix) {
      return null;
    }
    final ephemeralPublicKey = base64RawDecode(arguments[2]);
    if (ephemeralPublicKey.length != 32) {
      throw FormatException(
        'ssh-ed25519 ephemeral public key must be 32 bytes, got ${ephemeralPublicKey.length}',
      );
    }
    if (body.length < 16) {
      throw const FormatException('ssh-ed25519 wrapped key is too short');
    }
    return _SshEd25519AgeStanza(
      fingerprint: arguments[1],
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublicKey),
      wrappedKey: Uint8List.fromList(body),
    );
  }

  @override
  Future<AgeStanza?> createStanza(
    AgeRecipient recipient,
    List<int> symmetricFileKey, [
    KeyPair? ephemeralKeyPair,
  ]) async {
    if (recipient.prefix != _sshEd25519RecipientPrefix) {
      return null;
    }
    if (ephemeralKeyPair != null && ephemeralKeyPair is! SimpleKeyPair) {
      throw FormatException(
        'ssh-ed25519 age ephemeral key pair has unexpected type ${ephemeralKeyPair.runtimeType}',
      );
    }
    return _SshEd25519AgeStanza.create(
      recipient.bytes,
      symmetricFileKey,
      ephemeralKeyPair as SimpleKeyPair?,
    );
  }

  @override
  Future<AgeStanza?> createPassphraseStanza(
    List<int> symmetricFileKey,
    List<int> salt, {
    PassphraseProvider passphraseProvider = const PassphraseProvider(),
    int workFactor = -1,
  }) async {
    return null;
  }
}

final class _SshEd25519AgeStanza extends AgeStanza {
  const _SshEd25519AgeStanza({
    required this.fingerprint,
    required this.ephemeralPublicKey,
    required this.wrappedKey,
  });

  final String fingerprint;
  final Uint8List ephemeralPublicKey;
  final Uint8List wrappedKey;

  static Future<_SshEd25519AgeStanza> create(
    Uint8List ed25519PublicKey,
    List<int> symmetricFileKey, [
    SimpleKeyPair? ephemeralKeyPair,
  ]) async {
    if (ed25519PublicKey.length != 32) {
      throw FormatException(
        'ssh-ed25519 public key must be 32 bytes, got ${ed25519PublicKey.length}',
      );
    }
    final x25519 = X25519();
    final keyPair = ephemeralKeyPair ?? await x25519.newKeyPair();
    final ephemeralPublicKey = await keyPair.extractPublicKey();
    final recipientPublicKey = _ed25519PublicKeyToCurve25519(
      ed25519PublicKey,
    );
    final remotePublicKey = SimplePublicKey(
      recipientPublicKey,
      type: KeyPairType.x25519,
    );
    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );
    final sharedSecretBytes = await sharedSecret.extractBytes();
    if (sharedSecretBytes.every((byte) => byte == 0)) {
      throw const FormatException('ssh-ed25519 shared secret is all zero');
    }

    final sshPublicKey = _marshalSshEd25519PublicKey(ed25519PublicKey);
    final tweak = await _hkdf(
      secretKey: Uint8List(0),
      nonce: sshPublicKey,
      info: _sshEd25519Label.codeUnits,
    );
    final tweakedSecretKey = await x25519.sharedSecretKey(
      keyPair: await x25519.newKeyPairFromSeed(tweak),
      remotePublicKey: SimplePublicKey(
        sharedSecretBytes,
        type: KeyPairType.x25519,
      ),
    );
    final tweakedSecret = await tweakedSecretKey.extractBytes();

    final wrappingKey = await _hkdf(
      secretKey: Uint8List.fromList(tweakedSecret),
      nonce: Uint8List.fromList(
        <int>[...ephemeralPublicKey.bytes, ...recipientPublicKey],
      ),
      info: _sshEd25519Label.codeUnits,
    );
    final wrappedKey = await AgeStanza.wrap(
      symmetricFileKey,
      SecretKeyData(wrappingKey),
    );

    return _SshEd25519AgeStanza(
      fingerprint: _sshFingerprint(sshPublicKey),
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublicKey.bytes),
      wrappedKey: wrappedKey,
    );
  }

  @override
  Future<String> serialize() async {
    final header = '-> $_sshEd25519RecipientPrefix $fingerprint '
        '${base64RawEncode(ephemeralPublicKey)}';
    return '$header\n${wrapAtPosition(base64RawEncode(wrappedKey))}';
  }

  @override
  Future<Uint8List> decryptedFileKey(AgeKeyPair? keyPair) async {
    if (keyPair == null || keyPair.identityBytes == null) {
      throw const FormatException('ssh-ed25519 key pair is required');
    }
    final privateScalar = _ed25519PrivateKeyToCurve25519(
      keyPair.identityBytes!,
    );
    final recipientPublicKey = _ed25519PublicKeyToCurve25519(
      keyPair.recipientBytes,
    );
    final x25519 = X25519();
    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: await x25519.newKeyPairFromSeed(privateScalar),
      remotePublicKey: SimplePublicKey(
        ephemeralPublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final sharedSecretBytes = await sharedSecret.extractBytes();
    if (sharedSecretBytes.every((byte) => byte == 0)) {
      throw const FormatException('ssh-ed25519 shared secret is all zero');
    }

    final sshPublicKey = _marshalSshEd25519PublicKey(keyPair.recipientBytes);
    final tweak = await _hkdf(
      secretKey: Uint8List(0),
      nonce: sshPublicKey,
      info: _sshEd25519Label.codeUnits,
    );
    final tweakedSecretKey = await x25519.sharedSecretKey(
      keyPair: await x25519.newKeyPairFromSeed(tweak),
      remotePublicKey: SimplePublicKey(
        sharedSecretBytes,
        type: KeyPairType.x25519,
      ),
    );
    final tweakedSecret = await tweakedSecretKey.extractBytes();
    final wrappingKey = await _hkdf(
      secretKey: Uint8List.fromList(tweakedSecret),
      nonce: Uint8List.fromList(
        <int>[...ephemeralPublicKey, ...recipientPublicKey],
      ),
      info: _sshEd25519Label.codeUnits,
    );
    return AgeStanza.unwrap(wrappedKey, SecretKeyData(wrappingKey));
  }
}

AgeRecipient _sshEd25519Recipient(Uint8List publicKey) {
  if (publicKey.length != 32) {
    throw FormatException(
      'recipient public key must be 32 bytes, got ${publicKey.length}',
    );
  }
  return AgeRecipient(_sshEd25519RecipientPrefix, copyBytes(publicKey));
}

Uint8List _ed25519PrivateKeySeed(Uint8List privateKey) {
  if (privateKey.length == 32) {
    return copyBytes(privateKey);
  }
  if (privateKey.length == 64) {
    return Uint8List.fromList(privateKey.sublist(0, 32));
  }
  throw FormatException(
    'ssh-ed25519 private key must be 32 or 64 bytes, got ${privateKey.length}',
  );
}

Uint8List _ed25519PrivateKeyToCurve25519(Uint8List privateKey) {
  final seed = _ed25519PrivateKeySeed(privateKey);
  final digest = crypto.sha512.convert(seed).bytes;
  final out = Uint8List.fromList(digest.sublist(0, 32));
  out[0] &= 248;
  out[31] &= 127;
  out[31] |= 64;
  return out;
}

Uint8List _ed25519PublicKeyToCurve25519(Uint8List publicKey) {
  final yBytes = Uint8List.fromList(publicKey);
  yBytes[31] &= 0x7f;
  final y = _littleEndianToBigInt(yBytes);
  if (y >= _ed25519Prime) {
    throw const FormatException('invalid Ed25519 public key');
  }
  final numerator = (BigInt.one + y) % _ed25519Prime;
  final denominator = (BigInt.one - y) % _ed25519Prime;
  if (denominator == BigInt.zero) {
    throw const FormatException('invalid Ed25519 public key');
  }
  final u = (numerator * denominator.modInverse(_ed25519Prime)) % _ed25519Prime;
  return _bigIntToLittleEndian(u, 32);
}

Uint8List _marshalSshEd25519PublicKey(Uint8List publicKey) {
  const keyType = 'ssh-ed25519';
  final typeBytes = keyType.codeUnits;
  final out = BytesBuilder(copy: false)
    ..add(_uint32Bytes(typeBytes.length))
    ..add(typeBytes)
    ..add(_uint32Bytes(publicKey.length))
    ..add(publicKey);
  return out.toBytes();
}

String _sshFingerprint(Uint8List sshPublicKey) {
  final sum = crypto.sha256.convert(sshPublicKey).bytes;
  return base64RawEncode(sum.sublist(0, 4));
}

Future<Uint8List> _hkdf({
  required Uint8List secretKey,
  required List<int> nonce,
  required List<int> info,
}) async {
  final key = await Hkdf(
    hmac: Hmac(Sha256()),
    outputLength: 32,
  ).deriveKey(
    secretKey: SecretKeyData(secretKey),
    nonce: nonce,
    info: info,
  );
  return Uint8List.fromList(await key.extractBytes());
}

Uint8List _uint32Bytes(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw FormatException('uint32 value out of range: $value');
  }
  return Uint8List.fromList(<int>[
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);
}

BigInt _littleEndianToBigInt(Uint8List bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

Uint8List _bigIntToLittleEndian(BigInt value, int length) {
  var remaining = value;
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  if (remaining != BigInt.zero) {
    throw const FormatException('integer does not fit target byte length');
  }
  return out;
}
