// The Backup tab (routes/backup.tsx), in the whole app on a vault in memory.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/add_backup_service_sheet.dart';

import '../../helpers/test_app.dart';
import 'backup_test_kit.dart';

final github = service('gh', 'GitHub', ['aaaaa-11111', 'bbbbb-22222', 'ccccc-33333', 'ddddd-44444'], used: 1);
final google = service('go', 'Google', ['1234 5678', '2345 6789', '3456 7890'], used: 1);

/// The card of the service [name].
Finder cardOf(String name) => find.bySemanticsLabel(name).first;

void main() {
  testWidgets('starts empty, with a way to add the first service', (tester) async {
    await openBackupTab(tester);

    expect(find.text(t('app.tab.backupCodes')), findsOneWidget);
    expect(find.text(t('backup.subtitle')), findsOneWidget);
    expect(find.text(t('app.empty.backup.title')), findsOneWidget);
    await tester.tap(find.text(t('app.empty.backup.action')));
    await tester.pumpAndSettle();

    expect(find.byType(AddBackupServiceSheet), findsOneWidget);
  });

  testWidgets('counts the codes left, the services and those running low', (tester) async {
    await openBackupTab(tester, services: [github, google]);

    expect(find.text('5'), findsOneWidget);
    expect(find.text(t('backup.stat.left', {'count': 5})), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text(t('app.counter.services', {'count': 2})), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text(t('backup.stat.low')), findsOneWidget);
    expect(find.text(t('app.empty.backup.title')), findsNothing);
  });

  testWidgets('opens the first service, and one service at a time', (tester) async {
    await openBackupTab(tester, services: [github, google]);
    expect(find.text('bbbbb-22222'), findsOneWidget);
    expect(find.text('2345 6789'), findsNothing);

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(find.text('bbbbb-22222'), findsNothing);
    expect(find.text('2345 6789'), findsOneWidget);

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(find.text('2345 6789'), findsNothing);
    expect(find.text('bbbbb-22222'), findsNothing);
  });

  testWidgets('copies the next code and crosses it off, with Undo', (tester) async {
    final clipboard = watchClipboard();
    final app = await openBackupTab(tester, services: [github]);

    await tester.tap(find.text(t('backupCard.useNext')));
    await tester.pumpAndSettle();

    expect(clipboard, ['bbbbb-22222']);
    expect(app.state.backupServices.single.codes[1].used, isTrue);
    expect(app.state.backupServices.single.codes[1].usedAt, testNow.millisecondsSinceEpoch);
    expect(find.text(t('backup.usedToast', {'code': 'bbbbb-22222'})), findsOneWidget);

    await tester.tap(find.text(t('backup.undo')));
    await tester.pumpAndSettle();
    expect(app.state.backupServices.single.codes[1].used, isFalse);

    // The code doesn't stay on the clipboard, as Settings has it by default.
    await tester.pump(const Duration(seconds: 30));
    expect(clipboard, ['bbbbb-22222', '']);
  });

  testWidgets('crosses a code off and keeps it', (tester) async {
    final app = await openBackupTab(tester, services: [github]);

    await tester.tap(find.text('ccccc-33333'));
    await tester.pumpAndSettle();

    expect(app.state.backupServices.single.codes[2].used, isTrue);
    expect(find.text(t('backupCard.left', {'unused': 2, 'total': 4})), findsOneWidget);
    expect(find.text(t('backupCard.low')), findsOneWidget);
  });

  testWidgets('deletes a service once asked, and says so', (tester) async {
    final app = await openBackupTab(tester, services: [github]);

    await tester.tap(find.bySemanticsLabel(t('backupCard.tooltip.delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('backupCard.delete.confirm')));
    await tester.pumpAndSettle();

    expect(app.state.backupServices, isEmpty);
    expect(find.text(t('app.snack.backupDeleted')), findsOneWidget);
    expect(find.text(t('app.empty.backup.title')), findsOneWidget);
  });

  group('coverage', () {
    testWidgets('asks for the codes of a service the check found without', (tester) async {
      await openBackupTab(tester, services: [github], accounts: [account('1', 'GitHub'), account('2', 'Steam')]);

      expect(find.text(t('coverage.summary', {'covered': 1, 'total': 2})), findsOneWidget);
      await tester.tap(find.text(t('coverage.add')));
      await tester.pumpAndSettle();

      expect(find.byType(AddBackupServiceSheet), findsOneWidget);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, t('addBackup.field.serviceName'))).controller!.text, 'Steam');
    });

    testWidgets('remembers a service that gives no codes', (tester) async {
      final app = await openBackupTab(tester, services: [github], accounts: [account('1', 'GitHub'), account('2', 'Steam')]);

      await tester.tap(find.bySemanticsLabel(t('coverage.none.label', {'name': 'Steam'})));
      await tester.pumpAndSettle();

      expect(app.state.accounts.firstWhere((a) => a.id == '2').noBackupCodes, isTrue);
      expect(find.text(t('coverage.summary', {'covered': 1, 'total': 1})), findsOneWidget);
    });
  });
}
