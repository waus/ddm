import 'package:flutter/material.dart';

import 'app_state.dart';

final class AppUpdateNotice extends StatelessWidget {
  const AppUpdateNotice({
    required this.state,
    required this.onUpdatePressed,
    this.compact = false,
    super.key,
  });

  final AppState state;
  final VoidCallback onUpdatePressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final update = state.update;
    final appVersion = state.appVersion;
    if (update == null || appVersion == null) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = update.mandatoryUpdate
        ? colorScheme.errorContainer
        : colorScheme.primaryContainer;
    final foregroundColor = update.mandatoryUpdate
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;
    final icon = update.mandatoryUpdate
        ? Icons.warning_amber_outlined
        : Icons.info_outline;
    final title =
        update.mandatoryUpdate ? 'Update required' : 'Update available';
    final message =
        'DDM ${update.lastVersion} is available. Current version: ${appVersion.version}.';

    return Card(
      color: backgroundColor,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foregroundColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: foregroundColor,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(color: foregroundColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: onUpdatePressed,
              style: TextButton.styleFrom(foregroundColor: foregroundColor),
              child: const Text('Update'),
            ),
          ],
        ),
      ),
    );
  }
}
