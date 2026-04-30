import 'dart:io';

import 'package:image/image.dart' as image;

const _regularLogoPath = 'logo.png';
const _lowResolutionLogoPath = 'logo_low_resolution.png';
const _smallIconThreshold = 100;

const _windowsIconSizes = [16, 32, 48, 64, 128, 256];

Future<void> main() async {
  final projectDir = Directory.current;
  final regularLogo = _loadImage(projectDir, _regularLogoPath);
  final lowResolutionLogo = _loadImage(projectDir, _lowResolutionLogoPath);

  await _runFlutterLauncherIcons();
  await _restoreIosProjectSettings(projectDir);
  await _replaceSmallPngIcons(projectDir, lowResolutionLogo);
  await _generateWindowsIcon(projectDir, regularLogo, lowResolutionLogo);
  await _generateLinuxIcon(projectDir);
}

image.Image _loadImage(Directory projectDir, String path) {
  final file = File('${projectDir.path}/$path');
  final decoded = image.decodeImage(file.readAsBytesSync());
  if (decoded == null) {
    throw StateError('Failed to decode $path.');
  }
  return decoded;
}

Future<void> _runFlutterLauncherIcons() async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'flutter_launcher_icons'],
    runInShell: true,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0) {
    throw ProcessException(
      Platform.resolvedExecutable,
      ['run', 'flutter_launcher_icons'],
      'flutter_launcher_icons failed.',
      result.exitCode,
    );
  }
}

Future<void> _replaceSmallPngIcons(
  Directory projectDir,
  image.Image lowResolutionLogo,
) async {
  final iconDirectories = [
    Directory('${projectDir.path}/android/app/src/main/res'),
    Directory(
      '${projectDir.path}/ios/Runner/Assets.xcassets/AppIcon.appiconset',
    ),
    Directory(
      '${projectDir.path}/macos/Runner/Assets.xcassets/AppIcon.appiconset',
    ),
  ];

  for (final directory in iconDirectories) {
    if (!directory.existsSync()) {
      continue;
    }

    final iconFiles = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.png'));

    for (final file in iconFiles) {
      final bytes = file.readAsBytesSync();
      final decoded = image.decodePng(bytes);
      if (decoded == null) {
        continue;
      }

      if (decoded.width < _smallIconThreshold &&
          decoded.height < _smallIconThreshold) {
        final resized = _resize(lowResolutionLogo, decoded.width);
        await file.writeAsBytes(image.encodePng(resized));
      }
    }
  }
}

Future<void> _restoreIosProjectSettings(Directory projectDir) async {
  final projectFile = File(
    '${projectDir.path}/ios/Runner.xcodeproj/project.pbxproj',
  );
  if (!projectFile.existsSync()) {
    return;
  }

  final content = await projectFile.readAsString();
  await projectFile.writeAsString(
    content.replaceAll(
      'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon;',
      'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;',
    ),
  );
}

Future<void> _generateWindowsIcon(
  Directory projectDir,
  image.Image regularLogo,
  image.Image lowResolutionLogo,
) async {
  final icons = [
    for (final size in _windowsIconSizes)
      _resize(
        size < _smallIconThreshold ? lowResolutionLogo : regularLogo,
        size,
      ),
  ];

  final iconFile = File(
    '${projectDir.path}/windows/runner/resources/app_icon.ico',
  );
  await iconFile.writeAsBytes(image.IcoEncoder().encodeImages(icons));
}

Future<void> _generateLinuxIcon(Directory projectDir) async {
  final iconDirectory = Directory('${projectDir.path}/linux/runner/resources');
  await iconDirectory.create(recursive: true);

  final source = File('${projectDir.path}/$_regularLogoPath');
  final target = File('${iconDirectory.path}/app_icon.png');
  await source.copy(target.path);
}

image.Image _resize(image.Image source, int size) {
  return image.copyResize(
    source,
    width: size,
    height: size,
    interpolation: image.Interpolation.average,
  );
}
