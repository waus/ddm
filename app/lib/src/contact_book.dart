import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';

import 'account_policy.dart';
import 'app_controller.dart';
import 'app_state.dart';

final class ContactBookPanel extends StatefulWidget {
  const ContactBookPanel({
    required this.state,
    required this.controller,
    this.onComposeToContact,
    this.showAccountSelector = true,
    super.key,
  });

  final AppState state;
  final AppController controller;
  final ValueChanged<ContactRecord>? onComposeToContact;
  final bool showAccountSelector;

  @override
  State<ContactBookPanel> createState() => _ContactBookPanelState();
}

final class _ContactBookPanelState extends State<ContactBookPanel> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _address = TextEditingController();
  int? _accountId;
  ContactRecord? _editingContact;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = _selectedAccount(widget.state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showAccountSelector) ...[
          DropdownButtonFormField<int>(
            initialValue: account?.id,
            decoration: const InputDecoration(
              labelText: 'Account',
              prefixIcon: Icon(Icons.account_circle_outlined),
            ),
            items: [
              for (final localAccount in widget.state.accounts)
                DropdownMenuItem(
                  value: localAccount.id,
                  child: Text(localAccount.name),
                ),
            ],
            onChanged: (id) {
              if (id == null) {
                return;
              }
              final next = _accountById(widget.state.accounts, id);
              if (next == null) {
                return;
              }
              setState(() {
                _accountId = id;
                _editingContact = null;
                _name.clear();
                _address.clear();
              });
              widget.controller.refreshContacts(next);
            },
          ),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _address,
                readOnly: _editingContact != null,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  prefixIcon: Icon(Icons.alternate_email_outlined),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              tooltip: _editingContact == null ? 'Add contact' : 'Save contact',
              onPressed: account == null ? null : () => _submit(account),
              icon: Icon(
                _editingContact == null
                    ? Icons.person_add_alt_1_outlined
                    : Icons.save_outlined,
              ),
            ),
            if (_editingContact != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Cancel editing',
                onPressed: _clearForm,
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: account == null
              ? const Center(child: Text('No accounts'))
              : _ContactList(
                  contacts: widget.state.contacts,
                  editingContact: _editingContact,
                  onEdit: _editContact,
                  onDelete: (contact) => _deleteContact(account, contact),
                  onComposeToContact: widget.onComposeToContact,
                ),
        ),
      ],
    );
  }

  AccountRecord? _selectedAccount(AppState state) {
    if (state.accounts.isEmpty) {
      return null;
    }
    final id =
        _accountId ?? state.selectedAccount?.id ?? state.accounts.first.id;
    return _accountById(state.accounts, id) ?? state.accounts.first;
  }

  AccountRecord? _accountById(List<AccountRecord> accounts, int id) {
    for (final account in accounts) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  Future<void> _submit(AccountRecord account) async {
    final added = await widget.controller.addContact(
      account: account,
      name: _name.text,
      address: _address.text,
    );
    if (added) {
      _clearForm();
    }
  }

  void _editContact(ContactRecord contact) {
    setState(() {
      _editingContact = contact;
      _name.text = contact.name;
      _address.text = contact.address;
    });
  }

  Future<void> _deleteContact(
    AccountRecord account,
    ContactRecord contact,
  ) async {
    final deleted = await widget.controller.deleteContact(
      account: account,
      address: contact.address,
    );
    if (!mounted) {
      return;
    }
    if (deleted && _editingContact?.address == contact.address) {
      _clearForm();
    }
  }

  void _clearForm() {
    setState(() {
      _editingContact = null;
      _name.clear();
      _address.clear();
    });
  }
}

final class _ContactList extends StatelessWidget {
  const _ContactList({
    required this.contacts,
    required this.editingContact,
    required this.onEdit,
    required this.onDelete,
    this.onComposeToContact,
  });

  final List<ContactRecord> contacts;
  final ContactRecord? editingContact;
  final ValueChanged<ContactRecord> onEdit;
  final ValueChanged<ContactRecord> onDelete;
  final ValueChanged<ContactRecord>? onComposeToContact;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return const Center(child: Text('No contacts'));
    }
    final approved = contacts.where((contact) => contact.approved).toList();
    final recent = contacts.where((contact) => !contact.approved).toList();
    return ListView(
      children: [
        for (final contact in approved) ...[
          _ContactTile(
            contact: contact,
            selected: contact.address == editingContact?.address,
            onEdit: onEdit,
            onDelete: onDelete,
            onComposeToContact: onComposeToContact,
          ),
          const Divider(height: 1),
        ],
        if (recent.isNotEmpty) ...[
          if (approved.isNotEmpty) const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Last contacts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final contact in recent) ...[
            _ContactTile(
              contact: contact,
              selected: contact.address == editingContact?.address,
              onEdit: onEdit,
              onDelete: onDelete,
              onComposeToContact: onComposeToContact,
            ),
            const Divider(height: 1),
          ],
        ],
      ],
    );
  }
}

final class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.contact,
    required this.selected,
    required this.onEdit,
    required this.onDelete,
    this.onComposeToContact,
  });

  final ContactRecord contact;
  final bool selected;
  final ValueChanged<ContactRecord> onEdit;
  final ValueChanged<ContactRecord> onDelete;
  final ValueChanged<ContactRecord>? onComposeToContact;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      leading: Icon(
        contact.approved ? Icons.verified_user_outlined : Icons.person_outline,
      ),
      title: AccountTitle(
        name: contact.name.isEmpty
            ? shortText(contact.address, 32)
            : contact.name,
        isSilent: contact.isSilent,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: Text(contact.address),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_formatContactDate(contact.createdAt)),
          if (onComposeToContact != null)
            IconButton(
              tooltip: 'Send message',
              onPressed: () => onComposeToContact!(contact),
              icon: const Icon(Icons.send_outlined),
            ),
          IconButton(
            tooltip: 'Edit contact',
            onPressed: () => onEdit(contact),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Delete contact',
            onPressed: () => _confirmDelete(context),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      onTap: () => onEdit(contact),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete contact?'),
          content: Text(
            'Delete ${contactDisplayName(
              <ContactRecord>[contact],
              contact.address,
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
    if (confirmed == true) {
      onDelete(contact);
    }
  }
}

String _formatContactDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}
