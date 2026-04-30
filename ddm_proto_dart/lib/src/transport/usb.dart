import 'dart:io';

import 'package:ddm_proto_dart/src/transport/constants.dart';

bool get supportsExternalStorageDiscovery {
  return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}

Future<List<String>> findExternalStorageFiles() async {
  if (Platform.isMacOS) {
    return _findSyncFilesInChildDirs(const <String>['/Volumes']);
  }
  if (Platform.isLinux) {
    return _findSyncFilesInGrandchildDirs(const <String>[
      '/media',
      '/run/media',
    ]);
  }
  if (Platform.isWindows) {
    return _findRegularFiles(_windowsDriveSyncFiles());
  }
  return const <String>[];
}

Future<List<String>> _findSyncFilesInChildDirs(List<String> roots) async {
  final candidates = <String>[];
  for (final root in roots) {
    List<FileSystemEntity> entries;
    try {
      entries = Directory(root).listSync(followLinks: false);
    } on FileSystemException {
      continue;
    } on OSError {
      continue;
    }
    for (final entry in entries) {
      try {
        if (FileSystemEntity.typeSync(entry.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
      } on FileSystemException {
        continue;
      } on OSError {
        continue;
      }
      candidates.add(_joinPath(entry.path, syncDatabaseFileName));
    }
  }
  return _findRegularFiles(candidates);
}

Future<List<String>> _findSyncFilesInGrandchildDirs(List<String> roots) async {
  final candidates = <String>[];
  for (final root in roots) {
    List<FileSystemEntity> userEntries;
    try {
      userEntries = Directory(root).listSync(followLinks: false);
    } on FileSystemException {
      continue;
    } on OSError {
      continue;
    }
    for (final userEntry in userEntries) {
      FileSystemEntityType userType;
      try {
        userType =
            FileSystemEntity.typeSync(userEntry.path, followLinks: false);
      } on FileSystemException {
        continue;
      } on OSError {
        continue;
      }
      if (userType != FileSystemEntityType.directory) {
        continue;
      }

      List<FileSystemEntity> deviceEntries;
      try {
        deviceEntries = Directory(userEntry.path).listSync(followLinks: false);
      } on FileSystemException {
        continue;
      } on OSError {
        continue;
      }
      for (final deviceEntry in deviceEntries) {
        FileSystemEntityType deviceType;
        try {
          deviceType =
              FileSystemEntity.typeSync(deviceEntry.path, followLinks: false);
        } on FileSystemException {
          continue;
        } on OSError {
          continue;
        }
        if (deviceType != FileSystemEntityType.directory) {
          continue;
        }
        candidates.add(_joinPath(deviceEntry.path, syncDatabaseFileName));
      }
    }
  }
  return _findRegularFiles(candidates);
}

Future<List<String>> _findRegularFiles(Iterable<String> candidates) async {
  final files = <String>[];
  for (final candidate in candidates) {
    FileSystemEntityType type;
    try {
      type = FileSystemEntity.typeSync(candidate, followLinks: false);
    } on FileSystemException {
      continue;
    } on OSError {
      continue;
    }
    if (type == FileSystemEntityType.file) {
      files.add(Uri.file(candidate).toString());
    }
  }
  return files;
}

Iterable<String> _windowsDriveSyncFiles() sync* {
  for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
    yield '${String.fromCharCode(code)}:\\$syncDatabaseFileName';
  }
}

String _joinPath(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) {
    return '$parent$child';
  }
  return '$parent${Platform.pathSeparator}$child';
}
