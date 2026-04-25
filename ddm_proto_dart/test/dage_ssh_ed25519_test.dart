import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:test/test.dart';

void main() {
  test('encryptForRecipientWithDage emits ssh-ed25519 age stanza', () async {
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();

    final ciphertext = await encryptForRecipientWithDage(
      recipient: Address.newV1(Uint8List.fromList(publicKey.bytes)),
      plaintext: Uint8List.fromList('hello'.codeUnits),
    );
    final header = _ageHeader(ciphertext);
    final stanzaLine = header
        .split('\n')
        .singleWhere((line) => line.startsWith('-> ssh-ed25519 '));
    final fields = stanzaLine.split(' ');

    expect(header.startsWith('age-encryption.org/v1\n'), isTrue);
    expect(fields, hasLength(4));
    expect(fields[1], 'ssh-ed25519');
    expect(fields[2], hasLength(6));
    expect(fields[3], hasLength(43));
  });

  test('ssh-ed25519 age payload decrypts with matching local key', () async {
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final privateKey = Uint8List(64)
      ..setRange(0, 32, seed)
      ..setRange(32, 64, publicKey.bytes);
    final plaintext = Uint8List.fromList('hello local inbox'.codeUnits);

    final ciphertext = await encryptForRecipientWithDage(
      recipient: Address.newV1(Uint8List.fromList(publicKey.bytes)),
      plaintext: plaintext,
    );
    final decrypted = await decryptForRecipientWithDage(
      privateKey: privateKey,
      publicKey: Uint8List.fromList(publicKey.bytes),
      ciphertext: ciphertext,
    );

    expect(utf8.decode(decrypted), 'hello local inbox');
  });
}

String _ageHeader(Uint8List ciphertext) {
  final marker = '\n--- '.codeUnits;
  final markerOffset = _indexOf(ciphertext, marker);
  if (markerOffset < 0) {
    throw const FormatException('age header mac line not found');
  }
  final headerEnd = ciphertext.indexOf(0x0a, markerOffset + 1);
  if (headerEnd < 0) {
    throw const FormatException('age header terminator not found');
  }
  return ascii.decode(ciphertext.sublist(0, headerEnd));
}

int _indexOf(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return i;
    }
  }
  return -1;
}
