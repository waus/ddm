enum SyncSourceErrorKind {
  unavailable,
  requestFailed,
  invalidResponse,
}

final class SyncSourceException implements Exception {
  const SyncSourceException._({
    required this.kind,
    required this.message,
    this.statusCode,
    this.details,
  });

  const SyncSourceException.unavailable([
    String message = 'sync source unavailable',
    Object? details,
  ]) : this._(
          kind: SyncSourceErrorKind.unavailable,
          message: message,
          details: details,
        );

  const SyncSourceException.requestFailed(
    this.message, {
    this.statusCode,
    this.details,
  }) : kind = SyncSourceErrorKind.requestFailed;

  const SyncSourceException.invalidResponse(
    this.message, {
    this.details,
  })  : kind = SyncSourceErrorKind.invalidResponse,
        statusCode = null;

  final SyncSourceErrorKind kind;
  final String message;
  final int? statusCode;
  final Object? details;

  @override
  String toString() {
    switch (kind) {
      case SyncSourceErrorKind.unavailable:
        return message;
      case SyncSourceErrorKind.requestFailed:
        final code = statusCode;
        if (code == null) {
          return 'sync source request failed: $message';
        }
        return 'sync source request failed ($code): $message';
      case SyncSourceErrorKind.invalidResponse:
        return 'sync source invalid response: $message';
    }
  }
}

bool isSyncSourceUnavailableError(Object error) {
  return error is SyncSourceException &&
      error.kind == SyncSourceErrorKind.unavailable;
}

bool isSyncSourceSourceFaultError(Object error) {
  return error is SyncSourceException &&
      error.kind != SyncSourceErrorKind.unavailable;
}
