part of '../desktop_layout.dart';

final class _DesktopMessageList extends StatelessWidget {
  const _DesktopMessageList({
    required this.state,
    required this.mailbox,
    required this.selectedMessageIds,
    required this.onMessageSelected,
    required this.onSelectionChanged,
    required this.onDeleteSelected,
  });

  final AppState state;
  final Mailbox mailbox;
  final Set<MessageId> selectedMessageIds;
  final ValueChanged<MessageRecord> onMessageSelected;
  final void Function(MessageRecord message, bool selected) onSelectionChanged;
  final VoidCallback onDeleteSelected;

  @override
  Widget build(BuildContext context) {
    final selectedMessages = state.messages
        .where((message) => selectedMessageIds.contains(message.id))
        .toList(growable: false);
    final deleteBlockReason = messageListDeletionBlockReason(
      selectedMessages,
      DateTime.now().toUtc(),
    );
    final canDelete = selectedMessages.isNotEmpty && deleteBlockReason == null;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              const SizedBox(width: 44),
              Expanded(
                flex: 4,
                child: Text('Correspondent'),
              ),
              const Expanded(
                flex: 2,
                child: Text('State'),
              ),
              const Expanded(
                flex: 2,
                child: Text('Date'),
              ),
              Tooltip(
                message: deleteBlockReason ?? 'Delete selected messages',
                waitDuration: const Duration(milliseconds: 200),
                child: OutlinedButton.icon(
                  onPressed: canDelete ? onDeleteSelected : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: state.messages.isEmpty
              ? const Center(
                  child: Text('No messages'),
                )
              : ListView.separated(
                  itemCount: state.messages.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final message = state.messages[index];
                    final unread = mailbox == Mailbox.inbox && !message.isRead;
                    return InkWell(
                      onTap: () => onMessageSelected(message),
                      child: Container(
                        height: _desktopMessageListRowHeight,
                        color: state.selectedMessage?.id == message.id
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 44,
                              child: Checkbox(
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                value: selectedMessageIds.contains(message.id),
                                onChanged: (selected) => onSelectionChanged(
                                  message,
                                  selected ?? false,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: Text(
                                shortText(
                                  messagePeerLabel(
                                    message,
                                    mailbox,
                                    state.contacts,
                                  ),
                                  28,
                                ),
                                style: unread
                                    ? const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      )
                                    : null,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(messageStatusLabel(message, mailbox)),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(formatDateTime(message.createdAt)),
                            ),
                            const SizedBox(width: 104),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
