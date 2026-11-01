part of '../desktop_layout.dart';

final class _DesktopStatusBar extends StatelessWidget {
  const _DesktopStatusBar({
    required this.state,
    required this.onExternalStoragePressed,
    required this.onUpdatePressed,
  });

  final AppState state;
  final VoidCallback onExternalStoragePressed;
  final VoidCallback onUpdatePressed;

  @override
  Widget build(BuildContext context) {
    final sync = state.sync;
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _StatusSection(
              label: 'Peers',
              value: '${sync.onlinePeerCount}/${sync.totalPeerCount}',
            ),
            const SizedBox(width: 18),
            _StatusSection(
              label: 'Anonymity set',
              value: '${sync.totalSyncedMessages}',
            ),
            const SizedBox(width: 18),
            _PowStatusSection(
              label: 'PoW',
              value: sync.powActivity,
              progress: sync.powProgress,
            ),
            const SizedBox(width: 18),
            _StatusSection(
              label: 'Protocols',
              value: sync.registeredProtocols.isEmpty
                  ? 'none'
                  : sync.registeredProtocols.join(', '),
            ),
            const SizedBox(width: 18),
            _StatusSection(
              label: 'Version',
              value: state.appVersion?.displayText ?? 'unknown',
            ),
            if (state.update != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  tooltip: state.update!.mandatoryUpdate
                      ? 'Required update available'
                      : 'Update available',
                  visualDensity: VisualDensity.compact,
                  onPressed: onUpdatePressed,
                  icon: Icon(
                    Icons.upgrade,
                    color: state.update!.mandatoryUpdate
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(width: 18),
            if (sync.externalStorageFileUrls.isNotEmpty) ...[
              ExternalStorageStatusButton(
                count: sync.externalStorageFileUrls.length,
                onPressed: onExternalStoragePressed,
              ),
              const SizedBox(width: 18),
            ],
            const ThemeModeToggleButton(),
          ],
        ),
      ),
    );
  }
}

final class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: value),
        ],
      ),
      overflow: TextOverflow.ellipsis,
    );
  }
}

final class _PowStatusSection extends StatelessWidget {
  const _PowStatusSection({
    required this.label,
    required this.value,
    required this.progress,
  });

  final String label;
  final String value;
  final int progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progressValue = progress <= 0
        ? 0.0
        : progress >= 100
            ? 1.0
            : progress / 100;
    return Tooltip(
      message: '${progress.toString()}%',
      waitDuration: const Duration(milliseconds: 200),
      child: SizedBox(
        width: 240,
        height: 24,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fillWidth = constraints.maxWidth * progressValue;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: colorScheme.surfaceContainerLow,
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: fillWidth,
                  child: ColoredBox(
                    color: colorScheme.primary,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(context).style.copyWith(
                              color: progressValue > 0.55
                                  ? colorScheme.onPrimary
                                  : DefaultTextStyle.of(context).style.color,
                            ),
                        children: [
                          TextSpan(
                            text: '$label: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: value),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
