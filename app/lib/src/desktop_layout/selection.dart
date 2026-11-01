part of '../desktop_layout.dart';

sealed class _DesktopSelection {
  const _DesktopSelection(this.accountId);

  final int accountId;
}

final class _DesktopAccountSelection extends _DesktopSelection {
  const _DesktopAccountSelection(super.accountId);
}

final class _DesktopMailboxSelection extends _DesktopSelection {
  const _DesktopMailboxSelection(super.accountId, this.mailbox);

  final Mailbox mailbox;
}

final class _DesktopComposeSelection extends _DesktopSelection {
  const _DesktopComposeSelection(super.accountId, {this.recipientAddress});

  final String? recipientAddress;
}
