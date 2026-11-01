part of '../desktop_layout.dart';

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
          recipientAddress: composeSelection.recipientAddress,
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
