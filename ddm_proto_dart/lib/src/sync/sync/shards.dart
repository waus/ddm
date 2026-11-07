part of '../sync.dart';

final class ShardPolicy {
  ShardPolicy(
      {this.targetLeaves = targetShardLeaves,
      Iterable<StreamId> Function()? streams,
      UtcNow? nowUtc})
      : _nowUtc = nowUtc ?? defaultStorageUtcNow,
        _streams = streams,
        _anchor = StreamId(Random.secure().nextInt(0x100000000)) {
    if (targetLeaves <= 0) {
      throw ArgumentError.value(targetLeaves, 'targetLeaves');
    }
    for (final stream in _receiverStreams()) {
      _selections[stream.toUint32()] =
          StreamPrefix(stream.toHex().substring(0, minSplit));
    }
  }
  final UtcNow _nowUtc;
  DateTime? _lastReassessment;
  int _sequence = 0;
  final _observations = <String,
      ({DateTime at, int sequence, Map<int, StreamPrefix> selections})>{};
  final int targetLeaves;
  final Iterable<StreamId> Function()? _streams;
  final StreamId _anchor;
  Map<int, StreamPrefix> _selections = {};
  List<StreamPrefix> get coverage => normalizeCoverage(_selections.values);
  List<StreamId> _receiverStreams() {
    final own = _streams?.call().toList() ?? <StreamId>[];
    return own.isEmpty
        ? [_anchor]
        : {for (final stream in own) stream.toUint32(): stream}.values.toList();
  }

  Future<void> select(
      SyncSource source, SyncState state, BlobValidator validate,
      {bool local = false}) async {
    final sequence = ++_sequence;
    final observedAt = _nowUtc();
    var streams = _receiverStreams();
    final root = state.root;
    if (root != null && _sourceCheckSubtreeSize(root) > targetLeaves) {
      await checkSource(source: source, validateBlob: validate, snapshot: root);
    }
    final next = <int, StreamPrefix>{};
    for (final stream in streams) {
      final key = stream.toHex();
      var depth = minSplit;
      MessageIndexNode? node = root;
      while (node?.branch != null &&
          _sourceCheckSubtreeSize(node!) > targetLeaves &&
          depth < maxSplit) {
        final branch = node.branch!;
        var common = 0;
        while (common < branch.prefix.length &&
            common < maxSplit &&
            key[common] == branch.prefix[common]) {
          common++;
        }
        depth = max(depth, min(common + 1, maxSplit));
        if (common < branch.prefix.length || depth == maxSplit) break;
        final children = await _checkSourceLoadChildren(source, branch);
        node = children[int.parse(key[common], radix: 16)];
      }
      next[stream.toUint32()] = StreamPrefix(key.substring(0, depth));
    }
    // Account membership may change while a snapshot is being checked.
    streams = _receiverStreams();
    final now = _nowUtc();
    if (now.difference(observedAt) >= shardReassessmentInterval) return;
    _observations.removeWhere((_, observation) =>
        now.difference(observation.at) >= shardReassessmentInterval);
    final key = local ? 'local' : 'remote:${source.id}';
    if ((_observations[key]?.sequence ?? 0) > sequence) return;
    _observations[key] = (at: observedAt, sequence: sequence, selections: next);
    final expand = local &&
        (_lastReassessment == null ||
            now.difference(_lastReassessment!) >= shardReassessmentInterval);
    if (expand) _lastReassessment = now;
    final combined = <int, StreamPrefix>{};
    for (final stream in streams) {
      var prefix = StreamPrefix(stream.toHex().substring(0, minSplit));
      if (!expand) prefix = _selections[stream.toUint32()] ?? prefix;
      // The deepest snapshot choice equals thresholding the maximum count at each depth.
      for (final observation in _observations.values) {
        final candidate = observation.selections[stream.toUint32()];
        if (candidate != null && candidate.value.length > prefix.value.length) {
          prefix = candidate;
        }
      }
      combined[stream.toUint32()] = prefix;
    }
    _selections = combined;
  }
}
