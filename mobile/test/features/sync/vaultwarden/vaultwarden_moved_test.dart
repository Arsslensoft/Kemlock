// A phone still on Vaultwarden sync whose home another phone closed (move-off-vaultwarden-sync, design 11, task 5.2): when
// the server speaks Kemlock's own API the problem line says the vault moved, with Sign in; otherwise today's message stays.
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

Finder get _title => find.text(t('vaultwarden.moved.title'));

void main() {
  testWidgets('says the vault moved, with Sign in, when the home is gone and the server speaks Kemlock', (tester) async {
    final handed = <(VaultwardenTarget, KemlockOffer)>[];
    final (kit, server) = await _on(
      tester,
      kemlock: _speaksKemlock,
      today: () => DateTime(2026, 11, 22, 9),
      overrides: [moveOffVaultwardenProvider.overrideWithValue((context, target, offer) async => handed.add((target, offer)))],
    );

    kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.homeMissing));
    await tester.pumpAndSettle();

    expect(server.requests.where((request) => request.url.path == '/api/config'), isNotEmpty);
    expect(_title, findsOneWidget);
    expect(find.text(t('sync.problem.homeMissing')), findsNothing);
    expect(find.text(t('vaultwarden.moved.body')), findsOneWidget);

    await tapButton(tester, t('vaultwarden.moved.signIn'));

    expect(handed, hasLength(1));
    expect(handed.single.$2.api, 'https://vault.example.com/kem/v1');
  });

  testWidgets('keeps today’s problem when the server has no Kemlock API', (tester) async {
    final (kit, _) = await _on(tester, today: () => DateTime(2026, 11, 22, 9));

    kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.homeMissing));
    await tester.pumpAndSettle();

    expect(_title, findsNothing);
    expect(find.text(t('sync.problem.homeMissing')), findsOneWidget);
    expect(find.text(t('vaultwarden.moved.signIn')), findsNothing);
  });

  testWidgets('says nothing about a move for any other problem', (tester) async {
    final (kit, _) = await _on(tester, kemlock: _speaksKemlock, today: () => DateTime(2026, 11, 22, 9));

    kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.signedOut));
    await tester.pumpAndSettle();

    expect(_title, findsNothing);
    expect(find.text(t('sync.problem.signedOut')), findsOneWidget);
  });
}
