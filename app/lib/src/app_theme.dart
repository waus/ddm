import 'package:flutter/material.dart';

const _buttonRadius = 4.0;
const _dialogRadius = 8.0;
const _navigationItemRadius = 4.0;

const appShapeTheme = AppShapeTheme(
  buttonRadius: _buttonRadius,
  dialogRadius: _dialogRadius,
  navigationItemRadius: _navigationItemRadius,
);

const _buttonShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(_buttonRadius)),
);
const _dialogShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(_dialogRadius)),
);
const _buttonStyle = ButtonStyle(
  shape: WidgetStatePropertyAll<OutlinedBorder>(_buttonShape),
);

InputDecoration multilineTextFieldDecoration(
  BuildContext context, {
  required String labelText,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  final enabledBorder = OutlineInputBorder(
    borderRadius: appShapesOf(context).buttonBorderRadius,
    borderSide: BorderSide(color: colorScheme.outlineVariant),
  );
  final focusedBorder = OutlineInputBorder(
    borderRadius: appShapesOf(context).buttonBorderRadius,
    borderSide: BorderSide(color: colorScheme.primary),
  );
  final errorBorder = OutlineInputBorder(
    borderRadius: appShapesOf(context).buttonBorderRadius,
    borderSide: BorderSide(color: colorScheme.error),
  );
  return InputDecoration(
    labelText: labelText,
    alignLabelWithHint: true,
    border: enabledBorder,
    enabledBorder: enabledBorder,
    focusedBorder: focusedBorder,
    errorBorder: errorBorder,
    focusedErrorBorder: errorBorder,
  );
}

@immutable
final class AppShapeTheme extends ThemeExtension<AppShapeTheme> {
  const AppShapeTheme({
    required this.buttonRadius,
    required this.dialogRadius,
    required this.navigationItemRadius,
  });

  final double buttonRadius;
  final double dialogRadius;
  final double navigationItemRadius;

  BorderRadius get buttonBorderRadius {
    return BorderRadius.all(Radius.circular(buttonRadius));
  }

  BorderRadius get navigationItemBorderRadius {
    return BorderRadius.all(Radius.circular(navigationItemRadius));
  }

  @override
  AppShapeTheme copyWith({
    double? buttonRadius,
    double? dialogRadius,
    double? navigationItemRadius,
  }) {
    return AppShapeTheme(
      buttonRadius: buttonRadius ?? this.buttonRadius,
      dialogRadius: dialogRadius ?? this.dialogRadius,
      navigationItemRadius: navigationItemRadius ?? this.navigationItemRadius,
    );
  }

  @override
  AppShapeTheme lerp(ThemeExtension<AppShapeTheme>? other, double t) {
    if (other is! AppShapeTheme) {
      return this;
    }
    return AppShapeTheme(
      buttonRadius: _lerpDouble(buttonRadius, other.buttonRadius, t),
      dialogRadius: _lerpDouble(dialogRadius, other.dialogRadius, t),
      navigationItemRadius: _lerpDouble(
        navigationItemRadius,
        other.navigationItemRadius,
        t,
      ),
    );
  }
}

ThemeData buildAppTheme(ColorScheme colorScheme) {
  return ThemeData(
    colorScheme: colorScheme,
    extensions: const [appShapeTheme],
    dialogTheme: const DialogThemeData(shape: _dialogShape),
    filledButtonTheme: const FilledButtonThemeData(
      style: _buttonStyle,
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: _buttonStyle,
    ),
    textButtonTheme: const TextButtonThemeData(
      style: _buttonStyle,
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: _buttonStyle,
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: _buttonStyle,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      shape: _buttonShape,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      indicatorShape: _buttonShape,
    ),
  );
}

ThemeData buildDesktopTheme(ThemeData base) {
  return base.copyWith(
    visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
  );
}

AppShapeTheme appShapesOf(BuildContext context) {
  return Theme.of(context).extension<AppShapeTheme>() ?? appShapeTheme;
}

double _lerpDouble(double a, double b, double t) {
  return a + (b - a) * t;
}
