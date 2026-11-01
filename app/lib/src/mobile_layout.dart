import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_qr_code.dart';
import 'app_date_formatting.dart';
import 'account_policy.dart';
import 'app_controller.dart';
import 'app_shortcuts.dart';
import 'app_state.dart';
import 'app_update_notice.dart';
import 'labeled_value_row.dart';
import 'mailbox_icon.dart';
import 'mobile_layout/mailbox_segment_label.dart';
import 'message_compose_form.dart';
import 'mobile_pow_progress_bar.dart';
import 'new_account_dialog.dart';
import 'theme_mode_toggle.dart';

part 'mobile_layout/tabs.dart';
part 'mobile_layout/screen_body.dart';
part 'mobile_layout/messages_screen.dart';
part 'mobile_layout/message_detail_screen.dart';
part 'mobile_layout/contacts_screen.dart';
part 'mobile_layout/contact_rows.dart';
part 'mobile_layout/add_contact_sheet.dart';
part 'mobile_layout/contact_detail_screen.dart';
part 'mobile_layout/account_screen.dart';
part 'mobile_layout/settings_screen.dart';
part 'mobile_layout/compose_screen.dart';

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
