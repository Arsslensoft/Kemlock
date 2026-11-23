import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/breaches/breach_list.dart';
import 'package:kemlock/features/breaches/breach_providers.dart';
import 'package:kemlock/features/breaches/breach_refresh.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import 'breach_kit.dart';
import 'breach_list_test.dart' show hibpFixture;
import 'fake_hibp.dart';

// The phone ships with the fixture's breaches but Trello's; Have I Been Pwned has since
// listed Trello's, last.
final _withoutTrello = [
  for (final breach in hibpFixture())
    if ((breach! as Map<String, Object?>)['Name'] != 'Trello') breach,
];
final _trello = hibpFixture().firstWhere((breach) => (breach! as Map<String, Object?>)['Name'] == 'Trello');
final Override _shipped = bundledBreachListProvider.overrideWith((ref) async => BreachList.fromHibp(_withoutTrello, updated: '2026-10-01'));

FakeHibp _service() => FakeHibp([..._withoutTrello, _trello]);

/// What a request holds, to compare two of them.
String _sent(http.Request request) => '${request.method} ${request.url} ${request.headers} ${request.body}';

Finder _switchOf(String primary) => find.descendant(of: find.widgetWithText(GroupRow, primary), matching: find.byType(Switch));

void main() {
  testWidgets('makes no request when the open vault has updates off', (tester) async {
    final hibp = _service();
    await openVaultWith(tester, accounts: [breachAccount('a', 'Trello')], breaches: _shipped, overrides: hibp.overrides);

    expect(hibp.requests, isEmpty);
    expect(find.text(t('settings.health.breachesNone')), findsOneWidget);
  });

  testWidgets('checks once when a vault with updates on opens, and not again that day', (tester) async {
    final hibp = _service();
    var app = await openVaultWith(
      tester,
      accounts: [breachAccount('a', 'Trello')],
      prefs: {'breachRefresh': true},
      breaches: _shipped,
      overrides: hibp.overrides,
    );

    expect(hibp.asked, ['/api/v3/latestbreach', '/api/v3/breaches']);
    expect(app.store.getItem(keyBreachList), contains('"Trello"'));
    // The breach is new for the account, without the app starting again
    expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);

    // The app starts again the same day: the stored list is in use, and nothing is asked
    hibp.requests.clear();
    app = await app.restart(tester);
    await app.unlock(tester, 'pw');
    await tester.pumpAndSettle();
    expect(hibp.requests, isEmpty);
    expect(app.container.read(breachFindingsProvider).serviceCount, 1);
  });

  testWidgets('turning updates on in Settings checks at once, and the health line follows', (tester) async {
    final hibp = _service();
    final app = await openVaultWith(tester, accounts: [breachAccount('a', 'Trello')], breaches: _shipped, overrides: hibp.overrides);
    expect(find.text(t('settings.breachRefresh.detail')), findsOneWidget);
    expect(tester.widget<Switch>(_switchOf(t('settings.breachRefresh'))).value, isFalse);

    await tester.tap(_switchOf(t('settings.breachRefresh')));
    await tester.pumpAndSettle();

    expect(app.container.read(prefsProvider).breachRefresh, isTrue);
    expect(hibp.asked, ['/api/v3/latestbreach', '/api/v3/breaches']);
    expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);

    // Off again: the list already on the phone stays in use, and nothing more is asked
    hibp.requests.clear();
    await tester.tap(_switchOf(t('settings.breachRefresh')));
    await tester.pumpAndSettle();
    expect(app.container.read(prefsProvider).breachRefresh, isFalse);
    expect(hibp.requests, isEmpty);
    expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);
  });

  testWidgets('sends the same requests whatever the vault holds', (tester) async {
    final first = _service();
    await openVaultWith(
      tester,
      accounts: [breachAccount('a', 'Trello'), breachAccount('b', 'Adobe')],
      services: [breachCodes('s', 'Canva')],
      prefs: {'breachRefresh': true},
      breaches: _shipped,
      overrides: first.overrides,
    );
    final second = _service();
    await openVaultWith(
      tester,
      accounts: [breachAccount('z', 'GitHub')],
      prefs: {'breachRefresh': true},
      breaches: _shipped,
      overrides: second.overrides,
    );

    expect(first.requests, hasLength(2));
    expect([for (final request in second.requests) _sent(request)], [for (final request in first.requests) _sent(request)]);
    final sent = first.requests.map(_sent).join(' ');
    for (final secret in ['Trello', 'Adobe', 'Canva', 'example.com', 'JBSWY3DPEHPK3PXP']) {
      expect(sent, isNot(contains(secret)));
    }
  });

  testWidgets('a check that fails shows nothing and leaves the breaches as they were', (tester) async {
    final hibp = _service()..offline = true;
    final app = await openVaultWith(
      tester,
      accounts: [breachAccount('a', 'Trello')],
      prefs: {'breachRefresh': true},
      breaches: _shipped,
      overrides: hibp.overrides,
    );

    expect(hibp.requests, hasLength(1));
    expect(app.store.getItem(keyBreachList), isNull);
    expect(find.text(t('settings.health.breachesNone')), findsOneWidget);
    expect(find.byType(AppAlert), findsNothing);
  });

  // openspec: add-offline-mode, "Breach checks are paused"
  group('while offline mode is on', () {
    final twoDaysAgo = '{"at":${testNow.subtract(const Duration(days: 2)).millisecondsSinceEpoch},"latest":"Adobe"}';

    /// [stored] puts the list an earlier update fetched, with Trello's breach, on the phone.
    Future<TestApp> openOffline(
      WidgetTester tester,
      FakeHibp hibp, {
      Map<String, Object?> prefs = const {'breachRefresh': true},
      bool stored = false,
    }) => openVaultWith(
      tester,
      accounts: [breachAccount('a', 'Trello'), breachAccount('b', 'Adobe')],
      prefs: prefs,
      breaches: _shipped,
      overrides: hibp.overrides,
      before: (app) {
        app.store
          ..setItem(keyOffline, '{"on":true}')
          ..setItem(keyBreachCheck, twoDaysAgo);
        if (stored) {
          final list = BreachList.fromHibp([..._withoutTrello, _trello], updated: '2026-10-14');
          app.store.setItem(keyBreachList, jsonEncode(list.toJson()));
        }
      },
    );

    testWidgets('a check that is due makes no request and leaves the time of the last one', (tester) async {
      final hibp = _service();
      final app = await openOffline(tester, hibp);
      await tester.pump(const Duration(hours: 1));

      expect(hibp.requests, isEmpty);
      expect(app.store.getItem(keyBreachCheck), twoDaysAgo);
      expect(app.store.getItem(keyBreachList), isNull);
    });

    testWidgets('alerts still come from the list on the phone', (tester) async {
      final hibp = _service();
      final app = await openOffline(tester, hibp, stored: true);

      expect(hibp.requests, isEmpty);
      expect(app.container.read(breachFindingsProvider).serviceCount, 1);
      expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);
    });

    testWidgets('the two settings keep their switches and values, and are tagged paused', (tester) async {
      final hibp = _service();
      final app = await openOffline(tester, hibp, prefs: {'breachRefresh': true, 'leakCheck': true});

      for (final id in ['settings.breachRefresh', 'settings.leakCheck']) {
        final row = find.widgetWithText(GroupRow, t(id));
        expect(tester.widget<Switch>(_switchOf(t(id))).value, isTrue, reason: id);
        expect(
          find.descendant(of: row, matching: find.widgetWithText(StatusTag, t('settings.offline.paused').toUpperCase())),
          findsOneWidget,
        );
      }

      // Turning the update off and on again asks nothing either
      await tester.tap(_switchOf(t('settings.breachRefresh')));
      await tester.pumpAndSettle();
      await tester.tap(_switchOf(t('settings.breachRefresh')));
      await tester.pumpAndSettle();
      expect(app.container.read(prefsProvider).breachRefresh, isTrue);
      expect(hibp.requests, isEmpty);
    });

    testWidgets('the check that was due runs when offline mode is turned off', (tester) async {
      final hibp = _service();
      final app = await openOffline(tester, hibp);

      app.container.read(offlineProvider.notifier).set(false);
      await tester.pumpAndSettle();

      expect(hibp.asked, ['/api/v3/latestbreach', '/api/v3/breaches']);
      expect(app.store.getItem(keyBreachCheck), isNot(twoDaysAgo));
      expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);
      expect(find.byType(StatusTag), findsNothing);
    });

    testWidgets('turning offline mode off asks nothing when the vault has updates off', (tester) async {
      final hibp = _service();
      final app = await openOffline(tester, hibp, prefs: const {});

      app.container.read(offlineProvider.notifier).set(false);
      await tester.pumpAndSettle();

      expect(hibp.requests, isEmpty);
    });
  });
}
