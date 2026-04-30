import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_qr_code.dart';
import 'account_policy.dart';
import 'app_controller.dart';
import 'app_shortcuts.dart';
import 'app_state.dart';
import 'app_update_notice.dart';
import 'mailbox_icon.dart';
import 'message_compose_form.dart';
import 'mobile_pow_progress_bar.dart';
import 'new_account_dialog.dart';
import 'theme_mode_toggle.dart';

enum _MobileTab { messages, contacts, account, settings }

final class MobileLayout extends ConsumerStatefulWidget {
  const MobileLayout({required this.state, super.key});

  final AppState state;

  @override
  ConsumerState<MobileLayout> createState() => _MobileLayoutState();
}

final class _MobileLayoutState extends ConsumerState<MobileLayout> {
  _MobileTab _selectedTab = _MobileTab.messages;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(appControllerProvider.notifier);
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        newMessageShortcutActivator(): const NewMessageIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewMessageIntent: CallbackAction<NewMessageIntent>(
            onInvoke: (_) {
              _openCompose(context, controller);
              return null;
            },
          ),
        },
        // App shell
        child: Scaffold(
          // Main column
          body: Column(
            children: [
              // Progress bar
              MobilePowProgressBar(sync: widget.state.sync),
              // Current screen
              Expanded(
                child: _MobileScreenBody(
                  tab: _selectedTab,
                  state: widget.state,
                  controller: controller,
                  readState: () => ref.read(appControllerProvider),
                ),
              ),
            ],
          ),
          // Compose button
          floatingActionButton: _floatingActionButton(context, controller),
          // Bottom nav
          bottomNavigationBar: NavigationBar(
            selectedIndex: _MobileTab.values.indexOf(_selectedTab),
            onDestinationSelected: (index) {
              setState(() {
                _selectedTab = _MobileTab.values[index];
              });
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.mail_outline),
                selectedIcon: Icon(Icons.mail),
                label: 'Messages',
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: 'Contacts',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_circle_outlined),
                selectedIcon: Icon(Icons.account_circle),
                label: 'Account',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openCompose(
    BuildContext context,
    AppController controller, {
    String? recipientAddress,
  }) {
    if (widget.state.accounts.isEmpty) {
      return;
    }
    final state = widget.state;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return _MobileComposeScreen(
            state: state,
            controller: controller,
            readState: () => ref.read(appControllerProvider),
            initialRecipientAddress: recipientAddress,
          );
        },
      ),
    );
  }

  Widget? _floatingActionButton(
    BuildContext context,
    AppController controller,
  ) {
    if (_selectedTab == _MobileTab.messages) {
      return FloatingActionButton(
        onPressed: widget.state.accounts.isEmpty
            ? null
            : () => _openCompose(context, controller),
        child: const Icon(Icons.edit_outlined),
      );
    }
    if (_selectedTab == _MobileTab.contacts) {
      return FloatingActionButton(
        onPressed: widget.state.accounts.isEmpty
            ? null
            : () => _openContactDialog(context, controller),
        child: const Icon(Icons.person_add_alt_1_outlined),
      );
    }
    return null;
  }

  void _openContactDialog(BuildContext context, AppController controller) {
    final account = widget.state.selectedAccount ?? widget.state.accounts.first;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: _MobileAddContactSheet(
            account: account,
            controller: controller,
          ),
        );
      },
    );
    controller.refreshContacts(account);
  }
}

final class _MobileScreenBody extends StatelessWidget {
  const _MobileScreenBody({
    required this.tab,
    required this.state,
    required this.controller,
    required this.readState,
  });

  final _MobileTab tab;
  final AppState state;
  final AppController controller;
  final AppState Function() readState;

  @override
  Widget build(BuildContext context) {
    switch (tab) {
      case _MobileTab.messages:
        return _MobileMessagesScreen(
          state: state,
          controller: controller,
        );
      case _MobileTab.contacts:
        return _MobileContactsScreen(
          state: state,
          controller: controller,
          readState: readState,
        );
      case _MobileTab.account:
        return _MobileAccountScreen(
          state: state,
          controller: controller,
        );
      case _MobileTab.settings:
        return _MobileSettingsScreen(state: state);
    }
  }
}

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
                  label: _MailboxSegmentLabel(
                    label: 'Inbox',
                    unreadCount: inboxUnreadCount,
                  ),
                ),
                ButtonSegment(
                  value: Mailbox.outbox,
                  icon: Icon(mailboxIcon(Mailbox.outbox)),
                  label: _MailboxSegmentLabel(
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
                          _formatMessageDate(message.createdAt),
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

final class _MailboxSegmentLabel extends StatelessWidget {
  const _MailboxSegmentLabel({
    required this.label,
    required this.unreadCount,
  });

  final String label;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    final countSuffix = unreadCount > 0 ? ' ($unreadCount)' : '';
    return Text(
      '$label$countSuffix',
      style: TextStyle(
        fontWeight: unreadCount > 0 ? FontWeight.bold : null,
      ),
    );
  }
}

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
                  _MessageHeaderRow(
                    label: 'From',
                    value: contactDisplayName(contacts, message.senderAddress),
                  ),
                  _MessageHeaderRow(
                    label: 'To',
                    value: contactDisplayName(
                      contacts,
                      message.recipientAddress,
                    ),
                  ),
                  _MessageHeaderRow(
                    label: 'Date',
                    value: _formatMessageDateTimeWithSeconds(
                      message.createdAt,
                    ),
                  ),
                  _MessageHeaderRow(
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

final class _MobileContactsScreen extends StatefulWidget {
  const _MobileContactsScreen({
    required this.state,
    required this.controller,
    required this.readState,
  });

  final AppState state;
  final AppController controller;
  final AppState Function() readState;

  @override
  State<_MobileContactsScreen> createState() => _MobileContactsScreenState();
}

final class _MobileContactsScreenState extends State<_MobileContactsScreen> {
  bool _requestedInitialContacts = false;

  @override
  Widget build(BuildContext context) {
    final account =
        widget.state.selectedAccount ?? widget.state.accounts.firstOrNull;
    if (!_requestedInitialContacts && account != null) {
      _requestedInitialContacts = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.refreshContacts(account);
      });
    }
    if (account == null) {
      return const Center(child: NewAccountButton());
    }
    final contacts = widget.state.contacts;
    final contactRows = _contactRows(contacts);
    return SafeArea(
      child: contacts.isEmpty
          ? const Center(child: Text('No contacts'))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: contactRows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = contactRows[index];
                if (row is _MobileContactSectionRow) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                    child: Text(
                      row.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  );
                }
                final contact = (row as _MobileContactItemRow).contact;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: AccountTitle(
                    name: contact.name.isEmpty
                        ? shortText(contact.address, 32)
                        : contact.name,
                    isSilent: contact.isSilent,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  subtitle: Text(shortText(contact.address, 40)),
                  trailing: contact.approved
                      ? const Icon(Icons.verified_user_outlined)
                      : null,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => _MobileContactDetailScreen(
                          account: account,
                          contact: contact,
                          controller: widget.controller,
                          state: widget.state,
                          readState: widget.readState,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  List<_MobileContactRow> _contactRows(List<ContactRecord> contacts) {
    final rows = <_MobileContactRow>[];
    for (final contact in contacts) {
      if (contact.approved) {
        rows.add(_MobileContactItemRow(contact));
      }
    }
    var addedRecentHeader = false;
    for (final contact in contacts) {
      if (contact.approved) {
        continue;
      }
      if (!addedRecentHeader) {
        rows.add(const _MobileContactSectionRow('Last contacts'));
        addedRecentHeader = true;
      }
      rows.add(_MobileContactItemRow(contact));
    }
    return rows;
  }
}

sealed class _MobileContactRow {
  const _MobileContactRow();
}

final class _MobileContactItemRow extends _MobileContactRow {
  const _MobileContactItemRow(this.contact);

  final ContactRecord contact;
}

final class _MobileContactSectionRow extends _MobileContactRow {
  const _MobileContactSectionRow(this.title);

  final String title;
}

final class _MobileAddContactSheet extends StatefulWidget {
  const _MobileAddContactSheet({
    required this.account,
    required this.controller,
  });

  final AccountRecord account;
  final AppController controller;

  @override
  State<_MobileAddContactSheet> createState() => _MobileAddContactSheetState();
}

final class _MobileAddContactSheetState extends State<_MobileAddContactSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _address = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'New contact',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Name',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _address,
          decoration: const InputDecoration(
            labelText: 'Address',
            prefixIcon: Icon(Icons.alternate_email_outlined),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () async {
            final added = await widget.controller.addContact(
              account: widget.account,
              name: _name.text,
              address: _address.text,
            );
            if (added && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.person_add_alt_1_outlined),
          label: const Text('Add contact'),
        ),
      ],
    );
  }
}

final class _MobileContactDetailScreen extends StatefulWidget {
  const _MobileContactDetailScreen({
    required this.account,
    required this.contact,
    required this.controller,
    required this.state,
    required this.readState,
  });

  final AccountRecord account;
  final ContactRecord contact;
  final AppController controller;
  final AppState state;
  final AppState Function() readState;

  @override
  State<_MobileContactDetailScreen> createState() =>
      _MobileContactDetailScreenState();
}

final class _MobileContactDetailScreenState
    extends State<_MobileContactDetailScreen> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.contact.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contact')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 16),
            _MessageHeaderRow(
              label: 'Address',
              value: widget.contact.address,
            ),
            _MessageHeaderRow(
              label: 'Account',
              value: widget.account.name,
            ),
            _MessageHeaderRow(
              label: 'Created',
              value: _formatMessageDateTime(widget.contact.createdAt),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => _MobileComposeScreen(
                      state: widget.state,
                      controller: widget.controller,
                      readState: widget.readState,
                      initialRecipientAddress: widget.contact.address,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send message'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                final updated = await widget.controller.addContact(
                  account: widget.account,
                  name: _name.text,
                  address: widget.contact.address,
                );
                if (updated && context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _deleteContact(context),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteContact(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete contact?'),
          content: Text(
            'Delete ${contactDisplayName(
              <ContactRecord>[widget.contact],
              widget.contact.address,
            )} from contacts.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    final deleted = await widget.controller.deleteContact(
      account: widget.account,
      address: widget.contact.address,
    );
    if (deleted && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

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
              _AccountInfoRow(
                label: 'Created',
                value: _formatMessageDateTime(account.createdAt),
              ),
              _AccountInfoRow(
                label: 'Silent',
                value: '$isSilent',
              ),
              _AccountInfoRow(
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

final class _AccountInfoRow extends StatelessWidget {
  const _AccountInfoRow({
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
          _SettingsStatusRow(
            label: 'Version',
            value: state.appVersion?.displayText ?? 'unknown',
          ),
          const SizedBox(height: 12),
          _SettingsStatusRow(
            label: 'Peers',
            value: '${state.sync.onlinePeerCount}/${state.sync.totalPeerCount}',
          ),
          const SizedBox(height: 12),
          _SettingsStatusRow(
            label: 'Anonymity set',
            value: '${state.sync.totalSyncedMessages}',
          ),
          const SizedBox(height: 12),
          _SettingsStatusRow(
            label: 'PoW',
            value: state.sync.powActivity,
          ),
          const SizedBox(height: 12),
          _SettingsStatusRow(
            label: 'Progress',
            value: '${state.sync.powProgress}%',
          ),
          const SizedBox(height: 12),
          _SettingsStatusRow(
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

final class _SettingsStatusRow extends StatelessWidget {
  const _SettingsStatusRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    );
  }
}

final class _MobileComposeScreen extends StatelessWidget {
  const _MobileComposeScreen({
    required this.state,
    required this.controller,
    required this.readState,
    this.initialRecipientAddress,
  });

  final AppState state;
  final AppController controller;
  final AppState Function() readState;
  final String? initialRecipientAddress;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        closeComposeShortcutActivator: CloseComposeIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          CloseComposeIntent: CallbackAction<CloseComposeIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        // Compose shell
        child: Scaffold(
          // Top bar
          appBar: AppBar(
            title: const Text('Write message'),
          ),
          // Safe layout
          body: SafeArea(
            // Main column
            child: Column(
              children: [
                // Progress bar
                Consumer(
                  builder: (context, ref, _) {
                    final sync = ref.watch(appControllerProvider).sync;
                    return MobilePowProgressBar(sync: sync);
                  },
                ),
                // Compose form
                Expanded(
                  child: MessageComposeForm(
                    accounts: state.accounts,
                    initialAccountId: state.selectedAccount?.id,
                    initialRecipientAddress: initialRecipientAddress,
                    contacts: state.contacts,
                    autofocusAddress: true,
                    padding: const EdgeInsets.all(20),
                    onCancel: () => Navigator.of(context).pop(),
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
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatMessageDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$month/$day';
}

String _formatMessageDateTime(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _formatMessageDateTimeWithSeconds(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute:$second';
}
