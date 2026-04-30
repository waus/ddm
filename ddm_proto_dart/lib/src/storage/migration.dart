final class StorageMigration {
  const StorageMigration({
    required this.number,
    required this.name,
    required this.sql,
  });

  final int number;
  final String name;
  final String sql;
}
