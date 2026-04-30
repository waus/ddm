import 'package:ddm_proto_dart/src/storage/migration.dart';
import 'package:ddm_proto_dart/src/storage/migrations/0001_init.dart';
import 'package:sqlite3/sqlite3.dart';

const List<StorageMigration> storageMigrations = <StorageMigration>[
  migration0001Init,
];

final class DatabaseMigrationException implements Exception {
  DatabaseMigrationException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return message;
    }
    return '$message: $cause';
  }
}

void runStorageMigrations(Database db) {
  try {
    _ensureSchemaVersionTable(db);
    final version = _readSchemaVersion(db);
    if (version.dirty) {
      throw DatabaseMigrationException(
        'database schema migration is dirty at version ${version.number}',
      );
    }
    if (storageMigrations.isNotEmpty &&
        version.number > storageMigrations.last.number) {
      throw DatabaseMigrationException(
        'database schema version ${version.number} is newer than supported '
        'version ${storageMigrations.last.number}',
      );
    }

    var current = version.number;
    for (final migration in storageMigrations) {
      if (migration.number <= current) {
        continue;
      }
      _applyMigration(db, migration);
      current = migration.number;
    }
  } on DatabaseMigrationException {
    rethrow;
  } catch (error) {
    throw DatabaseMigrationException('database migration failed', error);
  }
}

void _ensureSchemaVersionTable(Database db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS schema_version (
  number INTEGER NOT NULL,
  dirty BOOLEAN NOT NULL
);
''');
  db.execute('''
INSERT INTO schema_version(number, dirty)
SELECT 0, FALSE
WHERE NOT EXISTS (SELECT 1 FROM schema_version);
''');
}

_SchemaVersion _readSchemaVersion(Database db) {
  final row = db.select('SELECT number, dirty FROM schema_version LIMIT 1;');
  if (row.isEmpty) {
    throw DatabaseMigrationException('database schema version is missing');
  }
  final number = _asMigrationInt(row.first['number'], 'schema version number');
  final dirty = _asMigrationBool(row.first['dirty'], 'schema version dirty');
  return _SchemaVersion(number: number, dirty: dirty);
}

void _applyMigration(Database db, StorageMigration migration) {
  db.execute(
    'UPDATE schema_version SET number = ?, dirty = TRUE;',
    <Object?>[migration.number],
  );
  db.execute('BEGIN IMMEDIATE;');
  try {
    db.execute(migration.sql);
    db.execute(
      'UPDATE schema_version SET number = ?, dirty = FALSE;',
      <Object?>[migration.number],
    );
    db.execute('COMMIT;');
  } catch (error) {
    db.execute('ROLLBACK;');
    throw DatabaseMigrationException(
      'apply migration ${migration.name}',
      error,
    );
  }
}

int _asMigrationInt(Object? value, String label) {
  if (value is int) {
    return value;
  }
  if (value is BigInt) {
    return value.toInt();
  }
  throw DatabaseMigrationException('$label must be integer');
}

bool _asMigrationBool(Object? value, String label) {
  if (value is bool) {
    return value;
  }
  if (value is int) {
    return value != 0;
  }
  if (value is BigInt) {
    return value != BigInt.zero;
  }
  throw DatabaseMigrationException('$label must be boolean');
}

final class _SchemaVersion {
  const _SchemaVersion({required this.number, required this.dirty});

  final int number;
  final bool dirty;
}
