import 'package:ddm_proto_dart/src/storage/storage.dart';
import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/sync/sync/registered_source.dart';
import 'package:ddm_proto_dart/src/sync/sync/source_selection.dart';
import 'package:ddm_proto_dart/src/sync/sync/sync_options.dart';

final class SourceRegistry {
  SourceRegistry({
    required DdmSqliteStorage storage,
    required UtcNow nowUtc,
    SourcePermutation? permutation,
  })  : _storage = storage,
        _nowUtc = nowUtc,
        _permutation = permutation ?? randomSourcePermutation;

  final DdmSqliteStorage _storage;
  final UtcNow _nowUtc;
  final SourcePermutation _permutation;
  final Map<String, RegisteredSource> _sources = <String, RegisteredSource>{};

  bool add(SyncSource source) {
    if (_sources.containsKey(source.id)) {
      return false;
    }
    _sources[source.id] = _newRegisteredSource(source);
    return true;
  }

  RegisteredSource addOrGet(SyncSource source) {
    final existing = _sources[source.id];
    if (existing != null) {
      source.stop();
      return existing;
    }
    final registered = _newRegisteredSource(source);
    _sources[source.id] = registered;
    return registered;
  }

  bool addStored(SyncSource source, PeerRecord peer) {
    if (_sources.containsKey(source.id)) {
      return false;
    }
    _sources[source.id] = RegisteredSource(
      source: source,
      createdAt: peer.createdAt,
      lastOnlineAt: peer.lastOnlineAt,
      lastSavedAt: peer.lastOnlineAt,
      rating: peer.rating,
    );
    return true;
  }

  List<RegisteredSource> getActive(int count) {
    final now = _nowUtc();
    final staleBefore = now.subtract(sourceRetention);
    final offlineStartupBefore = now.subtract(sourceOfflineStartup);
    final removed = <String>[];
    for (final item in _sources.entries) {
      if (item.value.shouldDrop(staleBefore, offlineStartupBefore)) {
        item.value.stop();
        removed.add(item.key);
      }
    }
    for (final id in removed) {
      _sources.remove(id);
    }
    return selectActiveSources(
      _sources.values.toList(growable: false),
      now,
      count,
      permutation: _permutation,
    );
  }

  int onlineCountSince(DateTime cutoff) {
    return _sources.values.where((source) => source.onlineSince(cutoff)).length;
  }

  List<SyncSource> peerExchangeSources() {
    return _sources.values
        .where((source) => source.flags.has(syncSourceFlagSupportPeerExchange))
        .toList(growable: false);
  }

  List<String> sourceIds() {
    return _sources.keys.toList(growable: false)..sort();
  }

  void saveUpdatedPeers() {
    final records = <PeerRecord>[];
    for (final source in _sources.values) {
      final record = source.peerRecordForSave();
      if (record != null) {
        records.add(record);
      }
    }
    _storage.peers.upsertPeers(records);
    _storage.peers
        .deletePeersLastOnlineBefore(_nowUtc().subtract(sourceRetention));
    for (final record in records) {
      _sources[record.id]?.markSaved(record.lastOnlineAt!);
    }
  }

  void close() {
    for (final source in _sources.values) {
      source.stop();
    }
  }

  RegisteredSource _newRegisteredSource(SyncSource source) {
    return RegisteredSource(
      source: source,
      createdAt: _nowUtc(),
      rating: ratingDefault,
    );
  }
}
