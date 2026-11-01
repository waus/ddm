part of '../mobile_layout.dart';

final class _MobileAccountScreen extends StatelessWidget {
  const _MobileAccountScreen({
    required this.state,
    required this.controller,
  });

  final AppState state;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final account = state.selectedAccount ?? state.accounts.firstOrNull;
    if (account == null) {
      return const Center(
        child: NewAccountButton(),
      );
    }

    final otherAccounts = state.accounts
        .where((candidate) => candidate.id != account.id)
        .toList(growable: false);
    final isSilent = account.isSilent;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AccountTitle(
            name: account.name,
            isSilent: isSilent,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          SelectableText(
            account.address,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 20),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: AccountQrCode(
                address: account.address,
                maxSize: 300,
              ),
            ),
          ),
          const SizedBox(height: 20),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text('Advanced'),
            children: [
              LabeledValueRow(
                label: 'Created',
                value: formatDateTime(account.createdAt),
              ),
              LabeledValueRow(
                label: 'Silent',
                value: '$isSilent',
              ),
              LabeledValueRow(
                label: 'Stream ID',
                value: account.streamId.toHex(),
              ),
            ],
          ),
          if (otherAccounts.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Switch accounts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...otherAccounts.map(
              (otherAccount) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(otherAccount.name),
                subtitle: Text(shortText(otherAccount.address, 28)),
                onTap: () => controller.selectAccount(otherAccount),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const NewAccountButton(),
        ],
      ),
    );
  }
}
