// Which accounts have backup codes saved (CoverageCard.test.tsx).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/coverage_card.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../helpers/test_app.dart';
import 'backup_test_kit.dart';

const github = BackupService(
  id: 'gh',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'aaaaa-11111')],
  addedAt: 1,
);
final accounts = [account('1', 'GitHub'), account('2', 'Steam'), account('3', 'Dropbox')];

/// What the card asked the page to do.
class Calls {
  final List<String> addCodes = [];
  final List<OtpAccount> noCodes = [];
}

Future<Calls> setup(WidgetTester tester, {List<OtpAccount>? list, List<BackupService> services = const [github]}) async {
  final calls = Calls();
  await pumpOnPage(
    tester,
    SingleChildScrollView(
      child: CoverageCard(
        accounts: list ?? accounts,
        backupServices: services,
        onAddCodes: calls.addCodes.add,
        onNoCodes: calls.noCodes.add,
      ),
    ),
    center: false,
  );
  await tester.pumpAndSettle();
  return calls;
}

/// The row of the missing service [name].
Finder rowOf(String name) => find.ancestor(of: find.text(name), matching: find.byType(Row)).first;

void main() {
  testWidgets('counts the accounts with backup codes and lists the others A–Z', (tester) async {
    await setup(tester);

    expect(find.text(t('coverage.summary', {'covered': 1, 'total': 3})), findsOneWidget);
    expect(find.text(t('coverage.add')), findsNWidgets(2));
    expect(find.descendant(of: rowOf('Dropbox'), matching: find.text(t('coverage.add'))), findsOneWidget);
    expect(find.descendant(of: rowOf('Steam'), matching: find.text(t('coverage.add'))), findsOneWidget);
    expect(tester.getTopLeft(find.text('Dropbox')).dy, lessThan(tester.getTopLeft(find.text('Steam')).dy));
    expect(find.text('GitHub'), findsNothing);
  });

  testWidgets('adds codes for, or rules out, a missing service', (tester) async {
    final calls = await setup(tester);

    await tester.tap(find.text(t('coverage.add')).at(1));
    expect(calls.addCodes, ['Steam']);

    await tester.tap(find.bySemanticsLabel(t('coverage.none.label', {'name': 'Dropbox'})));
    expect(calls.noCodes, [accounts[2]]);
  });

  testWidgets('shows four missing services, then all of them when asked', (tester) async {
    final names = ['Amazon', 'Box', 'Discord', 'Epic', 'Figma', 'Gitlab'];
    await setup(tester, list: [for (final (i, name) in names.indexed) account('$i', name)], services: const []);

    expect(find.text(t('coverage.add')), findsNWidgets(coveragePreview));
    expect(find.text('Figma'), findsNothing);
    await tester.tap(find.text(t('coverage.showAll', {'count': 6})));
    await tester.pumpAndSettle();
    expect(find.text(t('coverage.add')), findsNWidgets(6));

    await tester.tap(find.text(t('coverage.showLess')));
    await tester.pumpAndSettle();
    expect(find.text(t('coverage.add')), findsNWidgets(coveragePreview));
  });

  testWidgets('leaves out accounts marked as giving no codes', (tester) async {
    await setup(tester, list: [...accounts.take(2), account('3', 'Dropbox', noBackupCodes: true)]);

    expect(find.text(t('coverage.summary', {'covered': 1, 'total': 2})), findsOneWidget);
    expect(find.text('Dropbox'), findsNothing);
  });

  testWidgets('names an account without a service Unknown', (tester) async {
    await setup(tester, list: [account('1', '')], services: const []);

    expect(find.text(t('accountCard.unknown')), findsOneWidget);
  });

  testWidgets('takes no room without accounts, or when none is checked', (tester) async {
    await setup(tester, list: const []);
    expect(find.text(t('coverage.title')), findsNothing);

    await setup(tester, list: [account('1', 'Steam', noBackupCodes: true)]);
    expect(find.text(t('coverage.title')), findsNothing);
  });
}
