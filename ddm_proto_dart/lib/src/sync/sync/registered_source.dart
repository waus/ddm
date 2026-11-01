import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/storage/peers.dart';
import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/sync/sync/sync_options.dart';

final class RegisteredSource implements SyncSource {
  RegisteredSource({
    required SyncSource source,
    required DateTime createdAt,
    required double rating,
    DateTime? lastOnlineAt,
    DateTime? lastSavedAt,
  })  : _source = source,
        createdAt = createdAt.toUtc(),
        lastOnlineAt = lastOnlineAt?.toUtc(),
        lastSavedAt = lastSavedAt?.toUtc(),
        rating = rating.isNaN ? ratingDefault : rating;

  final SyncSource _source;
  final DateTime createdAt;
  DateTime? lastOnlineAt;
  DateTime? lastSavedAt;
  double rating;

  @override
  String get id => _source.id;

  @override
  SyncSourceFlags get flags => _source.flags;

  void decreaseRatingMul(double coefficient) {
    rating /= coefficient;
    if (rating.isNaN) {
      rating = 0;
    }
  }

  void increaseRatingConst(double coefficient) {
    rating += coefficient;
    if (rating.isNaN) {
      rating = ratingDefault;
    }
  }

  void markOnline(DateTime now) {
    final utc = now.toUtc();
    if (lastOnlineAt == null || utc.isAfter(lastOnlineAt!)) {
      lastOnlineAt = utc;
    }
  }

  bool onlineSince(DateTime cutoff) {
    final onlineAt = lastOnlineAt;
    return onlineAt != null && !onlineAt.isBefore(cutoff.toUtc());
  }

  bool shouldDrop(DateTime staleBefore, DateTime offlineStartupBefore) {
    final onlineAt = lastOnlineAt;
    if (onlineAt == null) {
      return createdAt.isBefore(offlineStartupBefore.toUtc());
    }
    return onlineAt.isBefore(staleBefore.toUtc());
  }

  PeerRecord? peerRecordForSave() {
    final onlineAt = lastOnlineAt;
    if (onlineAt == null) {
      return null;
    }
    final savedAt = lastSavedAt;
    if (savedAt != null && !onlineAt.isAfter(savedAt)) {
      return null;
    }
    return PeerRecord(
      id: id,
      createdAt: createdAt,
      lastOnlineAt: onlineAt,
      rating: rating,
    );
  }

  void markSaved(DateTime savedOnlineAt) {
    final onlineAt = lastOnlineAt;
    if (onlineAt != null && !onlineAt.isAfter(savedOnlineAt.toUtc())) {
      lastSavedAt = savedOnlineAt.toUtc();
    }
  }

  @override
  Future<List<ConfigRecord>> getConfigs() => _source.getConfigs();

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    final root = await _source.getMessageIndexRoot();
    if (root != null) {
      markOnline(DateTime.now().toUtc());
    }
    return root;
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) {
    return _source.getMessageIndexNode(id);
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) {
    return _source.getSyncBlobs(ids);
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) =>
      _source.push(blob, validationContext: validationContext);

  @override
  Future<List<String>> discoverPeers() => _source.discoverPeers();

  @override
  void stop() => _source.stop();
}
