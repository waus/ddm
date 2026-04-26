import 'package:flutter/material.dart';

import 'app_theme.dart';

final class ExternalStorageStatusButton extends StatefulWidget {
  const ExternalStorageStatusButton({
    required this.count,
    required this.onPressed,
    super.key,
  });

  final int count;
  final VoidCallback onPressed;

  @override
  State<ExternalStorageStatusButton> createState() =>
      _ExternalStorageStatusButtonState();
}

final class _ExternalStorageStatusButtonState
    extends State<ExternalStorageStatusButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.35,
      upperBound: 1,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderRadius = appShapesOf(context).buttonBorderRadius;
    return Tooltip(
      message: widget.count == 1
          ? 'External sync file detected'
          : '${widget.count} external sync files detected',
      waitDuration: const Duration(milliseconds: 200),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final backgroundColor =
              colorScheme.tertiaryContainer.withValues(alpha: _pulse.value);
          final iconColor = Color.lerp(
            colorScheme.tertiary,
            colorScheme.onTertiaryContainer,
            _pulse.value,
          );
          return DecoratedBox(
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: borderRadius,
              border: Border.all(
                color: colorScheme.tertiary.withValues(alpha: _pulse.value),
              ),
            ),
            child: IconButton(
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              icon: Badge.count(
                count: widget.count,
                isLabelVisible: widget.count > 1,
                backgroundColor: colorScheme.error,
                textColor: colorScheme.onError,
                child: Icon(
                  Icons.usb_outlined,
                  size: 20,
                  color: iconColor,
                ),
              ),
              onPressed: widget.onPressed,
            ),
          );
        },
      ),
    );
  }
}
