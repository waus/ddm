part of '../desktop_layout.dart';

final class _DesktopMessageDetail extends StatelessWidget {
  const _DesktopMessageDetail({
    required this.message,
    required this.contacts,
    required this.onDelete,
  });

  final MessageRecord? message;
  final List<ContactRecord> contacts;
  final ValueChanged<MessageRecord> onDelete;

  @override
  Widget build(BuildContext context) {
    final currentMessage = message;
    if (currentMessage == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(
          child: Text('Select a message'),
        ),
      );
    }
    final deleteBlockReason = messageDeletionBlockReason(
      currentMessage,
      DateTime.now().toUtc(),
    );
    final isReceived = currentMessage.state == messageStateReceived;
    final peerAddress = isReceived
        ? currentMessage.senderAddress
        : currentMessage.recipientAddress;
    return ListView(
      children: [
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledValueRow(
                  label: isReceived ? 'From' : 'To',
                  value: contactDisplayName(
                    contacts,
                    peerAddress,
                  ),
                  bottomPadding: 8,
                ),
                LabeledValueRow(
                  label: 'Date',
                  value: formatDateTimeWithSeconds(currentMessage.createdAt),
                  bottomPadding: 8,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Tooltip(
                    message: deleteBlockReason ?? 'Delete message',
                    waitDuration: const Duration(milliseconds: 200),
                    child: OutlinedButton.icon(
                      onPressed: deleteBlockReason == null
                          ? () => onDelete(currentMessage)
                          : null,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: SelectableText(messagePreview(currentMessage)),
        ),
      ],
    );
  }
}
