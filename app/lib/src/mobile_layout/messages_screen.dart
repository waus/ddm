part of '../mobile_layout.dart';

final class _MobileMessagesScreen extends StatefulWidget {
  const _MobileMessagesScreen({
    required this.state,
    required this.controller,
  });

  final AppState state;
  final AppController controller;

  @override
  State<_MobileMessagesScreen> createState() => _MobileMessagesScreenState();
}

final class _MobileMessagesScreenState extends State<_MobileMessagesScreen> {
  bool _requestedInitialMailbox = false;
  bool _selectionMode = false;
  final Set<MessageId> _selectedMessageIds = <MessageId>{};

  @override
  void didUpdateWidget(covariant _MobileMessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visibleIds =
        widget.state.messages.map((message) => message.id).toSet();
    _selectedMessageIds.removeWhere((id) => !visibleIds.contains(id));
    if (_selectedMessageIds.isEmpty && _selectionMode) {
      _selectionMode = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final account = state.selectedAccount ?? state.accounts.firstOrNull;
    if (!_requestedInitialMailbox &&
        account != null &&
        state.selectedAccount == null) {
      _requestedInitialMailbox = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.selectAccountMailbox(account, state.mailbox);
      });
    }

    if (account == null) {
      return const Center(
        child: NewAccountButton(),
      );
    }

    final inboxUnreadCount = widget.controller.unreadMailboxMessageCount(
      account,
      Mailbox.inbox,
    );
    final outboxUnreadCount = widget.controller.unreadMailboxMessageCount(
      account,
      Mailbox.outbox,
    );

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: SegmentedButton<Mailbox>(
              segments: [
                ButtonSegment(
                  value: Mailbox.inbox,
                  icon: Icon(mailboxIcon(Mailbox.inbox)),
                  label: MailboxSegmentLabel(
                    label: 'Inbox',
                    unreadCount: inboxUnreadCount,
                  ),
                ),
                ButtonSegment(
                  value: Mailbox.outbox,
                  icon: Icon(mailboxIcon(Mailbox.outbox)),
                  label: MailboxSegmentLabel(
                    label: 'Outbox',
                    unreadCount: outboxUnreadCount,
                  ),
                ),
              ],
              selected: {state.mailbox},
              onSelectionChanged: (selection) {
                setState(() {
                  _selectionMode = false;
                  _selectedMessageIds.clear();
                });
                widget.controller
                    .selectAccountMailbox(account, selection.single);
              },
            ),
          ),
          if (_selectionMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_selectedMessageIds.length} selected',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel selection',
                    onPressed: () {
                      setState(() {
                        _selectionMode = false;
                        _selectedMessageIds.clear();
                      });
                    },
                    icon: const Icon(Icons.close),
                  ),
                  FilledButton.icon(
                    onPressed: _canDeleteSelected(state)
                        ? () => _deleteSelectedMessages(context)
                        : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
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
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: state.messages.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final message = state.messages[index];
                      final unread =
                          state.mailbox == Mailbox.inbox && !message.isRead;
                      final selected = _selectedMessageIds.contains(message.id);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _selectionMode
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) =>
                                    _toggleMessageSelection(context, message),
                              )
                            : null,
                        title: Text(
                          shortText(
                            messagePeerLabel(
                              message,
                              state.mailbox,
                              state.contacts,
                            ),
                            32,
                          ),
                          style: unread
                              ? const TextStyle(fontWeight: FontWeight.bold)
                              : null,
                        ),
                        subtitle: Text(
                          messagePreview(message),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          formatCompactDate(message.createdAt),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () {
                          if (_selectionMode) {
                            _toggleMessageSelection(context, message);
                            return;
                          }
                          widget.controller.selectMessage(message);
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) {
                                return _MobileMessageDetailScreen(
                                  mailbox: state.mailbox,
                                  message: message,
                                  contacts: state.contacts,
                                  controller: widget.controller,
                                );
                              },
                            ),
                          );
                        },
                        onLongPress: () {
                          if (!_selectionMode) {
                            setState(() {
                              _selectionMode = true;
                            });
                          }
                          _toggleMessageSelection(context, message);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  bool _canDeleteSelected(AppState state) {
    final selectedMessages = _selectedMessages(state);
    return selectedMessages.isNotEmpty &&
        messageListDeletionBlockReason(
              selectedMessages,
              DateTime.now().toUtc(),
            ) ==
            null;
  }

  List<MessageRecord> _selectedMessages(AppState state) {
    return state.messages
        .where((message) => _selectedMessageIds.contains(message.id))
        .toList(growable: false);
  }

  void _toggleMessageSelection(BuildContext context, MessageRecord message) {
    final blockReason = messageDeletionBlockReason(
      message,
      DateTime.now().toUtc(),
    );
    setState(() {
      if (_selectedMessageIds.contains(message.id)) {
        _selectedMessageIds.remove(message.id);
      } else {
        _selectedMessageIds.add(message.id);
      }
      _selectionMode = _selectedMessageIds.isNotEmpty;
    });
    if (blockReason != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(blockReason)),
      );
    }
  }

  Future<void> _deleteSelectedMessages(BuildContext context) async {
    final deleted = await widget.controller.deleteMessages(
      _selectedMessages(widget.state),
    );
    if (!deleted || !mounted) {
      return;
    }
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
  }
}
