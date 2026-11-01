part of '../mobile_layout.dart';

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
            LabeledValueRow(
              label: 'Address',
              value: widget.contact.address,
            ),
            LabeledValueRow(
              label: 'Account',
              value: widget.account.name,
            ),
            LabeledValueRow(
              label: 'Created',
              value: formatDateTime(widget.contact.createdAt),
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
