part of '../desktop_layout.dart';

final class _DesktopMailboxPane extends StatefulWidget {
  const _DesktopMailboxPane({
    required this.state,
    required this.controller,
    required this.accountId,
    required this.mailbox,
    required this.listFraction,
    required this.onFractionChanged,
  });

  final AppState state;
  final AppController controller;
  final int accountId;
  final Mailbox mailbox;
  final double listFraction;
  final ValueChanged<double> onFractionChanged;

  @override
  State<_DesktopMailboxPane> createState() => _DesktopMailboxPaneState();
}

final class _DesktopMailboxPaneState extends State<_DesktopMailboxPane> {
  final Set<MessageId> _selectedMessageIds = <MessageId>{};

  @override
  void didUpdateWidget(covariant _DesktopMailboxPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visibleIds =
        widget.state.messages.map((message) => message.id).toSet();
    _selectedMessageIds.removeWhere((id) => !visibleIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight;
        final effectiveMaxListHeight = availableHeight -
            _desktopHorizontalDividerHeight -
            _desktopMessageDetailMinHeight;
        final fallbackListHeight = availableHeight * widget.listFraction;
        final listHeight = fallbackListHeight.clamp(
          _desktopMailboxListMinHeight,
          effectiveMaxListHeight,
        );
        final detailHeight =
            availableHeight - listHeight - _desktopHorizontalDividerHeight;

        return Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: listHeight,
                  child: _DesktopMessageList(
                    state: widget.state,
                    mailbox: widget.mailbox,
                    selectedMessageIds: _selectedMessageIds,
                    onMessageSelected: widget.controller.selectMessage,
                    onSelectionChanged: _setMessageSelected,
                    onDeleteSelected: _deleteSelectedMessages,
                  ),
                ),
                SizedBox(
                  height: _desktopHorizontalDividerHeight,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                SizedBox(
                  height: detailHeight,
                  child: _DesktopMessageDetail(
                    message: widget.state.selectedMessage,
                    contacts: widget.state.contacts,
                    onDelete: _deleteMessage,
                  ),
                ),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              top: listHeight -
                  (_desktopHorizontalDividerHitHeight -
                          _desktopHorizontalDividerHeight) /
                      2,
              height: _desktopHorizontalDividerHitHeight,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    final nextListHeight =
                        (listHeight + details.delta.dy).clamp(
                      _desktopMailboxListMinHeight,
                      effectiveMaxListHeight,
                    );
                    widget.onFractionChanged(nextListHeight / availableHeight);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _setMessageSelected(MessageRecord message, bool selected) {
    setState(() {
      if (selected) {
        _selectedMessageIds.add(message.id);
      } else {
        _selectedMessageIds.remove(message.id);
      }
    });
  }

  Future<void> _deleteSelectedMessages() async {
    final selectedMessages = widget.state.messages
        .where((message) => _selectedMessageIds.contains(message.id))
        .toList(growable: false);
    final deleted = await widget.controller.deleteMessages(selectedMessages);
    if (!deleted || !mounted) {
      return;
    }
    setState(_selectedMessageIds.clear);
  }

  Future<void> _deleteMessage(MessageRecord message) async {
    final deleted = await widget.controller.deleteMessages(<MessageRecord>[
      message,
    ]);
    if (!deleted || !mounted) {
      return;
    }
    setState(() {
      _selectedMessageIds.remove(message.id);
    });
  }
}
