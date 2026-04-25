import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/pow/pow_service.dart';
import 'package:vdfrsa/vdf.dart' as vdf;

final class VdfPowService implements PowService {
  const VdfPowService({
    this.progressInterval = const Duration(milliseconds: 200),
  });

  final Duration progressInterval;

  @override
  Future<PowSolveResult> solve({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    void Function(PowSolveProgress progress)? onProgress,
  }) async {
    final engine = _newWesolowski(modulus, difficulty);
    final startedAt = Stopwatch()..start();

    final proof = await engine.proveAsync(
      copyBytes(inputHash),
      difficulty,
      progressInterval: progressInterval,
      onProgress: onProgress == null
          ? null
          : (progress) {
              onProgress(
                PowSolveProgress(
                  completion: _normalizeCompletion(progress.completion),
                  elapsed: progress.elapsed,
                ),
              );
            },
    );

    return PowSolveResult(
      y: _normalizeProofComponent(proof.y, 'proof Y'),
      pi: _normalizeProofComponent(proof.pi, 'proof Pi'),
      elapsed: startedAt.elapsed,
    );
  }

  @override
  Future<bool> verify({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    required Uint8List y,
    required Uint8List pi,
  }) async {
    final engine = _newWesolowski(modulus, difficulty);
    _requireProofComponent(y, 'proof Y');
    _requireProofComponent(pi, 'proof Pi');

    return engine.verify(
      copyBytes(inputHash),
      difficulty,
      vdf.Proof(
        y: _trimLeadingZeros(y),
        pi: _trimLeadingZeros(pi),
      ),
    );
  }
}

vdf.Wesolowski _newWesolowski(Uint8List modulus, int difficulty) {
  _requireDifficulty(difficulty);
  if (modulus.length != powModulusSize) {
    throw FormatException('pow modulus must be $powModulusSize bytes');
  }
  final engine = vdf.Wesolowski.withModulus(
    _bigIntFromBytes(modulus),
    powProofComponentSize,
  );
  _logNativeBackendStatus(engine);
  return engine;
}

var _nativeBackendStatusLogged = false;

void _logNativeBackendStatus(vdf.Wesolowski engine) {
  if (_nativeBackendStatusLogged) {
    return;
  }
  _nativeBackendStatusLogged = true;
  final loadError = vdf.VdfNativeBackend.loadError;
  stderr.writeln(
    '${DateTime.now().toIso8601String()} [ddm:pow] '
    'vdf native backend active=${engine.hasNativeBackend} '
    'load_error=${loadError ?? 'none'}',
  );
}

void _requireDifficulty(int difficulty) {
  const maxInt = 0x7fffffffffffffff;
  if (difficulty < 0) {
    throw FormatException(
        'vdf difficulty must be non-negative, got $difficulty');
  }
  if (difficulty > maxInt) {
    throw FormatException('vdf difficulty $difficulty exceeds int range');
  }
}

Uint8List _normalizeProofComponent(Uint8List raw, String label) {
  if (raw.isEmpty) {
    throw FormatException('$label must not be empty');
  }
  if (raw.length > powProofComponentSize) {
    throw FormatException(
      '$label exceeds $powProofComponentSize bytes: ${raw.length}',
    );
  }
  final out = Uint8List(powProofComponentSize);
  out.setRange(powProofComponentSize - raw.length, powProofComponentSize, raw);
  return out;
}

void _requireProofComponent(Uint8List raw, String label) {
  if (raw.length != powProofComponentSize) {
    throw FormatException(
      '$label must be $powProofComponentSize bytes, got ${raw.length}',
    );
  }
}

Uint8List _trimLeadingZeros(Uint8List raw) {
  var firstNonZero = 0;
  while (firstNonZero < raw.length && raw[firstNonZero] == 0) {
    firstNonZero++;
  }
  if (firstNonZero == raw.length) {
    return Uint8List.fromList(<int>[0]);
  }
  return Uint8List.sublistView(raw, firstNonZero);
}

BigInt _bigIntFromBytes(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

double _normalizeCompletion(double completion) {
  if (completion <= 0) {
    return 0;
  }
  if (completion >= 1) {
    return 1;
  }
  return completion;
}
