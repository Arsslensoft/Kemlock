import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

// The regression test of the fail-closed fix (docs/plans/add-server-spaces.md, task 5.5): the reports of
// `hiddenPasswordsProvider` start empty, so a login of a server space showed its password between unlock and the space's
// first sync, and with no network at all. Until its space has reported a chain that shows this member's real grant, the
// login counts as hidden, in the login sheet and the edit sheet.
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

  Finder inLogin(Finder finder) => find.descendant(of: find.byType(LoginSheet), matching: finder);
  Finder inEdit(Finder finder) => find.descendant(of: find.byType(LoginEditSheet), matching: finder);

  /// The vault with the server-space login in it and its sheet open, with a chain reported only when [hold] is given.
  Future<TestApp> openLogin(WidgetTester tester, {SpaceHold? hold}) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addLogin(larkspur.copyWith(spaceId: space));
    if (hold != null) {
      app.container.read(hiddenPasswordsProvider.notifier).remember(space, hold);
    }
    // The toast of the login just saved would sit over what comes next: let it go
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.filter.logins')));
    await tapOn(tester, find.text(larkspur.name));
    return app;
  }

  testWidgets('a server space login before its chain reports has no reveal and no copy in the login sheet', (tester) async {
    final app = await openLogin(tester);

    expect(inLogin(find.byType(RevealPasswordButton)), findsNothing);
    expect(inLogin(find.byTooltip(t('logins.copy.password'))), findsNothing);
    expect(find.byKey(const ValueKey('login-password-space-hidden')), findsOneWidget);
    expect(inLogin(find.text(larkspur.password!)), findsNothing);
    // The login still holds its password, which AutoFill reads
    expect(app.container.read(vaultControllerProvider).logins.single.password, larkspur.password);
  });

  testWidgets('the login sheet shows the password once a report brings a grant that does not hide it', (tester) async {
    final app = await openLogin(tester);
    expect(inLogin(find.byType(RevealPasswordButton)), findsNothing);

    app.container.read(hiddenPasswordsProvider.notifier).remember(space, holdFor(CollectionPermission.edit));
    await tester.pump(const Duration(seconds: 10));

    expect(inLogin(find.byType(RevealPasswordButton)), findsOneWidget);
    expect(inLogin(find.byTooltip(t('logins.copy.password'))), findsOneWidget);
    expect(find.byKey(const ValueKey('login-password-space-hidden')), findsNothing);
  });

  testWidgets('a report with a grant that hides passwords keeps the login sheet hidden', (tester) async {
    await openLogin(tester, hold: holdFor(CollectionPermission.viewHidePasswords));

    expect(inLogin(find.byType(RevealPasswordButton)), findsNothing);
    expect(inLogin(find.byTooltip(t('logins.copy.password'))), findsNothing);
  });

  testWidgets('the edit sheet of a server space login before its chain reports shows no password and saves it unchanged', (tester) async {
    final app = await openLogin(tester);
    await tapOn(tester, inLogin(find.text(t('logins.edit'))));

    expect(inEdit(field(t('logins.field.password'))), findsNothing);
    expect(inEdit(find.byType(RevealPasswordButton)), findsNothing);
    expect(find.byKey(const ValueKey('login-edit-password-space-hidden')), findsOneWidget);
    for (final input in tester.widgetList<EditableText>(find.byType(EditableText))) {
      expect(input.controller.text, isNot(contains(larkspur.password!)));
    }

    // A grant that shows the password arrives while the sheet is open: it stays hidden, and the save keeps the password
    app.container.read(hiddenPasswordsProvider.notifier).remember(space, holdFor(CollectionPermission.edit));
    await tester.pump(const Duration(seconds: 10));
    expect(inEdit(field(t('logins.field.password'))), findsNothing);

    await tester.enterText(inEdit(field(t('logins.field.name'))), 'Larkspur Mail (work)');
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, inEdit(find.widgetWithText(FilledButton, t('logins.save'))));

    final saved = app.container.read(vaultControllerProvider).logins.single;
    expect(saved.name, 'Larkspur Mail (work)');
    expect(saved.password, larkspur.password);
  });

  testWidgets('the edit sheet shows the password field after a report without hide-passwords', (tester) async {
    await openLogin(tester, hold: holdFor(CollectionPermission.edit));
    await tapOn(tester, inLogin(find.text(t('logins.edit'))));

    expect(inEdit(field(t('logins.field.password'))), findsOneWidget);
    expect(inEdit(find.byType(RevealPasswordButton)), findsOneWidget);
    expect(find.byKey(const ValueKey('login-edit-password-space-hidden')), findsNothing);
  });
}
