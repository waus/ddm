import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final class ThemeModeToggleButton extends ConsumerWidget {
  const ThemeModeToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return Tooltip(
      message: _tooltip(themeMode),
      waitDuration: const Duration(milliseconds: 200),
      child: IconButton.filledTonal(
        icon: Icon(_icon(themeMode)),
        onPressed: () {
          ref.read(themeModeProvider.notifier).state = _nextMode(themeMode);
        },
      ),
    );
  }

  IconData _icon(ThemeMode themeMode) {
    switch (themeMode) {
      case ThemeMode.system:
        return Icons.brightness_6_outlined;
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.dark:
        return Icons.dark_mode;
    }
  }

  ThemeMode _nextMode(ThemeMode themeMode) {
    switch (themeMode) {
      case ThemeMode.system:
        return ThemeMode.light;
      case ThemeMode.light:
        return ThemeMode.dark;
      case ThemeMode.dark:
        return ThemeMode.system;
    }
  }

  String _tooltip(ThemeMode themeMode) {
    switch (themeMode) {
      case ThemeMode.system:
        return 'System theme';
      case ThemeMode.light:
        return 'Day theme';
      case ThemeMode.dark:
        return 'Night theme';
    }
  }
}
