part of '../mobile_layout.dart';

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
