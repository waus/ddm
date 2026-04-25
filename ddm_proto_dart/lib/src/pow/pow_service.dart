import 'dart:typed_data';

abstract interface class PowService {
  Future<PowSolveResult> solve({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    void Function(PowSolveProgress progress)? onProgress,
  });

  Future<bool> verify({
    required Uint8List modulus,
    required Uint8List inputHash,
    required int difficulty,
    required Uint8List y,
    required Uint8List pi,
  });
}

final class PowSolveResult {
  const PowSolveResult({
    required this.y,
    required this.pi,
    required this.elapsed,
  });

  final Uint8List y;
  final Uint8List pi;
  final Duration elapsed;
}

final class PowSolveProgress {
  const PowSolveProgress({required this.completion, required this.elapsed});

  final double completion;
  final Duration elapsed;
}
