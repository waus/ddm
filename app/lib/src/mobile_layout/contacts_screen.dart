part of '../mobile_layout.dart';

final class _MobileContactsScreen extends StatefulWidget {
  const _MobileContactsScreen({
    required this.state,
    required this.controller,
    required this.readState,
  });

  final AppState state;
  final AppController controller;
  final AppState Function() readState;

  @override
  State<_MobileContactsScreen> createState() => _MobileContactsScreenState();
}

final class _MobileContactsScreenState extends State<_MobileContactsScreen> {
  bool _requestedInitialContacts = false;

  @override
  Widget build(BuildContext context) {
    final account =
        widget.state.selectedAccount ?? widget.state.accounts.firstOrNull;
    if (!_requestedInitialContacts && account != null) {
      _requestedInitialContacts = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.refreshContacts(account);
      });
    }
    if (account == null) {
      return const Center(child: NewAccountButton());
    }
    final contacts = widget.state.contacts;
    final contactRows = _contactRows(contacts);
    return SafeArea(
      child: contacts.isEmpty
          ? const Center(child: Text('No contacts'))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: contactRows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = contactRows[index];
                if (row is _MobileContactSectionRow) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                    child: Text(
                      row.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  );
                }
                final contact = (row as _MobileContactItemRow).contact;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: AccountTitle(
                    name: contact.name.isEmpty
                        ? shortText(contact.address, 32)
                        : contact.name,
                    isSilent: contact.isSilent,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  subtitle: Text(shortText(contact.address, 40)),
                  trailing: contact.approved
                      ? const Icon(Icons.verified_user_outlined)
                      : null,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => _MobileContactDetailScreen(
                          account: account,
                          contact: contact,
                          controller: widget.controller,
                          state: widget.state,
                          readState: widget.readState,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  List<_MobileContactRow> _contactRows(List<ContactRecord> contacts) {
    final rows = <_MobileContactRow>[];
    for (final contact in contacts) {
      if (contact.approved) {
        rows.add(_MobileContactItemRow(contact));
      }
    }
    var addedRecentHeader = false;
    for (final contact in contacts) {
      if (contact.approved) {
        continue;
      }
      if (!addedRecentHeader) {
        rows.add(const _MobileContactSectionRow('Last contacts'));
        addedRecentHeader = true;
      }
      rows.add(_MobileContactItemRow(contact));
    }
    return rows;
  }
}
