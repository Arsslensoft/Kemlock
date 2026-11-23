import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/generator/generator_sheet.dart';
import 'package:kemlock/features/lock/gate_widgets.dart';
import 'package:kemlock/features/logins/login_edit_sheet.dart';
import 'package:kemlock/features/logins/login_sheet.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../spaces/chain_kit.dart';

// The edit sheet of a login whose password a space hides from the member (docs/plans/add-server-spaces.md, task 5.5): it
// shows no password, no Show and no Generate, puts nothing in a password field, and saves the password as it was, so
// tapping Edit is no way to read it. The login sheet's own part is in `hidden_passwords_test.dart`.
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
    passwordChangedAt: 1700000000000,
    addedAt: 0,
  );

  /// What a run of the space reports for Bob, who holds [permission] on "Everyone", where the login is.
  SpaceHold holdFor(CollectionPermission permission) {
    final chain = ChainBuilder(space)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: permission});
    return SpaceHold(chain: chain.state, account: bob.id, collections: {'l1': everyone});
  }

  Finder inEdit(Finder finder) => find.descendant(of: find.byType(LoginEditSheet), matching: finder);

  Future<TestApp> openEdit(WidgetTester tester, CollectionPermission permission) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addLogin(larkspur.copyWith(spaceId: space));
    app.container.read(hiddenPasswordsProvider.notifier).remember(space, holdFor(permission));
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.filter.logins')));
    await tapOn(tester, find.text(larkspur.name));
    await tapOn(tester, find.descendant(of: find.byType(LoginSheet), matching: find.text(t('logins.edit'))));
    return app;
  }

  for (final permission in [CollectionPermission.viewHidePasswords, CollectionPermission.editHidePasswords]) {
    testWidgets('the edit sheet of a login granted ${permission.wire} shows no password and saves it unchanged', (tester) async {
      final app = await openEdit(tester, permission);

      expect(inEdit(field(t('logins.field.password'))), findsNothing);
      expect(inEdit(find.byType(RevealPasswordButton)), findsNothing);
      expect(inEdit(find.text(t('generator.open'))), findsNothing);
      expect(find.byType(GeneratorSheet), findsNothing);
      expect(find.byKey(const ValueKey('login-edit-password-space-hidden')), findsOneWidget);
      // The login sheet stays open beneath the edit sheet and carries the same notice, so count the edit sheet's own
      expect(inEdit(find.text(t('logins.password.spaceHidden'))), findsOneWidget);
      expect(find.text(larkspur.password!), findsNothing, reason: 'the password is on no widget of the sheet');
      for (final input in tester.widgetList<EditableText>(find.byType(EditableText))) {
        expect(input.controller.text, isNot(contains(larkspur.password!)));
      }

      // As stored: adding the login stamped its password's change date with the vault's clock
      final before = app.container.read(vaultControllerProvider).logins.single;
      await tester.enterText(inEdit(field(t('logins.field.name'))), 'Larkspur Mail (work)');
      await tester.pump(const Duration(seconds: 10));
      await tapOn(tester, inEdit(find.widgetWithText(FilledButton, t('logins.save'))));

      final saved = app.container.read(vaultControllerProvider).logins.single;
      expect(saved.name, 'Larkspur Mail (work)');
      expect(saved.password, larkspur.password);
      expect(saved.passwordChangedAt, before.passwordChangedAt);
      expect(saved.previousPasswords, isNull);
    });
  }

  testWidgets('the edit sheet of a login granted edit still holds its password field', (tester) async {
    await openEdit(tester, CollectionPermission.edit);

    expect(inEdit(field(t('logins.field.password'))), findsOneWidget);
    expect(inEdit(find.byType(RevealPasswordButton)), findsOneWidget);
    expect(find.byKey(const ValueKey('login-edit-password-space-hidden')), findsNothing);
  });
}
