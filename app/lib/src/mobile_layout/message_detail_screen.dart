part of '../mobile_layout.dart';

final class _MobileMessageDetailScreen extends StatelessWidget {
  const _MobileMessageDetailScreen({
    required this.mailbox,
    required this.message,
    required this.contacts,
    required this.controller,
  });

  final Mailbox mailbox;
  final MessageRecord message;
  final List<ContactRecord> contacts;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Message'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Consumer(
              builder: (context, ref, _) {
                final sync = ref.watch(appControllerProvider).sync;
                return MobilePowProgressBar(sync: sync);
              },
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  LabeledValueRow(
                    label: 'From',
                    value: contactDisplayName(contacts, message.senderAddress),
                  ),
                  LabeledValueRow(
                    label: 'To',
                    value: contactDisplayName(
                      contacts,
                      message.recipientAddress,
                    ),
                  ),
                  LabeledValueRow(
                    label: 'Date',
                    value: formatDateTimeWithSeconds(
                      message.createdAt,
                    ),
                  ),
                  LabeledValueRow(
                    label: 'State',
                    value: messageStatusLabel(message, mailbox),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: messageDeletionBlockReason(
                              message,
                              DateTime.now().toUtc(),
                            ) ==
                            null
                        ? () => _deleteMessage(context)
                        : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                  const SizedBox(height: 20),
                  SelectableText(messagePreview(message)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessage(BuildContext context) async {
    final deleted = await controller.deleteMessages(<MessageRecord>[message]);
    if (deleted && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}
