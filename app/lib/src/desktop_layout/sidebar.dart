part of '../desktop_layout.dart';

final class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.state,
    required this.controller,
    required this.selection,
    required this.onAccountSelected,
    required this.onMailboxSelected,
  });

  final AppState state;
  final AppController controller;
  final _DesktopSelection? selection;
  final ValueChanged<AccountRecord> onAccountSelected;
  final void Function(AccountRecord account, Mailbox mailbox) onMailboxSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: state.accounts.isEmpty
                ? const Center(
                    child: Text('No accounts'),
                  )
                : ListView.builder(
                    itemCount: state.accounts.length,
                    itemBuilder: (context, index) {
                      final account = state.accounts[index];
                      return _AccountTreeItem(
                        account: account,
                        selection: selection,
                        onAccountSelected: onAccountSelected,
                        children: [
                          _MailboxTreeItem(
                            account: account,
                            mailbox: Mailbox.inbox,
                            unreadCount: controller.unreadMailboxMessageCount(
                              account,
                              Mailbox.inbox,
                            ),
                            selection: selection,
                            onTap: onMailboxSelected,
                          ),
                          _MailboxTreeItem(
                            account: account,
                            mailbox: Mailbox.outbox,
                            unreadCount: controller.unreadMailboxMessageCount(
                              account,
                              Mailbox.outbox,
                            ),
                            selection: selection,
                            onTap: onMailboxSelected,
                          ),
                        ],
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          const NewAccountButton(),
        ],
      ),
    );
  }
}

final class _AccountTreeItem extends StatefulWidget {
  const _AccountTreeItem({
    required this.account,
    required this.selection,
    required this.onAccountSelected,
    required this.children,
  });

  final AccountRecord account;
  final _DesktopSelection? selection;
  final ValueChanged<AccountRecord> onAccountSelected;
  final List<Widget> children;

  @override
  State<_AccountTreeItem> createState() => _AccountTreeItemState();
}

final class _AccountTreeItemState extends State<_AccountTreeItem> {
  bool _expanded = true;
  bool _restoredExpansion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredExpansion) {
      return;
    }
    _restoredExpansion = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _pageStorageIdentifier,
    );
    if (stored is bool) {
      _expanded = stored;
    }
  }

  String get _pageStorageIdentifier => 'account-${widget.account.id}';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = widget.selection is _DesktopAccountSelection &&
        widget.selection!.accountId == widget.account.id;
    final borderRadius = appShapesOf(context).navigationItemBorderRadius;
    final foregroundColor = selected ? colorScheme.onPrimary : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: selected ? colorScheme.primary : Colors.transparent,
            borderRadius: borderRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: borderRadius,
              onTap: () => widget.onAccountSelected(widget.account),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.account.name,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: foregroundColor,
                                ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                      ),
                      color: foregroundColor,
                      onPressed: _toggleExpanded,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...widget.children,
        ],
      ),
    );
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
    PageStorage.maybeOf(context)?.writeState(
      context,
      _expanded,
      identifier: _pageStorageIdentifier,
    );
  }
}

final class _MailboxTreeItem extends StatelessWidget {
  const _MailboxTreeItem({
    required this.account,
    required this.mailbox,
    required this.unreadCount,
    required this.selection,
    required this.onTap,
  });

  final AccountRecord account;
  final Mailbox mailbox;
  final int unreadCount;
  final _DesktopSelection? selection;
  final void Function(AccountRecord account, Mailbox mailbox) onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = selection is _DesktopMailboxSelection &&
        selection!.accountId == account.id &&
        (selection! as _DesktopMailboxSelection).mailbox == mailbox;
    final borderRadius = appShapesOf(context).navigationItemBorderRadius;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? colorScheme.primary : Colors.transparent,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 28, right: 8),
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          leading: Icon(
            mailboxIcon(mailbox),
            size: 18,
            color:
                selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
          ),
          minLeadingWidth: 18,
          title: Text(
            unreadCount > 0 ? '${mailbox.name} ($unreadCount)' : mailbox.name,
            style: TextStyle(
              color: selected ? colorScheme.onPrimary : null,
              fontWeight: unreadCount > 0 ? FontWeight.bold : null,
            ),
          ),
          onTap: () => onTap(account, mailbox),
        ),
      ),
    );
  }
}
