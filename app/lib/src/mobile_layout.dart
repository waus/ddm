import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_qr_code.dart';
import 'account_policy.dart';
import 'app_controller.dart';
import 'app_shortcuts.dart';
import 'app_state.dart';
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
    return Focus(
      autofocus: true,
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          newMessageShortcutActivator(): const _MobileNewMessageIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _MobileNewMessageIntent: CallbackAction<_MobileNewMessageIntent>(
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
                  ),
                ),
              ],
            ),
            // Compose button
            floatingActionButton: _selectedTab == _MobileTab.messages
                ? FloatingActionButton(
                    onPressed: widget.state.accounts.isEmpty
                        ? null
                        : () => _openCompose(context, controller),
                    child: const Icon(Icons.edit_outlined),
                  )
                : null,
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
      ),
    );
  }

  void _openCompose(BuildContext context, AppController controller) {
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
          );
        },
      ),
    );
  }
}

final class _MobileNewMessageIntent extends Intent {
  const _MobileNewMessageIntent();
}

final class _MobileScreenBody extends StatelessWidget {
  const _MobileScreenBody({
    required this.tab,
    required this.state,
    required this.controller,
  });

  final _MobileTab tab;
  final AppState state;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    switch (tab) {
      case _MobileTab.messages:
        return _MobileMessagesScreen(
          state: state,
          controller: controller,
        );
      case _MobileTab.contacts:
        return const Center(
          child: Text('Contacts'),
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
                widget.controller
                    .selectAccountMailbox(account, selection.single);
              },
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
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          shortText(messagePeer(message, state.mailbox), 32),
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
                          widget.controller.selectMessage(message);
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) {
                                return _MobileMessageDetailScreen(
                                  mailbox: state.mailbox,
                                  message: message,
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
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
  });

  final Mailbox mailbox;
  final MessageRecord message;

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
                    value: message.senderAddress,
                  ),
                  _MessageHeaderRow(
                    label: 'To',
                    value: message.recipientAddress,
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

final class _MobileSettingsScreen extends StatelessWidget {
  const _MobileSettingsScreen({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
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
  });

  final AppState state;
  final AppController controller;
  final AppState Function() readState;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        closeComposeShortcutActivator: _MobileCloseComposeIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MobileCloseComposeIntent: CallbackAction<_MobileCloseComposeIntent>(
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

final class _MobileCloseComposeIntent extends Intent {
  const _MobileCloseComposeIntent();
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
