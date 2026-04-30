import 'dart:async';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'app_theme.dart';
import 'app_shortcuts.dart';
import 'message_ttl_field.dart';

typedef MessageComposeSubmit = Future<String?> Function({
  required AccountRecord sender,
  required String recipientAddress,
  required Duration ttl,
  required String text,
});

final class MessageComposeForm extends StatefulWidget {
  const MessageComposeForm({
    required this.accounts,
    required this.onSubmit,
    this.initialAccountId,
    this.initialRecipientAddress,
    this.contacts = const <ContactRecord>[],
    this.onCancel,
    this.padding = const EdgeInsets.all(24),
    this.autofocusAddress = false,
    this.showSendTooltip = false,
    super.key,
  });

  final List<AccountRecord> accounts;
  final int? initialAccountId;
  final String? initialRecipientAddress;
  final List<ContactRecord> contacts;
  final MessageComposeSubmit onSubmit;
  final VoidCallback? onCancel;
  final EdgeInsets padding;
  final bool autofocusAddress;
  final bool showSendTooltip;

  @override
  State<MessageComposeForm> createState() => _MessageComposeFormState();
}

final class _MessageComposeFormState extends State<MessageComposeForm> {
  late final TextEditingController _addressController;
  late final TextEditingController _textController;
  late Duration _ttl;
  int? _selectedAccountId;
  String? _selectedContactAddress;
  String? _submitError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(
      text: widget.initialRecipientAddress?.trim() ?? '',
    );
    _addressController.addListener(_syncSelectedContact);
    _textController = TextEditingController();
    _ttl = messageTtlOptions[6];
    _selectedAccountId = _resolveInitialAccountId(
      widget.accounts,
      widget.initialAccountId,
    );
  }

  @override
  void didUpdateWidget(covariant MessageComposeForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextInitialRecipient = widget.initialRecipientAddress?.trim() ?? '';
    final oldInitialRecipient = oldWidget.initialRecipientAddress?.trim() ?? '';
    if (nextInitialRecipient != oldInitialRecipient &&
        _addressController.text.trim() != nextInitialRecipient) {
      _addressController.text = nextInitialRecipient;
    }
    final selectedId = _selectedAccountId;
    if (selectedId == null) {
      _selectedAccountId = _resolveInitialAccountId(
        widget.accounts,
        widget.initialAccountId,
      );
      return;
    }
    for (final account in widget.accounts) {
      if (account.id == selectedId) {
        return;
      }
    }
    _selectedAccountId = _resolveInitialAccountId(
      widget.accounts,
      widget.initialAccountId,
    );
  }

  @override
  void dispose() {
    _addressController.removeListener(_syncSelectedContact);
    _addressController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.accounts.isEmpty) {
      return Center(
        child: Text(
          'Create an account first',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        submitMessageShortcutActivator(): const SubmitMessageIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          SubmitMessageIntent: CallbackAction<SubmitMessageIntent>(
            onInvoke: (_) {
              if (!_submitting) {
                unawaited(_submit());
              }
              return null;
            },
          ),
        },
        child: ListView(
          padding: widget.padding,
          children: [
            Text(
              'Write message',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<int>(
              initialValue: _selectedAccountId,
              decoration: const InputDecoration(
                labelText: 'From account',
              ),
              items: [
                for (final account in widget.accounts)
                  DropdownMenuItem<int>(
                    value: account.id,
                    child: Text(account.name),
                  ),
              ],
              onChanged: _submitting
                  ? null
                  : (value) {
                      setState(() {
                        _selectedAccountId = value;
                        _selectedContactAddress = null;
                      });
                    },
            ),
            const SizedBox(height: 16),
            _ContactSelector(
              contacts: _recipientContacts,
              value: _selectedContactValue(_recipientContacts),
              enabled: !_submitting,
              onChanged: (address) {
                if (address == null) {
                  return;
                }
                setState(() {
                  _selectedContactAddress = address;
                  _addressController.text = address;
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _addressController,
              readOnly: _submitting,
              autofocus: widget.autofocusAddress,
              decoration: const InputDecoration(
                labelText: 'Address',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              readOnly: _submitting,
              minLines: 8,
              maxLines: 16,
              decoration: multilineTextFieldDecoration(
                context,
                labelText: 'Text',
              ),
            ),
            const SizedBox(height: 16),
            MessageTtlField(
              value: _ttl,
              onChanged: _submitting
                  ? (_) {}
                  : (value) {
                      setState(() {
                        _ttl = value;
                      });
                    },
            ),
            if (_submitError != null) ...[
              const SizedBox(height: 16),
              Text(
                _submitError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                if (widget.onCancel != null)
                  OutlinedButton(
                    onPressed: _submitting ? null : widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                const Spacer(),
                _SendButton(
                  enabled: !_submitting,
                  showTooltip: widget.showSendTooltip,
                  onPressed: _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  int? _resolveInitialAccountId(
    List<AccountRecord> accounts,
    int? initialAccountId,
  ) {
    if (accounts.isEmpty) {
      return null;
    }
    if (initialAccountId != null) {
      for (final account in accounts) {
        if (account.id == initialAccountId) {
          return account.id;
        }
      }
    }
    return accounts.first.id;
  }

  AccountRecord? _selectedAccount(
      List<AccountRecord> accounts, int? accountId) {
    if (accountId == null) {
      return null;
    }
    for (final account in accounts) {
      if (account.id == accountId) {
        return account;
      }
    }
    return null;
  }

  List<ContactRecord> get _recipientContacts {
    final sender = _selectedAccount(widget.accounts, _selectedAccountId);
    if (sender == null) {
      return const <ContactRecord>[];
    }
    return widget.contacts
        .where((contact) => contact.account == sender.address)
        .toList(growable: false);
  }

  String? _selectedContactValue(List<ContactRecord> contacts) {
    final selected = _selectedContactAddress ?? _addressController.text.trim();
    if (selected.isEmpty) {
      return null;
    }
    for (final contact in contacts) {
      if (contact.address == selected) {
        return selected;
      }
    }
    return null;
  }

  void _syncSelectedContact() {
    final current = _addressController.text.trim();
    if (_selectedContactAddress == current) {
      return;
    }
    if (!mounted) {
      _selectedContactAddress = null;
      return;
    }
    setState(() {
      _selectedContactAddress = null;
    });
  }

  Future<void> _submit() async {
    final sender = _selectedAccount(widget.accounts, _selectedAccountId);
    final recipientAddress = _addressController.text.trim();
    final text = _textController.text.trim();

    if (sender == null) {
      setState(() {
        _submitError = 'Select an account';
      });
      return;
    }
    if (recipientAddress.isEmpty) {
      setState(() {
        _submitError = 'Enter a recipient address';
      });
      return;
    }
    if (text.isEmpty) {
      setState(() {
        _submitError = 'Enter a message';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    final error = await widget.onSubmit(
      sender: sender,
      recipientAddress: recipientAddress,
      ttl: _ttl,
      text: text,
    );

    if (!mounted) {
      return;
    }

    if (error != null) {
      setState(() {
        _submitting = false;
        _submitError = error;
      });
      return;
    }
  }
}

final class _ContactSelector extends StatelessWidget {
  const _ContactSelector({
    required this.contacts,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final List<ContactRecord> contacts;
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('${value ?? ''}:${contacts.length}'),
      initialValue: value,
      decoration: const InputDecoration(
        labelText: 'Contact',
        prefixIcon: Icon(Icons.person_outline),
      ),
      items: [
        for (final contact in contacts)
          DropdownMenuItem<String>(
            value: contact.address,
            child: Text(contactDisplayName(contacts, contact.address)),
          ),
      ],
      onChanged: enabled && contacts.isNotEmpty ? onChanged : null,
    );
  }
}

final class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.showTooltip,
    required this.onPressed,
  });

  final bool enabled;
  final bool showTooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: const Icon(Icons.send_outlined),
      label: const Text('Send'),
    );
    if (!showTooltip) {
      return button;
    }
    return Tooltip(
      message: 'Send message (${submitMessageShortcutLabel()})',
      waitDuration: const Duration(milliseconds: 200),
      child: button,
    );
  }
}
