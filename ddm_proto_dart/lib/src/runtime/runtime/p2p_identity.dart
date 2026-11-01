part of '../runtime.dart';

final class P2pIdentityService {
  P2pIdentityService({required DdmSqliteStorage storage}) : _storage = storage;

  final DdmSqliteStorage _storage;

  Uint8List? getPrivateKey() => _storage.p2pIdentity.getPrivateKey();

  Future<Uint8List> loadOrCreatePrivateKey({
    P2pPrivateKeyGenerator? generatePrivateKey,
  }) async {
    final existing = _storage.p2pIdentity.getPrivateKey();
    if (existing != null) {
      return Uint8List.fromList(existing);
    }
    final generated =
        await (generatePrivateKey ?? generateP2pPrivateKey).call();
    if (generated.isEmpty) {
      throw const FormatException('p2p private key must not be empty');
    }
    _storage.p2pIdentity.upsertPrivateKey(generated);
    return Uint8List.fromList(generated);
  }
}
