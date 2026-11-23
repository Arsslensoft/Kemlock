import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/logins/login_sheet.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../spaces/chain_kit.dart';

// The Send button in the login sheet (docs/plans/add-server-spaces.md, task 5.5): a password the space hides from the
// member can't be revealed or copied, and can't be sent either, so the sheet offers no Send for it. A login without that
// grant keeps its Send button.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);

  const larkspur = Login(
    id: 'l1',
    name: 'Larkspur Mail',
    username: 'ada@example.org',
    password: 'kT9#vq2L-wPz8!mR4x',
    websites: ['larkspur.example'],
    addedAt: 0,
  );

  /// What a run of the space reports for Bob, who holds [permission] on "Everyone", where the login is.
  SpaceHold holdFor(CollectionPermission permission) {
    final chain = ChainBuilder(space)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: permission});
    return SpaceHold(chain: chain.state, account: bob.id, collections: {'l1': everyone});
  }

  Finder inSheet(Finder finder) => find.descendant(of: find.byType(LoginSheet), matching: finder);

  Future<void> openLogin(WidgetTester tester, CollectionPermission permission) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addLogin(larkspur.copyWith(spaceId: space));
    app.container.read(hiddenPasswordsProvider.notifier).remember(space, holdFor(permission));
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.filter.logins')));
    await tapOn(tester, find.text(larkspur.name));
  }

  for (final permission in [CollectionPermission.viewHidePasswords, CollectionPermission.editHidePasswords]) {
    testWidgets('the login sheet of a login granted ${permission.wire} shows no Send for its password', (tester) async {
      await openLogin(tester, permission);

      expect(find.byType(LoginSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('login-password-space-hidden')), findsOneWidget);
      expect(find.byTooltip(t('sends.fromItem.login')), findsNothing);
      expect(inSheet(find.byIcon(Icons.send_rounded)), findsNothing);
    });
  }

  testWidgets('the login sheet of a login granted edit still shows a Send for its password', (tester) async {
    await openLogin(tester, CollectionPermission.edit);

    expect(find.byKey(const ValueKey('login-password-space-hidden')), findsNothing);
    expect(inSheet(find.byTooltip(t('sends.fromItem.login'))), findsOneWidget);
    expect(inSheet(find.byIcon(Icons.send_rounded)), findsOneWidget);
  });
}
