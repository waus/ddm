import 'package:ddm_proto_dart/src/storage/storage_clock.dart';

String normalizeAccountName(String accountName, UtcNow nowUtc) {
  final trimmed = accountName.trim();
  if (trimmed.isNotEmpty) {
    return trimmed;
  }
  return 'account-${nowUtc().toUtc().microsecondsSinceEpoch * 1000}';
}
