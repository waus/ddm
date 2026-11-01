part of '../runtime.dart';

final class ContactsService {
  ContactsService({required DdmSqliteStorage storage}) : _storage = storage;

  final DdmSqliteStorage _storage;

  ContactRecord addContact({
    required AccountRecord account,
    required String name,
    required Address address,
  }) {
    final local = _requireLocalAccount(account);
    return _storage.contacts.upsertContact(
      ContactInsert(
        address: address.toText(),
        account: local.address,
        name: name,
        approved: true,
      ),
    );
  }

  List<ContactRecord> listContacts(AccountRecord account) {
    final local = _requireLocalAccount(account);
    return _storage.contacts.listContacts(local.address);
  }

  bool deleteContact({
    required AccountRecord account,
    required Address address,
  }) {
    final local = _requireLocalAccount(account);
    return _storage.contacts.deleteContact(
      account: local.address,
      address: address.toText(),
    );
  }

  AccountRecord _requireLocalAccount(AccountRecord account) {
    final parsed = Address.fromText(account.address);
    final local = _storage.accounts.getAccountByAddress(parsed.toText());
    if (local == null) {
      throw FormatException(
        'account address ${parsed.toText()} not found in local db',
      );
    }
    return local;
  }
}
