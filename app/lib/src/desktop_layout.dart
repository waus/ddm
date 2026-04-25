import 'dart:async';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_qr_code.dart';
import 'account_policy.dart';
import 'app_controller.dart';
import 'app_shortcuts.dart';
import 'app_state.dart';
import 'external_storage_status_button.dart';
import 'mailbox_icon.dart';
import 'message_compose_form.dart';
import 'new_account_dialog.dart';
import 'theme_mode_toggle.dart';

const desktopSidebarInitialFraction = 0.2;
const desktopSidebarMinWidth = 180.0;
const desktopContentMinWidth = 560.0;
const desktopDividerWidth = 1.0;
const desktopSidebarFractionKey = 'desktop_sidebar_fraction';
const _desktopDividerHitWidth = 12.0;
const _desktopMailboxListInitialFraction = 0.5;
const _desktopMailboxListMinHeight = 180.0;
const _desktopMessageDetailMinHeight = 180.0;
const _desktopHorizontalDividerHeight = 1.0;
const _desktopHorizontalDividerHitHeight = 12.0;

final class DesktopLayout extends ConsumerStatefulWidget {
  const DesktopLayout({required this.state, super.key});

  final AppState state;

  @override
  ConsumerState<DesktopLayout> createState() => _DesktopLayoutState();
}

final class _DesktopLayoutState extends ConsumerState<DesktopLayout> {
  SharedPreferencesAsync? _preferences;
  double? _sidebarFraction;
  Timer? _sidebarSaveDebounce;
  _DesktopSelection? _selection;
  _DesktopSelection? _selectionBeforeCompose;

  @override
  void initState() {
    super.initState();
    _restoreSidebarState();
  }

  @override
  void dispose() {
    _sidebarSaveDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(appControllerProvider.notifier);
    final state = widget.state;
    final newMessageShortcut = newMessageShortcutActivator();
    final compactTheme = Theme.of(context).copyWith(
      visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
    );
    return Focus(
      autofocus: true,
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          newMessageShortcut: const _DesktopNewMessageIntent(),
          closeComposeShortcutActivator: const _DesktopCloseComposeIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _DesktopNewMessageIntent: CallbackAction<_DesktopNewMessageIntent>(
              onInvoke: (_) {
                _openCompose(state, controller);
                return null;
              },
            ),
            _DesktopCloseComposeIntent:
                CallbackAction<_DesktopCloseComposeIntent>(
              onInvoke: (_) {
                if (_selection is _DesktopComposeSelection) {
                  _closeCompose(state);
                }
                return null;
              },
            ),
          },
          child: Theme(
            data: compactTheme,
            // App shell
            child: Scaffold(
              // Safe layout
              body: SafeArea(
                // Main column
                child: Column(
                  children: [
                    // Top bar
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          MenuBar(
                            children: [
                              SubmenuButton(
                                menuChildren: [
                                  MenuItemButton(
                                    shortcut: newMessageShortcut,
                                    onPressed: state.accounts.isEmpty
                                        ? null
                                        : () => _openCompose(state, controller),
                                    child: const Text('New message'),
                                  ),
                                ],
                                child: const Text('Message'),
                              ),
                            ],
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: state.accounts.isEmpty
                                ? null
                                : () => _openCompose(state, controller),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Write message'),
                          ),
                        ],
                      ),
                    ),
                    // Main area
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final availableWidth = constraints.maxWidth;
                          final effectiveMaxSidebarWidth = availableWidth -
                              desktopDividerWidth -
                              desktopContentMinWidth;
                          final fallbackSidebarWidth = availableWidth *
                              (_sidebarFraction ??
                                  desktopSidebarInitialFraction);
                          final sidebarWidth = fallbackSidebarWidth.clamp(
                            desktopSidebarMinWidth,
                            effectiveMaxSidebarWidth,
                          );
                          final messagesWidth = availableWidth -
                              sidebarWidth -
                              desktopDividerWidth;

                          return Stack(
                            children: [
                              // Split view
                              Row(
                                children: [
                                  // Left panel
                                  SizedBox(
                                    width: sidebarWidth,
                                    child: ColoredBox(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      child: _DesktopSidebar(
                                        state: state,
                                        controller: controller,
                                        selection: _selection,
                                        onAccountSelected: (account) {
                                          setState(() {
                                            _selection =
                                                _DesktopAccountSelection(
                                                    account.id);
                                          });
                                          controller.selectAccount(account);
                                        },
                                        onMailboxSelected: (account, mailbox) {
                                          setState(() {
                                            _selection =
                                                _DesktopMailboxSelection(
                                              account.id,
                                              mailbox,
                                            );
                                          });
                                          controller.selectAccountMailbox(
                                            account,
                                            mailbox,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  // Divider
                                  SizedBox(
                                    width: desktopDividerWidth,
                                    child: ColoredBox(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                    ),
                                  ),
                                  // Detail pane
                                  SizedBox(
                                    width: messagesWidth,
                                    child: _DesktopDetailPane(
                                      selection: _selection,
                                      state: state,
                                      controller: controller,
                                      onComposeCancel: () =>
                                          _closeCompose(state),
                                      onComposeSubmitted: (account) {
                                        setState(() {
                                          _selection = _DesktopMailboxSelection(
                                            account.id,
                                            Mailbox.outbox,
                                          );
                                          _selectionBeforeCompose = null;
                                        });
                                      },
                                      readState: () =>
                                          ref.read(appControllerProvider),
                                    ),
                                  ),
                                ],
                              ),
                              // Resize handle
                              Positioned(
                                left: sidebarWidth -
                                    (_desktopDividerHitWidth -
                                            desktopDividerWidth) /
                                        2,
                                top: 0,
                                bottom: 0,
                                width: _desktopDividerHitWidth,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.resizeColumn,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragUpdate: (details) {
                                      final nextSidebarWidth =
                                          (sidebarWidth + details.delta.dx)
                                              .clamp(
                                        desktopSidebarMinWidth,
                                        effectiveMaxSidebarWidth,
                                      );
                                      setState(() {
                                        _sidebarFraction =
                                            nextSidebarWidth / availableWidth;
                                      });
                                      _scheduleSidebarStateSave();
                                    },
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    // Status bar
                    _DesktopStatusBar(
                      sync: state.sync,
                      onExternalStoragePressed:
                          controller.chooseExternalStorageFile,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openCompose(AppState state, AppController controller) {
    if (state.accounts.isEmpty) {
      return;
    }
    final account = state.selectedAccount ?? state.accounts.first;
    setState(() {
      if (_selection is! _DesktopComposeSelection) {
        _selectionBeforeCompose = _selection;
      }
      _selection = _DesktopComposeSelection(account.id);
    });
    controller.selectSection(AppSection.compose);
  }

  void _closeCompose(AppState state) {
    final fallbackAccount = state.selectedAccount;
    setState(() {
      _selection = _selectionBeforeCompose ??
          (fallbackAccount == null
              ? null
              : _DesktopAccountSelection(fallbackAccount.id));
      _selectionBeforeCompose = null;
    });
  }

  Future<void> _restoreSidebarState() async {
    final preferences = SharedPreferencesAsync();
    _preferences = preferences;
    final savedSidebarFraction = await preferences.getDouble(
      desktopSidebarFractionKey,
    );
    if (savedSidebarFraction != null && mounted) {
      setState(() {
        _sidebarFraction = savedSidebarFraction;
      });
    }
  }

  void _scheduleSidebarStateSave() {
    final fraction = _sidebarFraction;
    final preferences = _preferences;
    if (fraction == null || preferences == null) {
      return;
    }
    _sidebarSaveDebounce?.cancel();
    _sidebarSaveDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(preferences.setDouble(desktopSidebarFractionKey, fraction));
    });
  }
}

final class _DesktopNewMessageIntent extends Intent {
  const _DesktopNewMessageIntent();
}

final class _DesktopCloseComposeIntent extends Intent {
  const _DesktopCloseComposeIntent();
}

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
    final borderRadius = BorderRadius.circular(6);
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
    final borderRadius = BorderRadius.circular(6);
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

final class _DesktopDetailPane extends StatefulWidget {
  const _DesktopDetailPane({
    required this.selection,
    required this.state,
    required this.controller,
    required this.onComposeCancel,
    required this.onComposeSubmitted,
    required this.readState,
  });

  final _DesktopSelection? selection;
  final AppState state;
  final AppController controller;
  final VoidCallback onComposeCancel;
  final ValueChanged<AccountRecord> onComposeSubmitted;
  final AppState Function() readState;

  @override
  State<_DesktopDetailPane> createState() => _DesktopDetailPaneState();
}

final class _DesktopDetailPaneState extends State<_DesktopDetailPane> {
  double _listFraction = _desktopMailboxListInitialFraction;

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    return switch (selection) {
      _DesktopAccountSelection accountSelection => _DesktopAccountPane(
          account: _account(
            accountSelection.accountId,
            widget.state.accounts,
          ),
          controller: widget.controller,
        ),
      _DesktopComposeSelection composeSelection => _DesktopComposePane(
          state: widget.state,
          controller: widget.controller,
          accountId: composeSelection.accountId,
          onCancel: widget.onComposeCancel,
          onSubmitted: widget.onComposeSubmitted,
          readState: widget.readState,
        ),
      _DesktopMailboxSelection mailboxSelection => _DesktopMailboxPane(
          state: widget.state,
          controller: widget.controller,
          accountId: mailboxSelection.accountId,
          mailbox: mailboxSelection.mailbox,
          listFraction: _listFraction,
          onFractionChanged: (value) {
            setState(() {
              _listFraction = value;
            });
          },
        ),
      null => const Center(
          child: Text('Messages'),
        ),
    };
  }

  AccountRecord? _account(int accountId, List<AccountRecord> accounts) {
    for (final account in accounts) {
      if (account.id == accountId) {
        return account;
      }
    }
    return null;
  }
}

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
        _MessageHeaderRow(
          label: 'Created',
          value: _formatDateTime(currentAccount.createdAt),
        ),
        _MessageHeaderRow(
          label: 'Silent',
          value: '$isSilent',
        ),
        _MessageHeaderRow(
          label: 'Messages',
          value: '$messageCount',
        ),
      ],
    );
  }
}

final class _DesktopMailboxPane extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight;
        final effectiveMaxListHeight = availableHeight -
            _desktopHorizontalDividerHeight -
            _desktopMessageDetailMinHeight;
        final fallbackListHeight = availableHeight * listFraction;
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
                    state: state,
                    mailbox: mailbox,
                    onMessageSelected: controller.selectMessage,
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
                    mailbox: mailbox,
                    message: state.selectedMessage,
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
                    onFractionChanged(nextListHeight / availableHeight);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

final class _DesktopComposePane extends StatelessWidget {
  const _DesktopComposePane({
    required this.state,
    required this.controller,
    required this.accountId,
    required this.onCancel,
    required this.onSubmitted,
    required this.readState,
  });

  final AppState state;
  final AppController controller;
  final int accountId;
  final VoidCallback onCancel;
  final ValueChanged<AccountRecord> onSubmitted;
  final AppState Function() readState;

  @override
  Widget build(BuildContext context) {
    return MessageComposeForm(
      accounts: state.accounts,
      initialAccountId: accountId,
      onCancel: onCancel,
      onSubmit: ({
        required AccountRecord sender,
        required String recipientAddress,
        required Duration ttl,
        required String text,
      }) async {
        await controller.sendText(
          sender: sender,
          recipientAddress: recipientAddress,
          text: text,
          ttl: ttl,
        );
        final nextState = readState();
        if (nextState.errorMessage != null) {
          return nextState.errorMessage;
        }
        onSubmitted(sender);
        return null;
      },
    );
  }
}

final class _DesktopMessageList extends StatelessWidget {
  const _DesktopMessageList({
    required this.state,
    required this.mailbox,
    required this.onMessageSelected,
  });

  final AppState state;
  final Mailbox mailbox;
  final ValueChanged<MessageRecord> onMessageSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Row(
            children: [
              Expanded(
                flex: 4,
                child: Text('Correspondent'),
              ),
              Expanded(
                flex: 2,
                child: Text('State'),
              ),
              Expanded(
                flex: 2,
                child: Text('Date'),
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
                        color: state.selectedMessage?.id == message.id
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 4,
                              child: Text(
                                shortText(messagePeer(message, mailbox), 28),
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
                              child: Text(_formatDateTime(message.createdAt)),
                            ),
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

final class _DesktopMessageDetail extends StatelessWidget {
  const _DesktopMessageDetail({
    required this.mailbox,
    required this.message,
  });

  final Mailbox mailbox;
  final MessageRecord? message;

  @override
  Widget build(BuildContext context) {
    final currentMessage = message;
    if (currentMessage == null) {
      return const Center(
        child: Text('Select a message'),
      );
    }
    return ListView(
      children: [
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MessageHeaderRow(
                  label: 'From',
                  value: currentMessage.senderAddress,
                ),
                _MessageHeaderRow(
                  label: 'To',
                  value: currentMessage.recipientAddress,
                ),
                _MessageHeaderRow(
                  label: 'Date',
                  value: _formatDateTimeWithSeconds(currentMessage.createdAt),
                ),
                _MessageHeaderRow(
                  label: 'State',
                  value: messageStatusLabel(currentMessage, mailbox),
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

final class _MessageHeaderRow extends StatelessWidget {
  const _MessageHeaderRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SelectableText('$label: $value'),
    );
  }
}

final class _DesktopStatusBar extends StatelessWidget {
  const _DesktopStatusBar({
    required this.sync,
    required this.onExternalStoragePressed,
  });

  final SyncDiagnostics sync;
  final VoidCallback onExternalStoragePressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _StatusSection(
              label: 'Peers',
              value: '${sync.onlinePeerCount}/${sync.totalPeerCount}',
            ),
            const SizedBox(width: 18),
            _StatusSection(
              label: 'Anonymity set',
              value: '${sync.totalSyncedMessages}',
            ),
            const SizedBox(width: 18),
            _PowStatusSection(
              label: 'PoW',
              value: sync.powActivity,
              progress: sync.powProgress,
            ),
            const SizedBox(width: 18),
            _StatusSection(
              label: 'Protocols',
              value: sync.registeredProtocols.isEmpty
                  ? 'none'
                  : sync.registeredProtocols.join(', '),
            ),
            const SizedBox(width: 18),
            if (sync.externalStorageFileUrls.isNotEmpty) ...[
              ExternalStorageStatusButton(
                count: sync.externalStorageFileUrls.length,
                onPressed: onExternalStoragePressed,
              ),
              const SizedBox(width: 18),
            ],
            const ThemeModeToggleButton(),
          ],
        ),
      ),
    );
  }
}

final class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: value),
        ],
      ),
      overflow: TextOverflow.ellipsis,
    );
  }
}

final class _PowStatusSection extends StatelessWidget {
  const _PowStatusSection({
    required this.label,
    required this.value,
    required this.progress,
  });

  final String label;
  final String value;
  final int progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progressValue = progress <= 0
        ? 0.0
        : progress >= 100
            ? 1.0
            : progress / 100;
    return Tooltip(
      message: '${progress.toString()}%',
      waitDuration: const Duration(milliseconds: 200),
      child: SizedBox(
        width: 240,
        height: 24,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fillWidth = constraints.maxWidth * progressValue;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: colorScheme.surfaceContainerLow,
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: fillWidth,
                  child: ColoredBox(
                    color: colorScheme.primary,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(context).style.copyWith(
                              color: progressValue > 0.55
                                  ? colorScheme.onPrimary
                                  : DefaultTextStyle.of(context).style.color,
                            ),
                        children: [
                          TextSpan(
                            text: '$label: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: value),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

sealed class _DesktopSelection {
  const _DesktopSelection(this.accountId);

  final int accountId;
}

final class _DesktopAccountSelection extends _DesktopSelection {
  const _DesktopAccountSelection(super.accountId);
}

final class _DesktopMailboxSelection extends _DesktopSelection {
  const _DesktopMailboxSelection(super.accountId, this.mailbox);

  final Mailbox mailbox;
}

final class _DesktopComposeSelection extends _DesktopSelection {
  const _DesktopComposeSelection(super.accountId);
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _formatDateTimeWithSeconds(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute:$second';
}
