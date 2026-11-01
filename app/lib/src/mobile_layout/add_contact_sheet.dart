part of '../mobile_layout.dart';

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
