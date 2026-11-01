DateTime defaultRuntimeUtcNow() => DateTime.now().toUtc();

int unixSecondsUint32(DateTime value) {
  final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xffffffff) {
    throw FormatException('unix timestamp out of uint32 range: $seconds');
  }
  return seconds;
}
