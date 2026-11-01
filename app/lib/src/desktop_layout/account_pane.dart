part of '../desktop_layout.dart';

final class _DesktopAccountPane extends StatelessWidget {
  const _DesktopAccountPane({
    required this.account,
    required this.controller,
  });

  final AccountRecord? account;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final currentAccount = account;
    if (currentAccount == null) {
      return const Center(
        child: Text('Select an account'),
      );
    }

    final messageCount =
        controller.mailboxMessageCount(currentAccount, Mailbox.inbox) +
            controller.mailboxMessageCount(currentAccount, Mailbox.outbox);
    final theme = Theme.of(context);
    final isSilent = currentAccount.isSilent;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AccountTitle(
          name: currentAccount.name,
          isSilent: isSilent,
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 24),
        SelectableText(
          currentAccount.address,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontFamily: 'monospace',
            height: 1.45,
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: AccountQrCode(address: currentAccount.address),
        ),
        const SizedBox(height: 24),
        Text(
          'Advanced',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        LabeledValueRow(
          label: 'Created',
          value: formatDateTime(currentAccount.createdAt),
        ),
        LabeledValueRow(
          label: 'Silent',
          value: '$isSilent',
        ),
        LabeledValueRow(
          label: 'Messages',
          value: '$messageCount',
        ),
      ],
    );
  }
}
