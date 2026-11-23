// The four PGP actions on the Vault tab: under the Keys filter and under
// an empty vault, and nowhere else.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/pgp/decrypt_sheet.dart';
import 'package:kemlock/features/pgp/encrypt_sheet.dart';
import 'package:kemlock/features/pgp/pgp_actions.dart';
import 'package:kemlock/features/pgp/sign_sheet.dart';
import 'package:kemlock/features/pgp/verify_sheet.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/test_app.dart';
import '../keys/expiry_kit.dart';
import '../pgp/pgp_kit.dart';

const _actions = ['encrypt', 'decrypt', 'sign', 'verify'];

List<String> _shown(WidgetTester tester) => [
  for (final button in tester.widgetList<OutlinedButton>(
    find.descendant(of: find.byType(PgpActionsRow), matching: find.byType(OutlinedButton)),
  ))
    ((button.key! as ValueKey<String>).value),
];

void main() {
  testWidgets('an empty vault shows the four actions under its empty state', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start();
    expect(find.text(t('vault.empty.title')), findsOneWidget);
    expect(_shown(tester), [for (final action in _actions) 'pgp.action.$action']);
    // In that order, left to right, under the empty state's own button
    final xs = [for (final action in _actions) tester.getCenter(find.text(t('pgp.action.$action'))).dx];
    expect(xs, [...xs]..sort());
    expect(tester.getTopLeft(find.byType(PgpActionsRow)).dy, greaterThan(tester.getBottomLeft(find.text(t('vault.empty.action'))).dy));
  });

  testWidgets('under Keys, with a PGP key and with an SSH key alone; not under the other filters', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: ['ed']);
    // All is the filter the tab opens on
    expect(find.byType(PgpActionsRow), findsNothing);

    await tapOn(tester, find.text(t('vault.filter.keys')));
    expect(_shown(tester), hasLength(4));
    // Between the filter and the first card
    final row = tester.getRect(find.byType(PgpActionsRow));
    expect(row.top, greaterThan(tester.getBottomLeft(find.text(t('vault.filter.keys'))).dy));
    expect(row.bottom, lessThan(tester.getTopLeft(find.text('Fixture Ed25519')).dy));

    for (final filter in ['all', 'notes', 'passkeys']) {
      await tapOn(tester, find.text(t('vault.filter.$filter')));
      expect(find.byType(PgpActionsRow), findsNothing, reason: filter);
    }
  });

  testWidgets('with no PGP key in the vault the actions are still there', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start();
    await tester.runAsync(() => pgp.app.container.read(vaultControllerProvider.notifier).addKey(sshKey()));
    await tester.pumpAndSettle();
    await tapOn(tester, find.text(t('vault.filter.keys')));
    expect(_shown(tester), hasLength(4));
    // Sign says what it needs
    await pgp.tap(find.text(t('pgp.action.sign')));
    expect(find.text(t('pgp.sign.needKey')), findsOneWidget);
    expect(find.text(t('pgp.sign.addKey')), findsOneWidget);
  });

  testWidgets('each button opens its sheet and has a label', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: ['ed']);
    await tapOn(tester, find.text(t('vault.filter.keys')));
    final handle = tester.ensureSemantics();
    for (final (action, sheet) in [('encrypt', EncryptSheet), ('decrypt', DecryptSheet), ('sign', SignSheet), ('verify', VerifySheet)]) {
      expect(find.bySemanticsLabel(t('pgp.action.$action')), findsWidgets, reason: action);
      await pgp.tap(find.text(t('pgp.action.$action')));
      expect(find.byType(sheet), findsOneWidget, reason: action);
      await pgp.closeSheet();
      expect(find.byType(sheet), findsNothing);
    }
    expect(find.bySemanticsLabel(t('pgp.actions.label')), findsOneWidget);
    handle.dispose();
  });
}
