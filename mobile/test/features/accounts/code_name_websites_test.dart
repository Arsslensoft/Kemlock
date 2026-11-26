import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/accounts/add_account_sheet.dart';
import 'package:kemlock/features/backup/add_backup_service_sheet.dart';
import 'package:kemlock/features/backup/backup_details_sheet.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

const _secret = 'JBSWY3DPEHPK3PXP';

/// The members of [json] that only a name or websites write.
List<String> _extras(Map<String, Object?> json) => [
  for (final key in json.keys)
    if (const {'name', 'websites', 'uris'}.contains(key)) key,
];

// An MFA code and a backup-code service can be named, and can say which websites they are used on.
void main() {
  Future<TestApp> open(WidgetTester tester) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    return app;
  }

  BuildContext root(WidgetTester tester) => tester.element(find.byType(Scaffold).first);

  Future<void> typeInto(WidgetTester tester, String labelId, String text) async {
    final finder = find.widgetWithText(TextField, t(labelId));
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
    await tester.enterText(finder.first, text);
    await tester.pump();
  }

  testWidgets('the manual form saves a name and websites on the code, and leaves them out when empty', (tester) async {
    final app = await open(tester);
    unawaited(showAddAccountSheet(root(tester)));
    await tester.pumpAndSettle();
    await tapOn(tester, find.text(t('addAccount.tab.manual')));

    await typeInto(tester, 'addAccount.field.issuer', 'GitHub');
    await typeInto(tester, 'addAccount.field.label', 'octocat');
    await typeInto(tester, 'accounts.field.name', 'Work GitHub');
    await typeInto(tester, 'addAccount.field.secret', _secret);
    await tapOn(tester, find.text(t('accounts.websites.add')));
    await typeInto(tester, 'accounts.websites.field', 'github.com');
    await tapOn(tester, find.widgetWithText(FilledButton, t('addAccount.add')));

    final account = app.container.read(vaultControllerProvider).accounts.single;
    expect((account.issuer, account.label, account.name), ('GitHub', 'octocat', 'Work GitHub'));
    expect(account.websites, ['github.com']);
    expect(displayName(account), 'Work GitHub');
    expect(accountSubLabel(account), 'GitHub · octocat');
  });

  testWidgets('a code with no name is listed by its issuer as before', (tester) async {
    final app = await open(tester);
    unawaited(showAddAccountSheet(root(tester)));
    await tester.pumpAndSettle();
    await tapOn(tester, find.text(t('addAccount.tab.manual')));

    await typeInto(tester, 'addAccount.field.issuer', 'GitHub');
    await typeInto(tester, 'addAccount.field.label', 'octocat');
    await typeInto(tester, 'addAccount.field.secret', _secret);
    await tapOn(tester, find.widgetWithText(FilledButton, t('addAccount.add')));

    final account = app.container.read(vaultControllerProvider).accounts.single;
    expect((account.name, account.websites), (null, null));
    expect(_extras(account.toJson()), isEmpty);
    expect((displayName(account), accountSubLabel(account)), ('GitHub', 'octocat'));
  });

  testWidgets('a backup-code service saves a name and websites, and its details can change them', (tester) async {
    final app = await open(tester);
    unawaited(showAddBackupServiceSheet(root(tester)));
    await tester.pumpAndSettle();

    await typeInto(tester, 'addBackup.field.serviceName', 'Google');
    await typeInto(tester, 'accounts.field.name', 'Personal Google');
    await tapOn(tester, find.text(t('accounts.websites.add')));
    await typeInto(tester, 'accounts.websites.field', 'google.com');
    await typeInto(tester, 'addBackup.field.codes', '1111 2222 3333');
    await tapOn(tester, find.widgetWithText(FilledButton, t('addBackup.save', {'count': 3})));

    BackupService service() => app.container.read(vaultControllerProvider).backupServices.single;
    // A record compares its list by identity, so each member is checked on its own
    expect((service().serviceName, service().name), ('Google', 'Personal Google'));
    expect(service().websites, ['google.com']);
    expect(backupTitle(service()), 'Personal Google');

    // Its Name and websites sheet changes both
    await tester.pump(const Duration(seconds: 10));
    final updates = <BackupService>[];
    unawaited(showBackupDetailsSheet(root(tester), service(), updates.add));
    await tester.pumpAndSettle();
    await typeInto(tester, 'accounts.field.name', '');
    await tapOn(tester, find.widgetWithText(FilledButton, t('accountSheet.save')));

    expect(updates.single.name, isNull);
    expect(updates.single.websites, ['google.com']);
    expect(backupTitle(updates.single), 'Google');
  });

  test('a code and a service with neither name nor websites are as they were', () {
    const account = OtpAccount(id: 'a', issuer: 'GitHub', label: 'octocat', secret: _secret, addedAt: 0);
    final service = BackupService(id: 's', serviceName: 'Google', codes: const [], addedAt: 0);
    expect(_extras(account.toJson()), isEmpty);
    expect(_extras(service.toJson()), isEmpty);
  });
}
