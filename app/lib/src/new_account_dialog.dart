import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_name_generator.dart';
import 'app_controller.dart';

Future<void> showNewAccountDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return const NewAccountDialog();
    },
  );
}

final class NewAccountButton extends ConsumerWidget {
  const NewAccountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAccounts = ref.watch(
      appControllerProvider.select((state) => state.accounts.isNotEmpty),
    );
    void onPressed() => showNewAccountDialog(context);
    if (hasAccounts) {
      return OutlinedButton(
        onPressed: onPressed,
        child: const Text('New account'),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      child: const Text('New account'),
    );
  }
}

final class NewAccountDialog extends ConsumerStatefulWidget {
  const NewAccountDialog({super.key});

  @override
  ConsumerState<NewAccountDialog> createState() => _NewAccountDialogState();
}

final class _NewAccountDialogState extends ConsumerState<NewAccountDialog> {
  late final TextEditingController _nameController;
  bool _silent = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: generateAccountName());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New account'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _silent,
              onChanged: (value) {
                setState(() {
                  _silent = value ?? false;
                });
              },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Silent account'),
              subtitle: const Text(
                'No delivery receipts (more private; offline messages may expire).',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _createAccount,
          child: const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _createAccount() async {
    final controller = ref.read(appControllerProvider.notifier);
    final previousCount = ref.read(appControllerProvider).accounts.length;
    setState(() {
      _submitting = true;
    });
    await controller.createAccount(
      _nameController.text,
      silent: _silent,
    );
    final nextState = ref.read(appControllerProvider);
    if (!mounted) {
      return;
    }
    if (nextState.accounts.length > previousCount) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = false;
    });
  }
}
