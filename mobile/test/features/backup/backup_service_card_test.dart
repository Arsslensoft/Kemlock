// A service's backup codes on the Backup tab (BackupServiceCard.test.tsx,
// and the card's cases in CoverageCard.test.tsx).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/backup_service_card.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/backup_service.dart';

import '../../helpers/test_app.dart';
import '../sync/sync_screen_kit.dart';
import 'backup_test_kit.dart';

const github = BackupService(
  id: 'svc',
  serviceName: 'GitHub',
  codes: [
    BackupCode(code: 'aaaaa-11111', used: true),
    BackupCode(code: 'bbbbb-22222'),
    BackupCode(code: 'ccccc-33333'),
    BackupCode(code: 'ddddd-44444'),
  ],
  addedAt: 0,
);

/// What the card asked the page to do.
class Calls {
  int toggles = 0;
  final List<BackupService> updates = [];
  final List<String> deletes = [];
  final List<BackupService> usedNext = [];
}

Future<Calls> setup(
  WidgetTester tester, {
  BackupService service = github,
  bool open = true,
  SyncSettings sync = noSync,
  List<Override> overrides = const [],
}) async {
  final calls = Calls();
  await pumpOnPage(
    tester,
    SingleChildScrollView(
      child: BackupServiceCard(
        service: service,
        open: open,
        onToggle: () => calls.toggles++,
        onUpdate: calls.updates.add,
        onDelete: calls.deletes.add,
        onUseNext: calls.usedNext.add,
      ),
    ),
    center: false,
    overrides: [
      fakeSync(SyncSnapshot(settings: sync)),
      ...overrides,
    ],
  );
  await tester.pumpAndSettle();
  return calls;
}

Space space(String id, String name) => Space(
  id: id,
  name: name,
  target: SyncTarget(
    dav: const DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'app-pw'),
    file: spaceFile(id),
    key: 'a2V5',
  ),
  joinedAt: 1,
);

void main() {
  testWidgets('summarises how many codes are left', (tester) async {
    await setup(tester);

    expect(find.text(t('backupCard.left', {'unused': 3, 'total': 4})), findsOneWidget);
    expect(find.text(t('backupCard.low')), findsNothing);
  });

  testWidgets('warns when two or fewer codes remain', (tester) async {
    await setup(
      tester,
      service: github.copyWith(codes: [for (final (i, code) in github.codes.indexed) code.copyWith(used: i < 3)]),
    );

    expect(find.text(t('backupCard.low')), findsOneWidget);
    expect(find.text(t('backupCard.lowHint', {'name': 'GitHub'})), findsOneWidget);
  });

  testWidgets('crosses a code off when tapped', (tester) async {
    final calls = await setup(tester);

    expect(tester.getSemantics(find.text('bbbbb-22222')), isSemantics(isButton: true, hasToggledState: true, isToggled: false));
    await tester.tap(find.text('bbbbb-22222'));

    expect(calls.updates.single.codes, contains(BackupCode(code: 'bbbbb-22222', used: true, usedAt: testNow.millisecondsSinceEpoch)));
  });

  testWidgets('marks a used code unused again, forgetting when', (tester) async {
    final usedAt = DateTime(2026, 3, 14).millisecondsSinceEpoch;
    final calls = await setup(
      tester,
      service: github.copyWith(
        codes: [BackupCode(code: 'aaaaa-11111', used: true, usedAt: usedAt)],
      ),
    );

    expect(tester.getSemantics(find.text('aaaaa-11111')), isSemantics(isToggled: true));
    await tester.tap(find.text('aaaaa-11111'));

    expect(calls.updates.single.codes, [const BackupCode(code: 'aaaaa-11111')]);
  });

  testWidgets('hands off "use next code" to the page', (tester) async {
    final calls = await setup(tester);

    await tester.tap(find.text(t('backupCard.useNext')));

    expect(calls.usedNext, [github]);
  });

  testWidgets('has no next code to use once all are used', (tester) async {
    final calls = await setup(tester, service: github.copyWith(codes: [for (final code in github.codes) code.copyWith(used: true)]));

    expect(find.text(t('backupCard.footer.allUsed')), findsOneWidget);
    await tester.tap(find.text(t('backupCard.useNext')));
    expect(calls.usedNext, isEmpty);
  });

  testWidgets('says when a service has no codes yet', (tester) async {
    await setup(tester, service: github.copyWith(codes: []));

    expect(find.text(t('backupCard.footer.none')), findsOneWidget);
    expect(find.text(t('backupCard.empty')), findsOneWidget);
  });

  testWidgets('adds pasted codes, skipping duplicates', (tester) async {
    final calls = await setup(tester);

    await tester.tap(find.byTooltip(t('backupCard.addButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'eeeee-55555 bbbbb-22222');
    await tester.pump();
    expect(find.text(t('backupCard.newCodesSummary', {'newCount': 1, 'dupCount': 1})), findsOneWidget);
    await tester.tap(find.text(t('backupCard.addCodes', {'count': 1})));
    await tester.pumpAndSettle();

    expect(calls.updates.single.codes, [...github.codes, const BackupCode(code: 'eeeee-55555')]);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('adds nothing when every code pasted is there already', (tester) async {
    final calls = await setup(tester);
    await tester.tap(find.byTooltip(t('backupCard.addButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bbbbb-22222');
    await tester.pump();
    final add = find.widgetWithText(FilledButton, t('backupCard.addCodes', {'count': 0}));
    expect(tester.widget<FilledButton>(add).onPressed, isNull);

    await tester.tap(find.text(t('backupCard.cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(calls.updates, isEmpty);
  });

  testWidgets('asks before deleting the service', (tester) async {
    final calls = await setup(tester);

    await tester.tap(find.bySemanticsLabel(t('backupCard.tooltip.delete')));
    await tester.pumpAndSettle();
    expect(find.text(t('backupCard.delete.title')), findsOneWidget);
    expect(find.textContaining('Remove GitHub and all 4 backup codes?', findRichText: true), findsOneWidget);
    await tester.tap(find.text(t('backupCard.delete.confirm')));
    await tester.pumpAndSettle();

    expect(calls.deletes, ['svc']);
  });

  testWidgets('keeps the service when deleting is cancelled', (tester) async {
    final calls = await setup(tester);

    await tester.tap(find.bySemanticsLabel(t('backupCard.tooltip.delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('backupCard.delete.cancel')));
    await tester.pumpAndSettle();

    expect(calls.deletes, isEmpty);
  });

  testWidgets('toggles open from its header', (tester) async {
    final calls = await setup(tester, open: false);

    expect(tester.getSemantics(find.text('GitHub')), isSemantics(isButton: true, hasExpandedState: true, isExpanded: false));
    expect(find.text('bbbbb-22222'), findsNothing);
    await tester.tap(find.text('GitHub'));

    expect(calls.toggles, 1);
  });

  testWidgets('shows when a used code was used', (tester) async {
    final usedAt = DateTime(2026, 3, 14).millisecondsSinceEpoch;
    await setup(
      tester,
      service: github.copyWith(
        codes: [BackupCode(code: 'aaaaa-11111', used: true, usedAt: usedAt)],
      ),
    );

    expect(find.byTooltip(t('backupCard.tooltip.usedOn', {'date': 'Mar 14, 2026'})), findsOneWidget);
    expect(find.text('Mar 14'), findsOneWidget);
  });

  testWidgets('keeps a note with the service', (tester) async {
    final calls = await setup(tester);

    await tester.tap(find.byTooltip(t('backupCard.noteButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, t('accountSheet.note')), 'Printed copy in the safe');
    await tester.tap(find.text(t('accountSheet.save')));
    await tester.pumpAndSettle();

    expect(calls.updates, [github.copyWith(note: 'Printed copy in the safe')]);
  });

  testWidgets('shows the saved note', (tester) async {
    await setup(tester, service: github.copyWith(note: 'Printed copy in the safe'));

    expect(find.text('Printed copy in the safe'), findsOneWidget);
  });

  group('directory links and spaces', () {
    testWidgets('links to where the service makes new codes and recovers access', (tester) async {
      final links = FakeLinks();
      await setup(tester, overrides: [realDirectory, links.asOverride]);

      final docs = find.text(t('backupCard.directory.docs'));
      expect(tester.getSemantics(docs), isSemantics(isLink: true));
      await tester.tap(docs);
      await tester.tap(find.text(t('backupCard.directory.recovery')));

      expect(links.opened, hasLength(2));
      expect(links.opened.first.toString(), startsWith('https://docs.github.com/'));
    });

    testWidgets('moves the service into a shared space', (tester) async {
      final calls = await setup(tester, sync: SyncSettings(spaces: [space('fam', 'Family')]));

      await tester.tap(find.text(t('spaces.picker.mine')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      expect(calls.updates.single.spaceId, 'fam');
    });

    testWidgets('has no space picker while there is no space', (tester) async {
      await setup(tester);

      expect(find.text(t('spaces.picker.label')), findsNothing);
    });
  });

  testWidgets('lets a service in a space be taken home', (tester) async {
    final calls = await setup(tester, service: github.copyWith(spaceId: 'gone'));

    expect(find.text(t('spaces.picker.left')), findsOneWidget);
    await tester.tap(find.text(t('spaces.picker.left')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('spaces.picker.mine')).last);
    await tester.pumpAndSettle();

    expect(calls.updates.single.spaceId, isNull);
    expect(calls.updates.single.toJson().containsKey('spaceId'), isFalse);
  });
}
