import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/logins/login_sheet.dart';
import 'package:kemlock/features/logins/password_health.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart' show realDirectory;

const _shared = 'kT9#vq2L-wPz8!mR4x';

const _mail = Login(
  id: 'l1',
  name: 'Larkspur Mail',
  username: 'ada@example.org',
  password: _shared,
  websites: ['larkspur.example'],
  addedAt: 0,
);
const _forum = Login(id: 'l2', name: 'Riverbank Forum', username: 'ada', password: _shared, websites: ['riverbank.example'], addedAt: 0);
const _blog = Login(id: 'l3', name: 'Blog', username: 'ada', password: 'summer2024', websites: ['blog.example'], addedAt: 0);
const _github = Login(id: 'l4', name: 'GitHub', username: 'octocat', password: 'Zq8!mW3#rT6-vB1?', websites: ['github.com'], addedAt: 0);

// openspec: add-passwords, task 8.3
void main() {
  Future<TestApp> openLogins(WidgetTester tester, List<Login> logins) async {
    final app = TestApp();
    await startApp(tester, app, overrides: [realDirectory]);
    await createVault(tester);
    final controller = app.container.read(vaultControllerProvider.notifier);
    for (final login in logins) {
      await controller.addLogin(login);
    }
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.filter.logins')));
    return app;
  }

  Finder row() => find.byType(PasswordHealthRow);
  Finder inHealth(Finder finder) => find.descendant(of: find.byType(PasswordHealthSheet), matching: finder);
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(LoginSheet), matching: finder);
  String summary(List<(String, int)> parts) => [
    for (final (id, count) in parts) t(id, {'count': count}),
  ].join(' · ');

  testWidgets('counts each kind of warning above the logins, and tags them in the list', (tester) async {
    await openLogins(tester, const [_mail, _forum, _blog, _github]);

    expect(
      find.descendant(
        of: row(),
        matching: find.text(summary([('health.count.reused', 2), ('health.count.weak', 1), ('health.count.noCode', 1)])),
      ),
      findsOneWidget,
    );
    expect(find.text(t('vault.login.tag.reused').toUpperCase()), findsNWidgets(2));
    expect(find.text(t('vault.login.tag.weak').toUpperCase()), findsOneWidget);
  });

  testWidgets('opens the logins grouped by warning, each opening its login', (tester) async {
    await openLogins(tester, const [_mail, _forum, _blog, _github]);

    await tapOn(tester, find.descendant(of: row(), matching: find.text(t('health.title'))));

    for (final id in ['health.section.reused', 'health.section.weak', 'health.section.noCode']) {
      expect(inHealth(find.text(t(id).toUpperCase())), findsOneWidget, reason: id);
    }
    expect(inHealth(find.text(t('health.section.breached').toUpperCase())), findsNothing);
    // Breached passwords wait for the switch, which is off
    expect(inHealth(find.text(t('health.breach.off'))), findsOneWidget);

    await tapOn(tester, inHealth(find.text('Blog')));
    expect(find.byType(LoginSheet), findsOneWidget);
  });

  testWidgets('a login’s sheet names the other login with its password, and says when it is weak', (tester) async {
    await openLogins(tester, const [_mail, _forum, _blog]);

    await tapOn(tester, find.text('Larkspur Mail'));
    expect(inSheet(find.text(t('health.login.reused', {'names': 'Riverbank Forum'}))), findsOneWidget);
    Navigator.of(tester.element(find.byType(LoginSheet))).pop();
    await tester.pumpAndSettle();

    await tapOn(tester, find.text('Blog'));
    expect(inSheet(find.text(t('health.login.weak', {'strength': t('setup.strength.fair')}))), findsOneWidget);
  });

  testWidgets('stops warning for one login’s code when asked, and keeps the choice in the vault', (tester) async {
    final app = await openLogins(tester, const [_github]);

    await tapOn(tester, find.text('GitHub'));
    expect(inSheet(find.text(t('health.login.noCode'))), findsOneWidget);
    await tapOn(tester, inSheet(find.text(t('health.login.noWarn'))));

    expect(inSheet(find.text(t('health.login.noCode'))), findsNothing);
    expect(app.container.read(vaultControllerProvider).logins.single.codeWarning, isFalse);
    Navigator.of(tester.element(find.byType(LoginSheet))).pop();
    await tester.pumpAndSettle();
    expect(row(), findsOneWidget);
    expect(
      find.descendant(of: row(), matching: find.byType(GroupRow)),
      findsNothing,
      reason: 'nothing left to say',
    );
  });

  testWidgets('shows no row when no login has a warning', (tester) async {
    await openLogins(tester, const [_github]);
    await tapOn(tester, find.text('GitHub'));
    await tapOn(tester, inSheet(find.text(t('health.login.noWarn'))));
    Navigator.of(tester.element(find.byType(LoginSheet))).pop();
    await tester.pumpAndSettle();

    expect(find.text(t('health.title')), findsNothing);
  });
}
