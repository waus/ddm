part of '../desktop_layout.dart';

final class _DesktopComposePane extends StatelessWidget {
  const _DesktopComposePane({
    required this.state,
    required this.controller,
    required this.accountId,
    this.recipientAddress,
    required this.onCancel,
    required this.onSubmitted,
    required this.readState,
  });

  final AppState state;
  final AppController controller;
  final int accountId;
  final String? recipientAddress;
  final VoidCallback onCancel;
  final ValueChanged<AccountRecord> onSubmitted;
  final AppState Function() readState;

  @override
  Widget build(BuildContext context) {
    return MessageComposeForm(
      accounts: state.accounts,
      initialAccountId: accountId,
      initialRecipientAddress: recipientAddress,
      contacts: state.contacts,
      onCancel: onCancel,
      showSendTooltip: true,
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
