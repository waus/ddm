import 'dart:convert';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';

enum AppLoadStatus { starting, ready, failed }

enum AppSection { accounts, mailbox, compose, diagnostics }

enum SyncRunStatus { idle, running, succeeded, failed }

final class SyncDiagnostics {
  const SyncDiagnostics({
    this.registeredProtocols = const <String>[],
    this.onlinePeerCount = 0,
    this.totalPeerCount = 0,
    this.totalSyncedMessages = 0,
    this.powActivity = 'Idle',
    this.powProgress = 0,
    this.lastSyncMessage,
    this.status = SyncRunStatus.idle,
    this.externalStorageFileUrls = const <String>[],
  });

  final List<String> registeredProtocols;
  final int onlinePeerCount;
  final int totalPeerCount;
  final int totalSyncedMessages;
  final String powActivity;
  final int powProgress;
  final String? lastSyncMessage;
  final SyncRunStatus status;
  final List<String> externalStorageFileUrls;

  SyncDiagnostics copyWith({
    List<String>? registeredProtocols,
    int? onlinePeerCount,
    int? totalPeerCount,
    int? totalSyncedMessages,
    String? powActivity,
    int? powProgress,
    String? lastSyncMessage,
    SyncRunStatus? status,
    List<String>? externalStorageFileUrls,
  }) {
    return SyncDiagnostics(
      registeredProtocols: registeredProtocols ?? this.registeredProtocols,
      onlinePeerCount: onlinePeerCount ?? this.onlinePeerCount,
      totalPeerCount: totalPeerCount ?? this.totalPeerCount,
      totalSyncedMessages: totalSyncedMessages ?? this.totalSyncedMessages,
      powActivity: powActivity ?? this.powActivity,
      powProgress: powProgress ?? this.powProgress,
      lastSyncMessage: lastSyncMessage ?? this.lastSyncMessage,
      status: status ?? this.status,
      externalStorageFileUrls:
          externalStorageFileUrls ?? this.externalStorageFileUrls,
    );
  }
}

final class AppState {
  const AppState({
    this.status = AppLoadStatus.starting,
    this.section = AppSection.accounts,
    this.mailbox = Mailbox.inbox,
    this.accounts = const <AccountRecord>[],
    this.messages = const <MessageRecord>[],
    this.selectedAccount,
    this.selectedMessage,
    this.errorMessage,
    this.sync = const SyncDiagnostics(),
  });

  final AppLoadStatus status;
  final AppSection section;
  final Mailbox mailbox;
  final List<AccountRecord> accounts;
  final List<MessageRecord> messages;
  final AccountRecord? selectedAccount;
  final MessageRecord? selectedMessage;
  final String? errorMessage;
  final SyncDiagnostics sync;

  bool get hasAccounts => accounts.isNotEmpty;

  AppState copyWith({
    AppLoadStatus? status,
    AppSection? section,
    Mailbox? mailbox,
    List<AccountRecord>? accounts,
    List<MessageRecord>? messages,
    AccountRecord? selectedAccount,
    bool clearSelectedAccount = false,
    MessageRecord? selectedMessage,
    bool clearSelectedMessage = false,
    String? errorMessage,
    bool clearError = false,
    SyncDiagnostics? sync,
  }) {
    return AppState(
      status: status ?? this.status,
      section: section ?? this.section,
      mailbox: mailbox ?? this.mailbox,
      accounts: accounts ?? this.accounts,
      messages: messages ?? this.messages,
      selectedAccount:
          clearSelectedAccount ? null : selectedAccount ?? this.selectedAccount,
      selectedMessage:
          clearSelectedMessage ? null : selectedMessage ?? this.selectedMessage,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      sync: sync ?? this.sync,
    );
  }
}

String mailboxLabel(Mailbox mailbox) {
  switch (mailbox) {
    case Mailbox.inbox:
      return 'Inbox';
    case Mailbox.outbox:
      return 'Outbox';
  }
}

String stateLabel(String state) {
  switch (state) {
    case messageStateCreated:
      return 'Created';
    case messageStatePowSynced:
      return 'PoW synced';
    case messageStateReceived:
      return 'Received';
    case messageStateDelivered:
      return 'Delivered';
    default:
      return state;
  }
}

String messageStatusLabel(MessageRecord message, Mailbox mailbox) {
  if (mailbox == Mailbox.inbox && !message.isRead) {
    return 'Unread';
  }
  return stateLabel(message.state);
}

String messagePeer(MessageRecord message, Mailbox mailbox) {
  return mailbox == Mailbox.inbox
      ? message.senderAddress
      : message.recipientAddress;
}

String messagePreview(MessageRecord message) {
  if (message.payloadType == MessageType.ack) {
    return 'Delivery acknowledgement';
  }
  return utf8.decode(message.payload, allowMalformed: true).trim();
}

String shortText(String value, [int max = 18]) {
  if (value.length <= max) {
    return value;
  }
  if (max <= 3) {
    return value.substring(0, max);
  }
  return '${value.substring(0, max - 3)}...';
}
