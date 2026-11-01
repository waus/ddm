import 'dart:async';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_qr_code.dart';
import 'app_date_formatting.dart';
import 'account_policy.dart';
import 'app_controller.dart';
import 'app_shortcuts.dart';
import 'app_state.dart';
import 'app_theme.dart';
import 'contact_book.dart';
import 'external_storage_status_button.dart';
import 'labeled_value_row.dart';
import 'mailbox_icon.dart';
import 'message_compose_form.dart';
import 'new_account_dialog.dart';
import 'theme_mode_toggle.dart';

part 'desktop_layout/sidebar.dart';
part 'desktop_layout/detail_pane.dart';
part 'desktop_layout/account_pane.dart';
part 'desktop_layout/mailbox_pane.dart';
part 'desktop_layout/compose_pane.dart';
part 'desktop_layout/message_list.dart';
part 'desktop_layout/message_detail.dart';
part 'desktop_layout/status_bar.dart';
part 'desktop_layout/selection.dart';

const desktopSidebarInitialFraction = 0.2;
const desktopSidebarMinWidth = 180.0;
const desktopContentMinWidth = 560.0;
const desktopDividerWidth = 1.0;
const desktopSidebarFractionKey = 'desktop_sidebar_fraction';
const _desktopDividerHitWidth = 12.0;
const _desktopMailboxListInitialFraction = 0.5;
const _desktopMailboxListMinHeight = 180.0;
const _desktopMessageDetailMinHeight = 180.0;
const _desktopMessageListRowHeight = 36.0;
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
    final desktopTheme = buildDesktopTheme(Theme.of(context));
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        newMessageShortcut: const NewMessageIntent(),
        closeComposeShortcutActivator: const CloseComposeIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewMessageIntent: CallbackAction<NewMessageIntent>(
            onInvoke: (_) {
              _openCompose(state, controller);
              return null;
            },
          ),
          CloseComposeIntent: CallbackAction<CloseComposeIntent>(
            onInvoke: (_) {
              if (_selection is _DesktopComposeSelection) {
                _closeCompose(state);
              }
              return null;
            },
          ),
        },
        child: Theme(
          data: desktopTheme,
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
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: Border(
                        bottom: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Tooltip(
                          message:
                              'Write message (${newMessageShortcutLabel()})',
                          waitDuration: const Duration(milliseconds: 200),
                          child: FilledButton.icon(
                            onPressed: state.accounts.isEmpty
                                ? null
                                : () => _openCompose(state, controller),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Write message'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: state.accounts.isEmpty
                              ? null
                              : () => _openAddressBook(
                                    context,
                                    state,
                                    controller,
                                  ),
                          icon: const Icon(Icons.people_outline),
                          label: const Text('Address book'),
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
                            (_sidebarFraction ?? desktopSidebarInitialFraction);
                        final sidebarWidth = fallbackSidebarWidth.clamp(
                          desktopSidebarMinWidth,
                          effectiveMaxSidebarWidth,
                        );
                        final messagesWidth =
                            availableWidth - sidebarWidth - desktopDividerWidth;

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
                                          _selection = _DesktopAccountSelection(
                                              account.id);
                                        });
                                        controller.selectAccount(account);
                                      },
                                      onMailboxSelected: (account, mailbox) {
                                        setState(() {
                                          _selection = _DesktopMailboxSelection(
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
                                    onComposeCancel: () => _closeCompose(state),
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
                                        (sidebarWidth + details.delta.dx).clamp(
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
                    state: state,
                    onExternalStoragePressed:
                        controller.chooseExternalStorageFile,
                    onUpdatePressed: controller.openUpdateSite,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openCompose(
    AppState state,
    AppController controller, {
    String? recipientAddress,
  }) {
    if (state.accounts.isEmpty) {
      return;
    }
    final account = state.selectedAccount ?? state.accounts.first;
    setState(() {
      if (_selection is! _DesktopComposeSelection) {
        _selectionBeforeCompose = _selection;
      }
      _selection = _DesktopComposeSelection(
        account.id,
        recipientAddress: recipientAddress,
      );
    });
    controller.selectSection(AppSection.compose);
  }

  void _openAddressBook(
    BuildContext context,
    AppState state,
    AppController controller,
  ) {
    final account = state.selectedAccount ?? state.accounts.firstOrNull;
    if (account != null) {
      controller.refreshContacts(account);
    }
    showDialog<void>(
      context: context,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final liveState = ref.watch(appControllerProvider);
            return Dialog(
              child: SizedBox(
                width: 760,
                height: 560,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Address book',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ContactBookPanel(
                          state: liveState,
                          controller: controller,
                          onComposeToContact: (contact) {
                            Navigator.of(context).pop();
                            _openCompose(
                              liveState,
                              controller,
                              recipientAddress: contact.address,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
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
