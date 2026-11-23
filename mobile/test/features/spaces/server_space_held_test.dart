import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/server_space_sheet.dart';
import 'package:kemlock/features/spaces/server_spaces.dart';
import 'package:kemlock/i18n/messages.dart';

import '../../helpers/test_app.dart';
import 'chain_kit.dart';

// The held list on a space's sheet: what the server holds back after a key replacement, with Keep for an item this phone
// has an accepted copy of, and Delete for any. The sheet takes its actions as functions, so these tests give it plain ones.
void main() {
  final space = uuid(0x5a);
  final alice = Person(1);
  final chain = ChainBuilder(space)..create(alice, collection: uuid(0xe0));

  HeldSpaceItem item(String id, {String? name, bool canKeep = true}) =>
      (id: id, kind: 'login', revision: 2, keyVersion: 1, collection: uuid(0xe0), name: name, canKeep: canKeep);

  for (final locale in AppLocale.values) {
    group('the held list in ${locale.name}', () {
      final messages = testCatalog.of(locale);
      late List<HeldSpaceItem> held;
      final kept = <String>[];
      final deleted = <String>[];
      HeldItemProblem? refuse;

      setUp(() {
        held = [item(uuid(0x11), name: 'Site l1'), item(uuid(0x12), canKeep: false)];
        kept.clear();
        deleted.clear();
        refuse = null;
      });

      Widget sheet() => Scaffold(
        body: ServerSpaceSheet(
          state: chain.state,
          account: alice.id,
          load: () async => const [],
          approve: (change, record) async {},
          drop: (change) async {},
          sign: (entry) async => throw StateError('nothing is signed here'),
          reloadState: () async => chain.state,
          now: () => 1700000100,
          loadHeld: () async => [...held],
          keepHeld: (id) async {
            final problem = refuse;
            if (problem != null) {
              throw HeldItemError(problem);
            }
            kept.add(id);
            held.removeWhere((entry) => entry.id == id);
          },
          deleteHeld: (id) async {
            deleted.add(id);
            held.removeWhere((entry) => entry.id == id);
          },
        ),
      );

      testWidgets('shows each held item, and Keep is only for one with an accepted copy', (tester) async {
        await pumpScreen(tester, sheet(), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.held.title')), findsOneWidget);
        expect(find.text('Site l1'), findsOneWidget);
        expect(find.text(messages.t('space.held.item', {'named': 'no', 'name': ''})), findsOneWidget);
        expect(find.text(messages.t('space.held.cantKeep')), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byKey(keepKey(uuid(0x11)))).onPressed, isNotNull);
        expect(tester.widget<FilledButton>(find.byKey(keepKey(uuid(0x12)))).onPressed, isNull);
        expect(tester.widget<TextButton>(find.byKey(deleteKey(uuid(0x12)))).onPressed, isNotNull);
      });

      testWidgets('Keep releases the item and the list is read again', (tester) async {
        await pumpScreen(tester, sheet(), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(keepKey(uuid(0x11))));
        await tester.pump(const Duration(seconds: 10));

        expect(kept, [uuid(0x11)]);
        expect(find.byKey(keepKey(uuid(0x11))), findsNothing);
        expect(find.byKey(deleteKey(uuid(0x12))), findsOneWidget);
      });

      testWidgets('Delete releases an item that can’t be kept', (tester) async {
        await pumpScreen(tester, sheet(), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(deleteKey(uuid(0x12))));
        await tester.pump(const Duration(seconds: 10));

        expect(deleted, [uuid(0x12)]);
        expect(find.byKey(deleteKey(uuid(0x12))), findsNothing);
      });

      testWidgets('a refusal is shown with its reason and the item stays', (tester) async {
        refuse = HeldItemProblem.keysPending;
        await pumpScreen(tester, sheet(), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(keepKey(uuid(0x11))));
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.held.problem', {'problem': 'keysPending'})), findsOneWidget);
        expect(find.byKey(keepKey(uuid(0x11))), findsOneWidget);
      });

      testWidgets('says so when nothing is held', (tester) async {
        held = [];
        await pumpScreen(tester, sheet(), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.held.none')), findsOneWidget);
      });
    });
  }
}

/// Scrolls [finder] into view, taps it and lets the screen settle.
Future<void> _tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
