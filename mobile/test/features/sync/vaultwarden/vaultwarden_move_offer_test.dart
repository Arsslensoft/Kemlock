// The offer to move from Vaultwarden to Kemlock Server (add-kemlock-server-sync, task 12.2): a server whose
// `/api/config` has a `kemlock` member gets "This server also speaks Kemlock's own API" with Move and Not now in
// the Vaultwarden sheet, at most once a day; Not now keeps it hidden until a later day; Move goes to the seam
// `move-off-vaultwarden-sync` fills.
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_kemlock_offer.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';

import '../../../helpers/test_app.dart';
import '../sync_screen_kit.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

const _speaksKemlock = {
  'api': 'https://vault.example.com/kem/v1',
  'versions': ['v1'],
};

/// A vault syncing with [server], on its sheet, on the day [today] gives.
Future<(SyncSheetKit, FakeVaultwarden)> _on(
  WidgetTester tester, {
  Object? kemlock,
  required DateTime Function() today,
  List<Override> overrides = const [],
}) async {
  final server = FakeVaultwarden();
  await server.allowSignIn();
  server.kemlockConfig = kemlock;
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSyncSheet,
    clock: today,
    overrides: [vwClientFactoryProvider.overrideWithValue((pin) => server.newClient()), ...overrides],
  );
  final target = await makeHome(server, VaultwardenMode.sealed);
  await VaultwardenBackend(
    vault: kit.vaultStore,
    session: kit.session,
    clientFor: (_) => server.newClient(),
  ).saveCredentials(server.credentials());
  await kit.open(tester);
  await kit.save(SyncSettings(vaultwarden: target));
  await tester.pumpAndSettle();
  return (kit, server);
}

Finder get _title => find.text(t('vaultwarden.moveOffer.title'));

void main() {
  test('reads an offer from the config, and none where there is no kemlock member, version or https address', () {
    final offer = KemlockOffer.fromConfig({'kemlock': _speaksKemlock});
    expect(offer?.api, 'https://vault.example.com/kem/v1');
    expect(KemlockOffer.fromConfig({'Kemlock': _speaksKemlock})?.api, isNotNull, reason: 'Bitwarden servers vary the case');
    expect(KemlockOffer.fromConfig({}), isNull);
    expect(KemlockOffer.fromConfig({'kemlock': 'yes'}), isNull);
    expect(
      KemlockOffer.fromConfig({
        'kemlock': {
          'api': 'https://vault.example.com/kem/v1',
          'versions': ['v2'],
        },
      }),
      isNull,
    );
    expect(
      KemlockOffer.fromConfig({
        'kemlock': {
          'api': 'http://vault.example.com/kem/v1',
          'versions': ['v1'],
        },
      }),
      isNull,
      reason: 'a plain http address would send the sign-in in the clear',
    );
  });

  test('a day is the phone\'s calendar day, and an offer is due on any other', () {
    final target = VaultwardenTarget(
      server: 'https://vault.example.com',
      email: 'me@example.com',
      home: 'h',
      mode: VaultwardenMode.sealed,
      folderId: 'f',
      kemlockOfferDay: offerDay(DateTime(2026, 11, 22, 9)),
    );

    expect(offerDay(DateTime(2026, 11, 22, 9)), '2026-11-22');
    expect(offerDue(target, DateTime(2026, 11, 22, 23, 59)), isFalse);
    expect(offerDue(target, DateTime(2026, 11, 23)), isTrue);
  });

  test('settings from before keep their bytes: the day is written only once there is one', () {
    final json = {
      'server': 'https://vault.example.com',
      'email': 'me@example.com',
      'home': 'h',
      'mode': 'sealed',
      'folderId': 'f',
      'pickUp': false,
    };

    expect(VaultwardenTarget.fromJson(json).toJson(), json);
    expect(VaultwardenTarget.fromJson({...json, 'kemlockOfferDay': '2026-11-22'}).toJson()['kemlockOfferDay'], '2026-11-22');
  });

  testWidgets('shows the offer for a server that speaks Kemlock, and keeps the day it was shown', (tester) async {
    final day = DateTime(2026, 11, 22, 9);
    final (kit, server) = await _on(tester, kemlock: _speaksKemlock, today: () => day);

    expect(_title, findsOneWidget);
    expect(find.text(t('vaultwarden.moveOffer.move')), findsOneWidget);
    expect(find.text(t('vaultwarden.moveOffer.later')), findsOneWidget);
    expect(server.requests.where((request) => request.url.path == '/api/config'), isNotEmpty);
    expect(kit.settings?.vaultwarden?.kemlockOfferDay, '2026-11-22');
  });

  testWidgets('shows nothing for a server with no Kemlock API, and saves nothing', (tester) async {
    final (kit, _) = await _on(tester, today: () => DateTime(2026, 11, 22, 9));

    expect(_title, findsNothing);
    expect(kit.settings?.vaultwarden?.kemlockOfferDay, isNull);
  });

  testWidgets('Not now hides it, it stays hidden the rest of the day, and it comes back on a later day', (tester) async {
    var day = DateTime(2026, 11, 22, 9);
    final (kit, _) = await _on(tester, kemlock: _speaksKemlock, today: () => day);

    await tapButton(tester, t('vaultwarden.moveOffer.later'));
    expect(_title, findsNothing);

    await tapButton(tester, t('export.close'));
    await kit.open(tester);
    expect(_title, findsNothing, reason: 'the same day');

    day = DateTime(2026, 11, 23, 9);
    await tapButton(tester, t('export.close'));
    await kit.open(tester);
    expect(_title, findsOneWidget, reason: 'a later day');
    expect(kit.settings?.vaultwarden?.kemlockOfferDay, '2026-11-23');
  });

  testWidgets('Move hands the vault\'s Vaultwarden target and the offer to the seam, and changes nothing itself', (tester) async {
    final handed = <(VaultwardenTarget, KemlockOffer)>[];
    final (kit, _) = await _on(
      tester,
      kemlock: _speaksKemlock,
      today: () => DateTime(2026, 11, 22, 9),
      overrides: [moveOffVaultwardenProvider.overrideWithValue((context, target, offer) async => handed.add((target, offer)))],
    );
    final before = kit.settings?.vaultwarden?.toJson();

    await tapButton(tester, t('vaultwarden.moveOffer.move'));

    expect(handed, hasLength(1));
    expect(handed.single.$1.server, 'https://vault.example.com');
    expect(handed.single.$2.api, 'https://vault.example.com/kem/v1');
    expect({...?kit.settings?.vaultwarden?.toJson()}..remove('kemlockOfferDay'), {...?before}..remove('kemlockOfferDay'));
  });

  testWidgets('offline mode reads nothing and shows no offer', (tester) async {
    final server = FakeVaultwarden();
    await server.allowSignIn();
    server.kemlockConfig = _speaksKemlock;
    final kit = SyncSheetKit();
    await kit.pump(
      tester,
      showSyncSheet,
      clock: () => DateTime(2026, 11, 22, 9),
      overrides: [vwClientFactoryProvider.overrideWithValue((pin) => server.newClient())],
    );
    final target = await makeHome(server, VaultwardenMode.sealed);
    await VaultwardenBackend(
      vault: kit.vaultStore,
      session: kit.session,
      clientFor: (_) => server.newClient(),
    ).saveCredentials(server.credentials());
    await kit.save(SyncSettings(vaultwarden: target));
    await kit.setOffline(tester, true);
    server.requests.clear();

    await kit.open(tester);

    expect(_title, findsNothing);
    expect(server.requests, isEmpty);
  });
}
