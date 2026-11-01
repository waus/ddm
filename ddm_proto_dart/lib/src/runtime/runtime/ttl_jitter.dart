import 'package:ddm_proto_dart/src/runtime/constants.dart';
import 'package:ddm_proto_dart/src/runtime/runtime/runtime_options.dart';
import 'package:ddm_proto_dart/src/runtime/runtime/secure_random.dart';

({Duration powTTL, Duration expiresTTL}) deriveJitteredTTLsWith(
  Duration base, {
  required DurationJitterDraw ttlDraw,
  required DurationJitterDraw expiresDraw,
}) {
  final ttlJitter = randomDurationJitterWith(
    base,
    ttlJitterDivisor,
    ttlDraw,
  );
  final powTTL = addDurationClamp(base, ttlJitter);
  final expiresTTL = addDurationClamp(
    base,
    randomDurationJitterUpTo(ttlJitter, expiresDraw),
  );
  return (powTTL: powTTL, expiresTTL: expiresTTL);
}

({int ttlSeconds, DateTime expiresAt}) deriveAckJitteredTTLWith({
  required DateTime createdAt,
  required int baseTTLSeconds,
  required DateTime baseExpiresAt,
  required DurationJitterDraw ttlDraw,
  required DurationJitterDraw expiresDraw,
}) {
  var baseTTL = Duration(seconds: baseTTLSeconds);
  if (baseTTL <= Duration.zero) {
    baseTTL = const Duration(seconds: 1);
  }
  final ttlJitter = randomDurationJitterWith(
    baseTTL,
    ttlJitterDivisor,
    ttlDraw,
  );
  var ackTTL = addDurationClamp(baseTTL, ttlJitter);
  if (ackTTL <= Duration.zero) {
    ackTTL = const Duration(seconds: 1);
  }

  var baseExpiresTTL = baseExpiresAt.toUtc().difference(createdAt.toUtc());
  if (baseExpiresTTL <= Duration.zero) {
    baseExpiresTTL = const Duration(seconds: 1);
  }
  var maxExpiresJitter = ackTTL - baseExpiresTTL;
  if (maxExpiresJitter > ttlJitter) {
    maxExpiresJitter = ttlJitter;
  }
  var ackExpiresTTL = addDurationClamp(
    baseExpiresTTL,
    randomDurationJitterUpTo(maxExpiresJitter, expiresDraw),
  );
  var ackTTLSeconds = ackTTL.inSeconds;
  if (ackTTLSeconds <= 0) {
    ackTTLSeconds = 1;
  }
  return (
    ttlSeconds: ackTTLSeconds,
    expiresAt: createdAt.toUtc().add(ackExpiresTTL),
  );
}

Duration addRandomTTLJitterWith(
  Duration base,
  DurationJitterDraw draw,
) {
  return addDurationClamp(
    base,
    randomDurationJitterWith(base, ttlJitterDivisor, draw),
  );
}

Duration addRandomDurationJitterWith(
  Duration base,
  int divisor,
  DurationJitterDraw draw,
) {
  return addDurationClamp(base, randomDurationJitterWith(base, divisor, draw));
}

Duration randomDurationJitterWith(
  Duration base,
  int divisor,
  DurationJitterDraw draw,
) {
  if (base <= Duration.zero || divisor <= 0) {
    return Duration.zero;
  }
  final maxJitter = Duration(microseconds: base.inMicroseconds ~/ divisor);
  return randomDurationJitterUpTo(maxJitter, draw);
}

Duration randomDurationJitterUpTo(
  Duration maxJitter,
  DurationJitterDraw draw,
) {
  if (maxJitter <= Duration.zero) {
    return Duration.zero;
  }
  var jitter = draw(maxJitter);
  if (jitter < Duration.zero) {
    jitter = Duration.zero;
  }
  if (jitter > maxJitter) {
    jitter = maxJitter;
  }
  return jitter;
}

Duration addDurationClamp(Duration base, Duration jitter) {
  if (base <= Duration.zero) {
    return base;
  }
  return base + jitter;
}

Duration randomDurationUpToInclusive(Duration max) {
  if (max <= Duration.zero) {
    return Duration.zero;
  }
  final value =
      secureRandomBigInt(BigInt.from(max.inMicroseconds) + BigInt.one);
  return Duration(microseconds: value);
}
