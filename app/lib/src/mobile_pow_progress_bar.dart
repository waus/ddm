import 'package:flutter/material.dart';

import 'app_state.dart';

final class MobilePowProgressBar extends StatelessWidget {
  const MobilePowProgressBar({required this.sync, super.key});

  final SyncDiagnostics sync;

  @override
  Widget build(BuildContext context) {
    final visible = sync.powProgress > 0 && sync.powProgress < 100;
    final progressValue = sync.powProgress <= 0
        ? 0.0
        : sync.powProgress >= 100
            ? 1.0
            : sync.powProgress / 100;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: SizedBox(
        width: double.infinity,
        height: 4,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: constraints.maxWidth * progressValue,
                  height: 4,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
