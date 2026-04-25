import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';

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
    this.onCancel,
    this.padding = const EdgeInsets.all(24),
    this.autofocusAddress = false,
    super.key,
  });

  final List<AccountRecord> accounts;
  final int? initialAccountId;
  final MessageComposeSubmit onSubmit;
  final VoidCallback? onCancel;
  final EdgeInsets padding;
  final bool autofocusAddress;

  @override
  State<MessageComposeForm> createState() => _MessageComposeFormState();
}

final class _MessageComposeFormState extends State<MessageComposeForm> {
  late final TextEditingController _addressController;
  late final TextEditingController _textController;
  late Duration _ttl;
  int? _selectedAccountId;
  String? _submitError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController();
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

    return ListView(
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
        const SizedBox(height: 16),
        TextField(
          controller: _textController,
          readOnly: _submitting,
          minLines: 8,
          maxLines: 16,
          decoration: const InputDecoration(
            labelText: 'Text',
            alignLabelWithHint: true,
          ),
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
              TextButton(
                onPressed: _submitting ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            if (widget.onCancel != null) const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send'),
            ),
          ],
        ),
      ],
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
