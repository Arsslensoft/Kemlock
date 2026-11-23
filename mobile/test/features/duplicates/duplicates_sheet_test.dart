import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/features/duplicates/dedup_tagger.dart';
import 'package:kemlock/features/duplicates/duplicate_matcher.dart';
import 'package:kemlock/features/duplicates/duplicate_merge.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/features/duplicates/duplicate_view.dart';
import 'package:kemlock/features/duplicates/duplicates_provider.dart';
import 'package:kemlock/features/duplicates/duplicates_sheet.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/secure_note.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

Login _login(String id, String name, {String password = 'one'}) =>
    Login(id: id, name: name, username: 'sam', password: password, websites: const ['proton.me'], addedAt: 0);

/// The app with a duplicate login, a duplicate note and a code under two issuers in the vault, the
/// Duplicates screen open.
Future<TestApp> _openScreen(WidgetTester tester, {ThemeChoice theme = ThemeChoice.light, AppLocale locale = AppLocale.en}) async {
  tester.view.physicalSize = const Size(800, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var now = DateTime.utc(2026, 11, 21, 12);
  final app = TestApp(now: () => now);
  await tester.runAsync(() => app.createVault('pw'));
  await app.pump(tester, overrides: [suffixListHashProvider.overrideWith((ref) async => 'none')]);
  await app.unlock(tester, 'pw');
  app.controller.biometricOffered();
  app.container.read(themeChoiceProvider.notifier).choose(theme);
  app.container.read(localeProvider.notifier).setLocale(locale);
  await app.controller.addLogin(_login('a', 'proton.me'));
  now = now.add(const Duration(minutes: 1));
  await app.controller.addLogin(_login('b', 'Proton Mail'));
  await app.controller.addNote(const SecureNote(id: 'n1', title: 'Wifi', text: 'secret', addedAt: 0));
  await app.controller.addNote(const SecureNote(id: 'n2', title: 'Wifi at home', text: 'secret', addedAt: 0));
  await app.controller.addAccount(OtpAccount(id: 'x', issuer: 'Google', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
  await app.controller.addAccount(OtpAccount(id: 'y', issuer: 'google.com', label: 'me', secret: 'jbsw y3dp ehpk 3pxp', addedAt: 0));
  await app.container.read(duplicatesProvider.notifier).check();
  // The toast of the last item saved would sit over the sheet's lowest buttons: let it go
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
  unawaited(showDuplicatesSheet(tester.element(find.byType(Scaffold).first)));
  await tester.pumpAndSettle();
  return app;
}

String _t(String id, [Map<String, Object?> args = const {}]) => t(id, args);

// The plan's task 5.1: the Duplicates screen
void main() {
  group('the screen', () {
    testWidgets('lists each group with why it matched, and its items\' place and date', (tester) async {
      await _openScreen(tester);

      expect(find.text(_t('duplicates.title')), findsOneWidget);
      expect(find.text(_t('duplicates.onDevice')), findsOneWidget);
      expect(find.text(_t('duplicates.reason.sameSignIn')), findsOneWidget);
      expect(find.text(_t('duplicates.reason.sameNote')), findsOneWidget);
      expect(find.text(_t('duplicates.reason.sameCode')), findsOneWidget);
      expect(
        find.textContaining('Proton Mail · ${_t('duplicates.item.meta', {'place': _t('duplicates.place.vault'), 'date': 'Nov 21, 2026'})}'),
        findsOneWidget,
      );
    });

    testWidgets('narrows to logins, codes, notes or the groups in two places', (tester) async {
      await _openScreen(tester);

      await tester.tap(find.byKey(const ValueKey('filter-notes')));
      await tester.pumpAndSettle();
      expect(find.text(_t('duplicates.reason.sameNote')), findsOneWidget);
      expect(find.text(_t('duplicates.reason.sameSignIn')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('filter-logins')));
      await tester.pumpAndSettle();
      expect(find.text(_t('duplicates.reason.sameSignIn')), findsOneWidget);
      expect(find.text(_t('duplicates.reason.sameCode')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('filter-codes')));
      await tester.pumpAndSettle();
      expect(find.text(_t('duplicates.reason.sameCode')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('filter-places')));
      await tester.pumpAndSettle();
      expect(find.text(_t('duplicates.empty')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('filter-all')));
      await tester.pumpAndSettle();
      expect(find.text(_t('duplicates.reason.sameSignIn')), findsOneWidget);
    });

    testWidgets('Review opens the merge sheet of the group', (tester) async {
      await _openScreen(tester);

      await tester.tap(find.text(_t('duplicates.review')).first);
      await tester.pumpAndSettle();

      expect(find.text(_t('duplicates.merge.title')), findsOneWidget);
    });

    testWidgets('Not duplicates takes the group off, and Check again keeps it off', (tester) async {
      final app = await _openScreen(tester);
      final logins = app.container.read(duplicatesProvider).groups.firstWhere((group) => group.items.first.item is Login);

      await tester.tap(
        find.descendant(of: find.byKey(ValueKey('group-${logins.key}')), matching: find.text(_t('duplicates.notDuplicates'))),
      );
      await tester.pumpAndSettle();
      expect(find.text(_t('duplicates.reason.sameSignIn')), findsNothing);

      await tester.tap(find.text(_t('duplicates.checkAgain')));
      await tester.pumpAndSettle();

      expect(find.text(_t('duplicates.reason.sameSignIn')), findsNothing);
      expect(app.container.read(duplicatesProvider).groups, hasLength(2));
    });

    testWidgets('Check again finds a group made since', (tester) async {
      final app = await _openScreen(tester);
      await app.controller.addNote(const SecureNote(id: 'n3', title: 'Other', text: 'different', addedAt: 0));
      await app.controller.addNote(const SecureNote(id: 'n4', title: 'Other again', text: 'different', addedAt: 0));

      await tester.tap(find.text(_t('duplicates.checkAgain')));
      await tester.pumpAndSettle();

      expect(find.text(_t('duplicates.reason.sameNote')), findsNWidgets(2));
    });

    testWidgets('shows a merge in Recent merges, and Undo merge brings the items back', (tester) async {
      final app = await _openScreen(tester);
      final group = app.container.read(duplicatesProvider).groups.firstWhere((group) => group.items.first.item is SecureNote);
      await app.controller.mergeDuplicates(MergeChoices(group.items));
      await tester.pumpAndSettle();

      expect(find.text(_t('duplicates.undo.title').toUpperCase()), findsOneWidget);
      expect(find.text(_t('duplicates.undo.hint')), findsOneWidget);
      expect(app.state.notes, hasLength(1));

      await tester.tap(find.text(_t('duplicates.undo.button')));
      await tester.pumpAndSettle();

      expect(app.state.notes, hasLength(2));
      expect(find.text(_t('duplicates.undo.title').toUpperCase()), findsNothing);
    });

    testWidgets('says so when there is nothing to review', (tester) async {
      final app = await _openScreen(tester);
      for (final group in app.container.read(duplicatesProvider).groups) {
        await app.container.read(duplicatesProvider.notifier).dismiss(group);
      }
      await tester.pumpAndSettle();

      expect(find.text(_t('duplicates.empty')), findsOneWidget);
    });
  });

  group('in light, dark and French', () {
    for (final (name, theme, locale) in [
      ('light', ThemeChoice.light, AppLocale.en),
      ('dark', ThemeChoice.dark, AppLocale.en),
      ('French', ThemeChoice.light, AppLocale.fr),
    ]) {
      testWidgets('shows the screen in $name', (tester) async {
        await _openScreen(tester, theme: theme, locale: locale);
        final copy = testCatalog.of(locale);

        expect(find.text(copy.t('duplicates.title')), findsOneWidget);
        expect(find.text(copy.t('duplicates.reason.sameSignIn')), findsOneWidget);
        expect(find.text(copy.t('duplicates.review')), findsNWidgets(3));
        expect(find.text(copy.t('duplicates.checkAgain')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the filters', () {
    DuplicateGroup pair(Object item, Object other) {
      final items = dedupItems(
        logins: [if (item is Login) item, if (other is Login) other],
        notes: [if (item is SecureNote) item, if (other is SecureNote) other],
      );
      return DuplicateGroup(reason: DuplicateReason.sameNote, items: items);
    }

    test('each keeps the groups of its kind, and All keeps every group', () {
      final logins = pair(_login('a', 'A'), _login('b', 'B'));
      final notes = pair(const SecureNote(id: 'n', title: 'T', addedAt: 0), const SecureNote(id: 'm', title: 'U', addedAt: 0));
      final all = [logins, notes];

      expect(filtered(DuplicateFilter.all, all), all);
      expect(filtered(DuplicateFilter.logins, all), [logins]);
      expect(filtered(DuplicateFilter.notes, all), [notes]);
      expect(filtered(DuplicateFilter.codes, all), isEmpty);
      expect(filtered(DuplicateFilter.places, all), isEmpty);
    });

    test('In two places keeps the groups held in more than one place', () {
      final across = DuplicateGroup(
        reason: DuplicateReason.inTwoPlaces,
        items: dedupItems(
          logins: [
            _login('a', 'A'),
            _login('b', 'B').copyWith(spaceId: 'team'),
          ],
        ),
      );

      expect(filtered(DuplicateFilter.places, [across]), [across]);
    });
  });

  test('every new message of the Duplicates screens is in English and in French, and not empty', () {
    Map<String, Object?> read(String code) => jsonDecode(File('assets/i18n/$code.json').readAsStringSync()) as Map<String, Object?>;
    final en = read('en');
    final fr = read('fr');
    final ids = en.keys.where(
      (id) => id.startsWith('duplicates.') || id.startsWith('settings.health.duplicates') || id.startsWith('vault.snack.duplicates'),
    );

    expect(ids, isNotEmpty);
    for (final id in ids) {
      expect(fr[id], isA<String>(), reason: id);
      expect((fr[id]! as String).trim(), isNotEmpty, reason: id);
      expect((en[id]! as String).trim(), isNotEmpty, reason: id);
    }
    expect(fr.keys.where((id) => id.startsWith('duplicates.')), unorderedEquals(en.keys.where((id) => id.startsWith('duplicates.'))));
  });
}
