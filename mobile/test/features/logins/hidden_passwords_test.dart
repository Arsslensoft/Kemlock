import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/gate_widgets.dart';
import 'package:kemlock/features/logins/login_sheet.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../spaces/chain_kit.dart';

// Hidden passwords in the login sheet (docs/plans/add-server-spaces.md, task 5.5): a member granted "passwords hidden" on a
// collection sees dots and a line saying why, with no Show and no Copy for the password of that collection's logins, one
// widget test per permission. The login still holds its password, which AutoFill reads from the login itself.
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

  Future<TestApp> openLogin(WidgetTester tester, Login login, {SpaceHold? hold}) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addLogin(login);
    if (hold != null) {
      app.container.read(hiddenPasswordsProvider.notifier).remember(space, hold);
    }
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.filter.logins')));
    await tapOn(tester, find.text(login.name));
    return app;
  }

  for (final permission in CollectionPermission.values) {
    testWidgets('a login granted ${permission.wire} ${permission.hidesPasswords ? 'hides' : 'shows'} its password in the login sheet', (
      tester,
    ) async {
      final app = await openLogin(tester, larkspur.copyWith(spaceId: space), hold: holdFor(permission));

      final hides = permission.hidesPasswords;
      expect(inSheet(find.byType(RevealPasswordButton)), hides ? findsNothing : findsOneWidget);
      expect(inSheet(find.byTooltip(t('logins.copy.password'))), hides ? findsNothing : findsOneWidget);
      expect(find.byKey(const ValueKey('login-password-space-hidden')), hides ? findsOneWidget : findsNothing);
      expect(find.text(t('logins.password.spaceHidden')), hides ? findsOneWidget : findsNothing);
      expect(inSheet(find.text(larkspur.password!)), findsNothing, reason: 'the password is not on screen unless it is shown');
      // AutoFill reads the login, not the sheet, so it still has the password to fill
      expect(app.container.read(vaultControllerProvider).logins.single.password, larkspur.password);
    });
  }

  testWidgets('the vault’s own logins are never hidden, whatever a space grants', (tester) async {
    await openLogin(tester, larkspur, hold: holdFor(CollectionPermission.viewHidePasswords));

    expect(inSheet(find.byType(RevealPasswordButton)), findsOneWidget);
    expect(inSheet(find.byTooltip(t('logins.copy.password'))), findsOneWidget);
    expect(find.byKey(const ValueKey('login-password-space-hidden')), findsNothing);
  });
}
