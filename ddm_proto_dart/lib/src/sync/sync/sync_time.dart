int syncUnixSeconds(DateTime value) {
  final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xffffffff) {
    throw FormatException('unix timestamp out of uint32 range: $seconds');
  }
  return seconds;
}
