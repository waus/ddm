import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'src/ddm_app.dart';

const _desktopWindowWidthKey = 'desktop_window_width';
const _desktopWindowHeightKey = 'desktop_window_height';
const _desktopWindowOffsetXKey = 'desktop_window_offset_x';
const _desktopWindowOffsetYKey = 'desktop_window_offset_y';
const _minimumWindowWidth = 320.0;
const _minimumWindowHeight = 480.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_supportsManagedDesktopWindow()) {
    await _configureDesktopWindow();
  }
  runApp(const ProviderScope(child: DdmApp()));
}

bool _supportsManagedDesktopWindow() {
  return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}

Future<void> _configureDesktopWindow() async {
  await windowManager.ensureInitialized();

  final preferences = SharedPreferencesAsync();
  final savedWidth = await preferences.getDouble(_desktopWindowWidthKey);
  final savedHeight = await preferences.getDouble(_desktopWindowHeightKey);
  final savedOffsetX = await preferences.getDouble(_desktopWindowOffsetXKey);
  final savedOffsetY = await preferences.getDouble(_desktopWindowOffsetYKey);

  final restoredSize = savedWidth != null && savedHeight != null
      ? Size(savedWidth, savedHeight)
      : const Size(1280, 800);
  final restoredPosition = savedOffsetX != null && savedOffsetY != null
      ? Offset(savedOffsetX, savedOffsetY)
      : null;

  await windowManager.setMinimumSize(
    const Size(_minimumWindowWidth, _minimumWindowHeight),
  );
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: restoredPosition == null ? restoredSize : null,
      center: restoredPosition == null,
      backgroundColor: Colors.transparent,
    ),
  );
  if (restoredPosition != null) {
    await windowManager.setBounds(restoredPosition & restoredSize);
  }
  windowManager.addListener(_WindowStatePersistence(preferences));
  await windowManager.show();
  await windowManager.focus();
}

final class _WindowStatePersistence with WindowListener {
  _WindowStatePersistence(this._preferences);

  final SharedPreferencesAsync _preferences;
  Timer? _saveDebounce;

  @override
  void onWindowMoved() {
    _scheduleSave();
  }

  @override
  void onWindowResized() {
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();
      await _preferences.setDouble(_desktopWindowWidthKey, size.width);
      await _preferences.setDouble(_desktopWindowHeightKey, size.height);
      await _preferences.setDouble(_desktopWindowOffsetXKey, position.dx);
      await _preferences.setDouble(_desktopWindowOffsetYKey, position.dy);
    });
  }
}
