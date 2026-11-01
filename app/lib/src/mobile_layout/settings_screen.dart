part of '../mobile_layout.dart';

final class _MobileSettingsScreen extends ConsumerWidget {
  const _MobileSettingsScreen({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Settings',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
              const ThemeModeToggleButton(),
            ],
          ),
          const SizedBox(height: 20),
          AppUpdateNotice(
            state: state,
            onUpdatePressed: () {
              ref.read(appControllerProvider.notifier).openUpdateSite();
            },
          ),
          if (state.update != null) const SizedBox(height: 20),
          LabeledValueBlock(
            label: 'Version',
            value: state.appVersion?.displayText ?? 'unknown',
          ),
          const SizedBox(height: 12),
          LabeledValueBlock(
            label: 'Peers',
            value: '${state.sync.onlinePeerCount}/${state.sync.totalPeerCount}',
          ),
          const SizedBox(height: 12),
          LabeledValueBlock(
            label: 'Anonymity set',
            value: '${state.sync.totalSyncedMessages}',
          ),
          const SizedBox(height: 12),
          LabeledValueBlock(
            label: 'PoW',
            value: state.sync.powActivity,
          ),
          const SizedBox(height: 12),
          LabeledValueBlock(
            label: 'Progress',
            value: '${state.sync.powProgress}%',
          ),
          const SizedBox(height: 12),
          LabeledValueBlock(
            label: 'Protocols',
            value: state.sync.registeredProtocols.isEmpty
                ? 'none'
                : state.sync.registeredProtocols.join(', '),
          ),
        ],
      ),
    );
  }
}
