import 'constants.dart';
import 'message_index_node.dart';
import 'stream.dart';

final class StreamPrefix {
  StreamPrefix(String value) : value = value {
    if (value.length > streamPrefixMaxLength ||
        !RegExp(r'^[0-9a-f]*$').hasMatch(value)) {
      throw FormatException('invalid stream prefix: $value');
    }
  }
  final String value;
  bool contains(StreamPrefix other) => other.value.startsWith(value);
  bool matches(StreamId stream) => stream.toHex().startsWith(value);
  @override
  bool operator ==(Object other) =>
      other is StreamPrefix && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

List<StreamPrefix> normalizeCoverage(Iterable<StreamPrefix> prefixes) {
  final sorted = prefixes.toList()..sort((a, b) => a.value.compareTo(b.value));
  final out = <StreamPrefix>[];
  for (final p in sorted) {
    if (out.isEmpty || !out.last.contains(p)) out.add(p);
  }
  return List.unmodifiable(out);
}

List<StreamPrefix> intersectCoverage(
        Iterable<StreamPrefix> a, Iterable<StreamPrefix> b) =>
    normalizeCoverage([
      for (final x in a)
        for (final y in b)
          if (x.contains(y)) y else if (y.contains(x)) x,
    ]);

final class SyncState {
  SyncState({required this.root, required Iterable<StreamPrefix> coverage})
      : coverage = normalizeCoverage(coverage) {
    root?.validate();
    if (coverage.length > maxSyncCoveragePrefixes) {
      throw const FormatException('too many coverage prefixes');
    }
  }
  final MessageIndexNode? root;
  final List<StreamPrefix> coverage;
}
