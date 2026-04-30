import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

const updateCheckEndpoint = 'https://ddm.waus.app/update';
const updateSiteUrl = 'https://ddm.waus.app';

typedef PackageInfoLoader = Future<PackageInfo> Function();

final class AppVersion {
  const AppVersion({
    required this.version,
    required this.os,
    required this.arch,
  });

  final String version;
  final String os;
  final String arch;

  String get displayText => version;
}

final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.lastVersion,
    required this.mandatoryUpdate,
  });

  final String lastVersion;
  final bool mandatoryUpdate;

  bool isNewerThan(String currentVersion) {
    final current = _parseSemver(currentVersion);
    final latest = _parseSemver(lastVersion);
    if (current == null || latest == null) {
      return lastVersion.trim() != currentVersion.trim();
    }
    for (var i = 0; i < latest.length; i++) {
      if (latest[i] > current[i]) {
        return true;
      }
      if (latest[i] < current[i]) {
        return false;
      }
    }
    return false;
  }
}

Future<AppVersion> loadCurrentAppVersion({
  PackageInfoLoader packageInfoLoader = PackageInfo.fromPlatform,
}) async {
  final packageInfo = await packageInfoLoader();
  return AppVersion(
    version: packageInfo.version,
    os: currentUpdateOs(),
    arch: currentUpdateArch(),
  );
}

Future<UpdateCheckResult?> checkForUpdate(AppVersion currentVersion) async {
  final endpoint = Uri.parse(updateCheckEndpoint).replace(
    queryParameters: <String, String>{
      'version': currentVersion.version,
      'os': currentVersion.os,
      'arch': currentVersion.arch,
    },
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(endpoint);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Update check failed with HTTP ${response.statusCode}',
        uri: endpoint,
      );
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Update response must be a JSON object');
    }
    final lastVersion = decoded['last_version'];
    final mandatoryUpdate = decoded['mandatory_update'];
    if (lastVersion is! String || mandatoryUpdate is! bool) {
      throw const FormatException('Update response has invalid fields');
    }
    return UpdateCheckResult(
      lastVersion: lastVersion,
      mandatoryUpdate: mandatoryUpdate,
    );
  } finally {
    client.close(force: true);
  }
}

String currentUpdateOs() {
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  if (Platform.isIOS) {
    return 'ios';
  }
  return Platform.operatingSystem;
}

String currentUpdateArch() {
  return switch (Abi.current()) {
    Abi.androidArm => 'armv7',
    Abi.androidArm64 => 'arm64',
    Abi.androidIA32 => 'x86',
    Abi.androidX64 => 'x64',
    Abi.linuxArm => 'armv7',
    Abi.linuxArm64 => 'arm64',
    Abi.linuxIA32 => 'x86',
    Abi.linuxX64 => 'x64',
    Abi.linuxRiscv32 => 'riscv32',
    Abi.linuxRiscv64 => 'riscv64',
    Abi.macosArm64 => 'arm64',
    Abi.macosX64 => 'x64',
    Abi.windowsArm64 => 'arm64',
    Abi.windowsIA32 => 'x86',
    Abi.windowsX64 => 'x64',
    Abi.iosArm => 'armv7',
    Abi.iosArm64 => 'arm64',
    Abi.iosX64 => 'x64',
    _ => Abi.current().toString(),
  };
}

List<int>? _parseSemver(String value) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[+-].*)?$').firstMatch(
    value.trim(),
  );
  if (match == null) {
    return null;
  }
  return <int>[
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}
