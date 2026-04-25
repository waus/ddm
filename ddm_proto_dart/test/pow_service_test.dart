import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:test/test.dart';

void main() {
  test('VdfPowService solves and verifies fixed-width proofs', () async {
    const service = VdfPowService(
      progressInterval: Duration(milliseconds: 1),
    );
    final inputHash = _sha256('pow-payload');
    final progress = <PowSolveProgress>[];

    final result = await service.solve(
      modulus: _testPowModulus(),
      inputHash: inputHash,
      difficulty: 12,
      onProgress: progress.add,
    );

    expect(result.y, hasLength(powProofComponentSize));
    expect(result.pi, hasLength(powProofComponentSize));
    expect(result.elapsed, isNot(Duration.zero));
    expect(progress, isNotEmpty);
    expect(progress.first.completion, 0);
    expect(progress.last.completion, 1);

    var previous = 0.0;
    for (final item in progress) {
      expect(item.completion, inInclusiveRange(0, 1));
      expect(item.completion, greaterThanOrEqualTo(previous));
      previous = item.completion;
    }

    final verified = await service.verify(
      modulus: _testPowModulus(),
      inputHash: inputHash,
      difficulty: 12,
      y: result.y,
      pi: result.pi,
    );
    expect(verified, isTrue);
  });

  test('VdfPowService rejects tampered fixed-width proof', () async {
    const service = VdfPowService();
    final inputHash = _sha256('pow-payload');
    final result = await service.solve(
      modulus: _testPowModulus(),
      inputHash: inputHash,
      difficulty: 10,
    );

    final tamperedPi = Uint8List.fromList(result.pi);
    tamperedPi[powProofComponentSize - 1] ^= 0x01;

    final verified = await service.verify(
      modulus: _testPowModulus(),
      inputHash: inputHash,
      difficulty: 10,
      y: result.y,
      pi: tamperedPi,
    );
    expect(verified, isFalse);
  });

  test('calculateDifficulty matches Go compatibility cases', () {
    expect(
      calculateDifficulty(
        base: 2,
        scaleDivisor: 1,
        ttlSeconds: 10 * 60,
        payloadBytes: 100,
      ),
      2 * 3600 * (100 + 1024),
    );
    expect(
      calculateDifficulty(
        base: 1000,
        scaleDivisor: 7373,
        ttlSeconds: 3600,
        payloadBytes: 37888 - 1024,
      ),
      136396800000 ~/ 7373,
    );
    expect(
      calculateDifficulty(
        base: 1000,
        scaleDivisor: 7373,
        ttlSeconds: 3600,
        payloadBytes: 1024,
      ),
      inInclusiveRange(900000, 1100000),
    );
  });

  test('VdfPowService verifies Go-produced fixed-width proof vector', () async {
    const service = VdfPowService();
    final verified = await service.verify(
      modulus: _testPowModulus(),
      inputHash: _sha256('pow-payload'),
      difficulty: 12,
      y: _parseProofComponent(
        '4a7562e57c959590ac6a8245cb908b746d09fdc71013f0087ac1ac0686d03be7d7b2bc029e68ff7891c5ae2005a0d38a05a9dc8adc4036af96cc9cc09b706d82f7557adf8e62744782e1c8854c8ecd38b14d1513758ddfdb09a2a5b1809118e8d0e27346ba6d38436ce1e4dc73386cb5802ac7f32387de7058d713a0e6940252',
      ),
      pi: _parseProofComponent(
        '0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001',
      ),
    );

    expect(verified, isTrue);
  });
}

Uint8List _sha256(String value) {
  final digest = crypto.sha256.convert(utf8.encode(value));
  return Uint8List.fromList(digest.bytes);
}

Uint8List _testPowModulus() {
  return parseHexBytes(
    'dff91e2d2fe04b05c94cd448db087c86c1e8a3aa27147cc6a6a29bfb3dad8d85b24e4a4cc2a1a06531603f15f5a41d52b63a53a6d60d647faeb169a12e78d900f22c14bb32e18ab9d99d37403c1860d5b84c6fc0b53b462b9ef193762a84efe6872f72348e210e0584d521a26ee9f983473e2feefe1ff5470abf0f13ea3e8bbd',
    expectedBytes: powModulusSize,
    label: 'test pow modulus',
  );
}

Uint8List _parseProofComponent(String hex) {
  return parseHexBytes(
    hex,
    expectedBytes: powProofComponentSize,
    label: 'proof component',
  );
}
