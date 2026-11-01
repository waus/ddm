part of '../runtime.dart';

final class AccountOverview {
  const AccountOverview({
    required this.account,
    required this.inboxCount,
    required this.outboxCount,
  });

  final AccountRecord account;
  final int inboxCount;
  final int outboxCount;
}

final class AccountKeyExport {
  AccountKeyExport({
    required this.account,
    required Uint8List publicKey,
    required Uint8List privateKey,
  })  : publicKey = Uint8List.fromList(publicKey),
        privateKey = Uint8List.fromList(privateKey);

  final AccountRecord account;
  final Uint8List publicKey;
  final Uint8List privateKey;
}

final class _DecryptedImportedMessage {
  _DecryptedImportedMessage({
    required this.account,
    required this.decrypted,
  });

  final AccountRecord account;
  final UnencryptedMessage decrypted;
}

final class AccountManager {
  AccountManager({required DdmSqliteStorage storage}) : _storage = storage {
    _reset(storage.accounts.listAccounts());
  }

  final DdmSqliteStorage _storage;
  final Map<String, AccountRecord> _byAddress = <String, AccountRecord>{};
  final Map<int, List<AccountRecord>> _byStream = <int, List<AccountRecord>>{};

  AccountRecord createAccount(AccountInsert input) {
    final created = _storage.accounts.createAccount(input);
    _byAddress[created.address] = created;
    (_byStream[created.streamId.toUint32()] ??= <AccountRecord>[]).add(created);
    return created;
  }

  List<AccountRecord> listAccounts() {
    return _byAddress.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  AccountRecord? accountByAddress(String address) {
    final normalized = address.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return _byAddress[normalized];
  }

  Future<_DecryptedImportedMessage?> _decryptImportedMessage(
    EncryptedMessage encrypted, {
    RecipientPayloadDecryptor decrypt = decryptForRecipientWithDage,
  }) async {
    final accounts = List<AccountRecord>.from(
      _byStream[encrypted.streamNumber.toUint32()] ?? const <AccountRecord>[],
    );
    for (final account in accounts) {
      Uint8List plaintext;
      try {
        plaintext = await decrypt(
          privateKey: account.privateKey,
          publicKey: account.publicKey,
          ciphertext: encrypted.payload,
        );
      } catch (_) {
        continue;
      }
      try {
        final decrypted = UnencryptedMessage.fromBytes(plaintext);
        return _DecryptedImportedMessage(
          account: account,
          decrypted: decrypted,
        );
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  void _reset(List<AccountRecord> accounts) {
    _byAddress.clear();
    _byStream.clear();
    for (final account in accounts) {
      _byAddress[account.address] = account;
      (_byStream[account.streamId.toUint32()] ??= <AccountRecord>[])
          .add(account);
    }
  }
}

final class AccountsService {
  AccountsService({
    required DdmSqliteStorage storage,
    required AccountManager accountManager,
    required UtcNow nowUtc,
    required RandomBytes randomBytes,
  })  : _storage = storage,
        _accountManager = accountManager,
        _nowUtc = nowUtc,
        _randomBytes = randomBytes;

  final DdmSqliteStorage _storage;
  final AccountManager _accountManager;
  final UtcNow _nowUtc;
  final RandomBytes _randomBytes;

  Future<AccountRecord> createAccount(
    String accountName, {
    int policy = 0,
  }) async {
    final name = normalizeAccountName(accountName, _nowUtc);
    final keys = await newAccountKeys(_randomBytes);
    final address = Address.newV1(keys.publicKey, policy: policy);
    return _accountManager.createAccount(
      AccountInsert(
        name: name,
        address: address.toText(),
        publicKey: keys.publicKey,
        privateKey: keys.privateKey,
        streamId: address.streamId(),
        createdAt: _nowUtc(),
      ),
    );
  }

  List<AccountRecord> listAccounts() {
    return _accountManager.listAccounts();
  }

  AccountOverview getAccountOverview(AccountRecord account) {
    final local = requireLocalAccount(account);
    return AccountOverview(
      account: local,
      inboxCount: _storage.messages.countMessagesByRecipientAddress(
        local.address,
      ),
      outboxCount: _storage.messages.countMessagesBySenderAddress(
        local.address,
      ),
    );
  }

  List<MessageRecord> listMailboxMessages(
    AccountRecord account,
    Mailbox mailbox,
  ) {
    final local = requireLocalAccount(account);
    switch (mailbox) {
      case Mailbox.inbox:
        return _storage.messages.listMessagesByRecipientAddress(local.address);
      case Mailbox.outbox:
        return _storage.messages.listMessagesBySenderAddress(local.address);
    }
  }

  void markMessageRead(AccountRecord account, MessageId messageId) {
    final local = requireLocalAccount(account);
    final message = _storage.messages.getMessageById(messageId);
    if (message == null) {
      throw FormatException('message ${messageId.toHex()} not found');
    }
    if (message.recipientAddress != local.address) {
      throw FormatException(
        'message ${messageId.toHex()} does not belong to inbox account ${local.address}',
      );
    }
    if (message.isRead) {
      return;
    }
    _storage.messages.markMessageRead(messageId);
  }

  int deleteLocalMessages(
    AccountRecord account,
    Iterable<MessageId> messageIds, {
    required DateTime now,
  }) {
    final local = requireLocalAccount(account);
    final messages = <MessageRecord>[];
    for (final messageId in messageIds) {
      final message = _storage.messages.getMessageById(messageId);
      if (message == null) {
        continue;
      }
      if (!_messageBelongsToAccount(message, local)) {
        throw FormatException(
          'message ${messageId.toHex()} does not belong to account ${local.address}',
        );
      }
      if (!canDeleteLocalMessage(message, now)) {
        throw FormatException(
          'received message ${messageId.toHex()} cannot be deleted before it expires',
        );
      }
      messages.add(message);
    }
    var deleted = 0;
    for (final message in messages) {
      if (_storage.messages.deleteMessageById(message.id)) {
        deleted++;
      }
    }
    return deleted;
  }

  bool _messageBelongsToAccount(MessageRecord message, AccountRecord account) {
    return message.senderAddress == account.address ||
        message.recipientAddress == account.address;
  }

  AccountKeyExport exportAccountKeys(AccountRecord account) {
    final local = requireLocalAccount(account);
    return AccountKeyExport(
      account: local,
      publicKey: local.publicKey,
      privateKey: local.privateKey,
    );
  }

  AccountRecord requireLocalAccount(AccountRecord account) {
    final parsed = Address.fromText(account.address);
    final local = _accountManager.accountByAddress(parsed.toText());
    if (local == null) {
      throw FormatException(
        'account address ${parsed.toText()} not found in local db',
      );
    }
    return local;
  }
}

bool canDeleteLocalMessage(MessageRecord message, DateTime now) {
  return message.state != messageStateReceived ||
      !message.expiresAt.isAfter(now.toUtc());
}
