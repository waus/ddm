import 'dart:math';

import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/sync/sync/registered_source.dart';
import 'package:ddm_proto_dart/src/sync/sync/sync_options.dart';

List<RegisteredSource> selectActiveSources(
  List<RegisteredSource> sources,
  DateTime now,
  int count, {
  SourcePermutation? permutation,
}) {
  if (count <= 0 || sources.isEmpty) {
    return const <RegisteredSource>[];
  }
  final limit = count > sources.length ? sources.length : count;
  final recentSince = now.toUtc().subtract(sourceOnlineWindow);
  final bad = <RegisteredSource>[];
  final old = <RegisteredSource>[];
  final healthyRecent = <RegisteredSource>[];
  final healthyOld = <RegisteredSource>[];

  for (final source in sources) {
    final onlineAt = source.lastOnlineAt;
    final recent = onlineAt != null && !onlineAt.isBefore(recentSince);
    if (source.rating < ratingDefault) {
      bad.add(source);
    }
    if (!recent) {
      old.add(source);
    }
    if (source.rating >= ratingDefault && recent) {
      healthyRecent.add(source);
    }
    if (source.rating >= ratingDefault && !recent) {
      healthyOld.add(source);
    }
  }

  final selected = <RegisteredSource>[];
  final seen = <RegisteredSource>{};
  final perm = permutation ?? randomSourcePermutation;
  _pickRegisteredSources(selected, seen, bad, limit ~/ 10, limit, perm);
  _pickRegisteredSources(selected, seen, old, limit ~/ 10, limit, perm);
  _pickRegisteredSources(
    selected,
    seen,
    healthyRecent,
    limit - selected.length,
    limit,
    perm,
  );
  _pickRegisteredSources(
    selected,
    seen,
    healthyOld,
    limit - selected.length,
    limit,
    perm,
  );
  _pickRegisteredSources(
      selected, seen, sources, limit - selected.length, limit, perm);
  return selected;
}

void _pickRegisteredSources(
  List<RegisteredSource> out,
  Set<RegisteredSource> seen,
  List<RegisteredSource> candidates,
  int quota,
  int limit,
  SourcePermutation permutation,
) {
  if (quota <= 0 || out.length >= limit) {
    return;
  }
  var picked = 0;
  for (final idx in permutation(candidates.length)) {
    final item = candidates[idx];
    if (seen.contains(item)) {
      continue;
    }
    out.add(item);
    seen.add(item);
    picked++;
    if (out.length >= limit || picked >= quota) {
      return;
    }
  }
}

List<int> randomSourcePermutation(int length) {
  final values = List<int>.generate(length, (idx) => idx);
  final random = Random.secure();
  for (var i = values.length - 1; i > 0; i--) {
    final j = random.nextInt(i + 1);
    final tmp = values[i];
    values[i] = values[j];
    values[j] = tmp;
  }
  return values;
}
