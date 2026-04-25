import 'dart:io';

import 'package:ddm_app/src/account_policy.dart';
import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AccountPolicyView parses silent state from address policy', () async {
    final workspace = Directory.systemTemp.createTempSync('ddm-policy-test-');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final core = DdmCore.open(workspace.path);
    addTearDown(core.close);

    final defaultAccount = await core.accounts.createAccount(
      'Default',
      policy: addressPolicyAckExpected,
    );
    final silentAccount =
        await core.accounts.createAccount('Silent', policy: 0);

    expect(defaultAccount.isSilent, isFalse);
    expect(silentAccount.isSilent, isTrue);
  });
}
