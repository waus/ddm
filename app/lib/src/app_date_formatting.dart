String formatCompactDate(DateTime value) {
  final local = value.toLocal();
  final month = _twoDigits(local.month);
  final day = _twoDigits(local.day);
  return '$month/$day';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  final month = _twoDigits(local.month);
  final day = _twoDigits(local.day);
  final hour = _twoDigits(local.hour);
  final minute = _twoDigits(local.minute);
  return '${local.year}-$month-$day $hour:$minute';
}

String formatDateTimeWithSeconds(DateTime value) {
  final local = value.toLocal();
  final month = _twoDigits(local.month);
  final day = _twoDigits(local.day);
  final hour = _twoDigits(local.hour);
  final minute = _twoDigits(local.minute);
  final second = _twoDigits(local.second);
  return '${local.year}-$month-$day $hour:$minute:$second';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
