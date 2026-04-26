import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'app_shortcuts.dart';
import 'app_theme.dart';
import 'desktop_layout.dart';
import 'mobile_layout.dart';
import 'theme_mode_toggle.dart';

const desktopLayoutMinWidth = 900.0;

/// Light [ColorScheme] made with FlexColorScheme v8.4.0.
/// Requires Flutter 3.22.0 or later.
const ColorScheme lightColorScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF172234),
  onPrimary: Color(0xFFF8FAFC),
  primaryContainer: Color(0xFFE6ECF5),
  onPrimaryContainer: Color(0xFF111827),
  primaryFixed: Color(0xFFCBD5E1),
  primaryFixedDim: Color(0xFF94A3B8),
  onPrimaryFixed: Color(0xFF0F172A),
  onPrimaryFixedVariant: Color(0xFF334155),
  secondary: Color(0xFFE9EEF6),
  onSecondary: Color(0xFF172234),
  secondaryContainer: Color(0xFFDDE5F0),
  onSecondaryContainer: Color(0xFF172234),
  secondaryFixed: Color(0xFFF8FAFC),
  secondaryFixedDim: Color(0xFFE2E8F0),
  onSecondaryFixed: Color(0xFF334155),
  onSecondaryFixedVariant: Color(0xFF64748B),
  tertiary: Color(0xFFE7EAEE),
  onTertiary: Color(0xFF1F2937),
  tertiaryContainer: Color(0xFFD8DEE7),
  onTertiaryContainer: Color(0xFF111827),
  tertiaryFixed: Color(0xFFF8FAFC),
  tertiaryFixedDim: Color(0xFFE5E7EB),
  onTertiaryFixed: Color(0xFF374151),
  onTertiaryFixedVariant: Color(0xFF6B7280),
  error: Color(0xFFB42318),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFEE4E2),
  onErrorContainer: Color(0xFF7A271A),
  surface: Color(0xFFF7F8FA),
  onSurface: Color(0xFF111827),
  surfaceDim: Color(0xFFD9DEE7),
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF3F5F8),
  surfaceContainer: Color(0xFFEEF1F5),
  surfaceContainerHigh: Color(0xFFE5E9EF),
  surfaceContainerHighest: Color(0xFFDCE2EA),
  onSurfaceVariant: Color(0xFF4B5563),
  outline: Color(0xFF8A94A3),
  outlineVariant: Color(0xFFCBD2DC),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFF1A2230),
  onInverseSurface: Color(0xFFF8FAFC),
  inversePrimary: Color(0xFFB6C2D2),
  surfaceTint: Color(0xFF172234),
);
const ColorScheme darkColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFE5EAF2),
  onPrimary: Color(0xFF0F1724),
  primaryContainer: Color(0xFF263548),
  onPrimaryContainer: Color(0xFFEAF0F8),
  primaryFixed: Color(0xFFCBD5E1),
  primaryFixedDim: Color(0xFF94A3B8),
  onPrimaryFixed: Color(0xFF0F172A),
  onPrimaryFixedVariant: Color(0xFF334155),
  secondary: Color(0xFF253142),
  onSecondary: Color(0xFFE5EAF2),
  secondaryContainer: Color(0xFF202B3A),
  onSecondaryContainer: Color(0xFFE5EAF2),
  secondaryFixed: Color(0xFF334155),
  secondaryFixedDim: Color(0xFF243244),
  onSecondaryFixed: Color(0xFFE5EAF2),
  onSecondaryFixedVariant: Color(0xFFCBD5E1),
  tertiary: Color(0xFF283341),
  onTertiary: Color(0xFFE5E7EB),
  tertiaryContainer: Color(0xFF202936),
  onTertiaryContainer: Color(0xFFE5E7EB),
  tertiaryFixed: Color(0xFF374151),
  tertiaryFixedDim: Color(0xFF26303D),
  onTertiaryFixed: Color(0xFFE5E7EB),
  onTertiaryFixedVariant: Color(0xFFD1D5DB),
  error: Color(0xFFDC2626),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFF4A1212),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF101821),
  onSurface: Color(0xFFE7ECF3),
  surfaceDim: Color(0xFF0B1118),
  surfaceBright: Color(0xFF253142),
  surfaceContainerLowest: Color(0xFF070B10),
  surfaceContainerLow: Color(0xFF0D141C),
  surfaceContainer: Color(0xFF121C26),
  surfaceContainerHigh: Color(0xFF182332),
  surfaceContainerHighest: Color(0xFF223044),
  onSurfaceVariant: Color(0xFFB7C0CC),
  outline: Color(0xFF6B7788),
  outlineVariant: Color(0xFF344253),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFE6EAF0),
  onInverseSurface: Color(0xFF172234),
  inversePrimary: Color(0xFF526177),
  surfaceTint: Color(0xFFE5EAF2),
);

final class DdmApp extends ConsumerWidget {
  const DdmApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'DDM',
      debugShowCheckedModeBanner: false,
      themeMode: ref.watch(themeModeProvider),
      theme: buildAppTheme(lightColorScheme),
      darkTheme: buildAppTheme(darkColorScheme),
      home: const AppShell(),
    );
  }
}

final class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

final class _AppShellState extends ConsumerState<AppShell> {
  static const _appMenuChannel = MethodChannel('ddm/app_menu');

  @override
  void initState() {
    super.initState();
    _appMenuChannel.setMethodCallHandler(_handleAppMenuCall);
  }

  @override
  void dispose() {
    _appMenuChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleAppMenuCall(MethodCall call) async {
    if (call.method != 'newMessage') {
      throw MissingPluginException(
          'Unsupported app menu method ${call.method}');
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    Actions.maybeInvoke(
      focusedContext ?? context,
      const NewMessageIntent(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktopLayout = constraints.maxWidth >= desktopLayoutMinWidth;
        return isDesktopLayout
            ? DesktopLayout(state: state)
            : MobileLayout(state: state);
      },
    );
  }
}
