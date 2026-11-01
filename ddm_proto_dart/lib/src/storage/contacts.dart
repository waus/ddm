import 'package:ddm_proto_dart/src/storage/storage_clock.dart';
import 'package:ddm_proto_dart/src/storage/storage_value_codec.dart';
import 'package:sqlite3/sqlite3.dart';

final class ContactInsert {
  ContactInsert({
    required this.address,
    required this.account,
    this.name = '',
    this.approved = false,
    this.lastDeliveryTime = '',
    this.trust = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String address;
  final String account;
  final String name;
  final bool approved;
  final String lastDeliveryTime;
  final int trust;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

final class ContactRecord {
  ContactRecord({
    required this.id,
    required this.address,
    required this.account,
    required this.name,
    required this.approved,
    required this.lastDeliveryTime,
    required this.trust,
    required DateTime createdAt,
    required DateTime updatedAt,
  })  : createdAt = createdAt.toUtc(),
        updatedAt = updatedAt.toUtc();

  final int id;
  final String address;
  final String account;
  final String name;
  final bool approved;
  final String lastDeliveryTime;
  final int trust;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class ContactsRepository {
  ContactsRepository(this._db, this._nowUtc);

  final Database _db;
  final UtcNow _nowUtc;

  ContactRecord upsertContact(ContactInsert input) {
    final address = input.address.trim();
    if (address.isEmpty) {
      throw const FormatException('contact address must not be empty');
    }
    final account = input.account.trim();
    if (account.isEmpty) {
      throw const FormatException('contact account must not be empty');
    }
    final createdAt = (input.createdAt ?? _nowUtc()).toUtc();
    final updatedAt = (input.updatedAt ?? _nowUtc()).toUtc();

    _db.execute(
      '''
INSERT INTO contacts(address, account, name, approved, last_delivery_time, trust, created_at, updated_at)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(address, account) DO UPDATE SET
  name = CASE WHEN excluded.approved != 0 THEN excluded.name ELSE contacts.name END,
  approved = CASE WHEN excluded.approved != 0 THEN 1 ELSE contacts.approved END,
  updated_at = CASE WHEN excluded.approved != 0 THEN excluded.updated_at ELSE contacts.updated_at END;
''',
      <Object?>[
        address,
        account,
        input.name.trim(),
        input.approved ? 1 : 0,
        input.lastDeliveryTime,
        input.trust,
        formatStoredTime(createdAt),
        formatStoredTime(updatedAt),
      ],
    );
    final contact = getContact(account: account, address: address);
    if (contact == null) {
      throw StateError('contact was not stored');
    }
    return contact;
  }

  ContactRecord? getContact({
    required String account,
    required String address,
  }) {
    final rows = _db.select(
      '''
SELECT id, address, account, name, approved, last_delivery_time, trust, created_at, updated_at
FROM contacts
WHERE account = ? AND address = ?;
''',
      <Object?>[account.trim(), address.trim()],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _scanContact(rows.first);
  }

  List<ContactRecord> listContacts(String account) {
    final rows = _db.select(
      '''
SELECT id, address, account, name, approved, last_delivery_time, trust, created_at, updated_at
FROM contacts
WHERE account = ?
ORDER BY name COLLATE NOCASE ASC, created_at ASC, id ASC;
''',
      <Object?>[account.trim()],
    );
    return rows.map(_scanContact).toList(growable: false);
  }

  bool deleteContact({
    required String account,
    required String address,
  }) {
    final rows = _db.select(
      '''
DELETE FROM contacts
WHERE account = ? AND address = ?
RETURNING id;
''',
      <Object?>[account.trim(), address.trim()],
    );
    return rows.isNotEmpty;
  }

  ContactRecord _scanContact(Row row) {
    return ContactRecord(
      id: asInt(row['id'], 'contact id'),
      address: asString(row['address'], 'contact address'),
      account: asString(row['account'], 'contact account'),
      name: asString(row['name'], 'contact name'),
      approved: asInt(row['approved'], 'contact approved') != 0,
      lastDeliveryTime: asString(
        row['last_delivery_time'],
        'contact last_delivery_time',
      ),
      trust: asInt(row['trust'], 'contact trust'),
      createdAt: parseStoredTime(
        asString(row['created_at'], 'contact created_at'),
        'contact created_at',
      ),
      updatedAt: parseStoredTime(
        asString(row['updated_at'], 'contact updated_at'),
        'contact updated_at',
      ),
    );
  }
}
