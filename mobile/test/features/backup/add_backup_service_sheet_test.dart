import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/add_backup_service_sheet.dart';
import 'package:kemlock/features/backup/backup_page.dart';

import '../../fakes/fake_code_readers.dart';
import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import 'backup_test_kit.dart';

/// The field labelled with the message [id].
Finder field(String id) => find.widgetWithText(TextField, t(id));

/// The sheet's Save button, whatever count it shows.
FilledButton saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.descendant(of: find.byType(AddBackupServiceSheet), matching: find.byType(FilledButton)));

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel(t('nav.addBackup')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('saves a service with the codes pasted, and says so', (tester) async {
    final app = await openBackupTab(tester);
    await openSheet(tester);

    await tester.enterText(field('addBackup.field.serviceName'), '  GitHub ');
    await tester.enterText(field('addBackup.field.codes'), 'aaaaa-11111\nbbbbb-22222, ccccc-33333');
    await tester.pump();
    expect(find.text(t('addBackup.detected', {'count': 3})), findsOneWidget);
    await tester.tap(find.text(t('addBackup.save', {'count': 3})));
    await tester.pumpAndSettle();

    expect(find.byType(AddBackupServiceSheet), findsNothing);
    final saved = app.state.backupServices.single;
    expect(saved.serviceName, 'GitHub');
    expect(
      [for (final code in saved.codes) (code.code, code.used)],
      [('aaaaa-11111', false), ('bbbbb-22222', false), ('ccccc-33333', false)],
    );
    expect(find.text(t('app.snack.backupSaved', {'name': 'GitHub'})), findsOneWidget);
  });

  testWidgets('saves only with a service and at least one code', (tester) async {
    await openBackupTab(tester);
    await openSheet(tester);
    expect(saveButton(tester).onPressed, isNull);
    expect(find.text(t('addBackup.save', {'count': 0})), findsOneWidget);

    await tester.enterText(field('addBackup.field.serviceName'), '   ');
    await tester.enterText(field('addBackup.field.codes'), '1234 5678');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNull);

    await tester.enterText(field('addBackup.field.serviceName'), 'Google');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNotNull);
    expect(find.text(t('addBackup.save', {'count': 1})), findsOneWidget);
  });

  testWidgets('shows each code it found, and warns when it finds none', (tester) async {
    await openBackupTab(tester);
    await openSheet(tester);

    await tester.enterText(field('addBackup.field.codes'), '1234 5678  8765 4321');
    await tester.pump();
    expect(find.text('1234 5678'), findsOneWidget);
    expect(find.text('8765 4321'), findsOneWidget);
    expect(find.text(t('addBackup.noDetected')), findsNothing);

    await tester.enterText(field('addBackup.field.codes'), ' , ,');
    await tester.pump();
    expect(find.text(t('addBackup.detected', {'count': 0})), findsNothing);
    expect(find.text(t('addBackup.noDetected')), findsOneWidget);
  });

  testWidgets('starts with the service it was opened for', (tester) async {
    await openBackupTab(tester);

    showAddBackupServiceSheet(tester.element(find.byType(BackupPage)), initialName: 'Steam').ignore();
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(field('addBackup.field.serviceName')).controller!.text, 'Steam');
  });

  testWidgets('adds the codes read from a file, with a reminder to check them', (tester) async {
    final files = FakeFiles()..nextPick = FakeFiles.image('codes.png');
    final readers = FakeCodeReaders();
    readers.images.text = 'Google backup codes\n1234 5678  8765 4321';
    await openBackupTab(tester, overrides: [files.asOverride, ...readers.overrides]);
    await openSheet(tester);
    await tester.enterText(field('addBackup.field.codes'), 'zzzzz-99999\n');
    await tester.pump();

    await tester.tap(find.text(t('codeImport.button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('codeImport.from.photos')));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(field('addBackup.field.codes')).controller!.text, 'zzzzz-99999\n1234 5678\n8765 4321');
    expect(find.text(t('codeImport.check')), findsOneWidget);
    expect(find.text(t('addBackup.detected', {'count': 3})), findsOneWidget);
  });

  testWidgets('closes without saving on Cancel', (tester) async {
    final app = await openBackupTab(tester);
    await openSheet(tester);
    await tester.enterText(field('addBackup.field.serviceName'), 'GitHub');
    await tester.enterText(field('addBackup.field.codes'), 'aaaaa-11111');

    await tester.tap(find.text(t('addBackup.cancel')));
    await tester.pumpAndSettle();

    expect(find.byType(AddBackupServiceSheet), findsNothing);
    expect(app.state.backupServices, isEmpty);
  });
}
