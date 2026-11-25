// The sheet of a vault that syncs with Kemlock Server (add-kemlock-server-sync,
// task 8.7): what it shows, what it asks after a run the removal guard stopped,
// and that Turn off signs out and keeps every entry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/removal_guard.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_messages.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/platform/push.dart';

import '../../../fakes/fake_push_tokens.dart';
import '../../../helpers/test_app.dart';
import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com:8443')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

/// A vault that syncs with Kemlock Server, its sheet open. [signedOut] records each sign-out the host is asked for.
Future<SyncSheetKit> _open(WidgetTester tester, {List<KemlockTarget>? signedOut, bool unreachable = false}) async {
  final push = FakePushTokens.apns();
  addTearDown(push.close);
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSyncSheet,
    overrides: [
      pushTokensProvider.overrideWithValue(push),
      kemlockSignOutProvider.overrideWithValue((target) async {
        signedOut?.add(target);
        if (unreachable) throw StateError('no route to host');
      }),
    ],
  );
  await kit.save(const SyncSettings(kemlock: _target));
  await kit.open(tester);
  return kit;
}

void main() {
  testWidgets('says who is signed in and where, and that nothing has synced yet', (tester) async {
    await _open(tester);

    expect(find.text(t('kemlock.on.body', {'host': 'kem.example.com:8443', 'email': 'me@example.com'})), findsOneWidget);
    expect(find.text(t('sync.status.never')), findsOneWidget);
    expect(button(tester, t('sync.now')).onPressed, isNotNull);
    expect(find.text(t('kemlock.on.hint')), findsOneWidget);
  });

  testWidgets('shows when the last sync went through, and how many items it left alone', (tester) async {
    final kit = await _open(tester);

    kit.sync.setScopeStatus(kemlockScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch, count: 3));
    await tester.pumpAndSettle();

    final when = syncTime(tester.element(find.byType(SyncSheet)), testNow.millisecondsSinceEpoch);
    expect(find.text(t('sync.status.synced', {'when': when})), findsOneWidget);
    expect(find.text(t('kemlock.on.left', {'count': 3})), findsOneWidget);
  });

  testWidgets('says why a sync stopped, in words, and that the session ended', (tester) async {
    final kit = await _open(tester);

    kit.sync.setScopeStatus(kemlockScope, const ScopeStatus(problem: SyncProblem.sessionEnded));
    await tester.pumpAndSettle();

    expect(find.text(t('sync.problem.sessionEnded')), findsOneWidget);
    expect(find.text(t('kemlock.on.left', {'count': 0})), findsNothing);
  });

  testWidgets('asks before many removals, and passes the answer on', (tester) async {
    final kit = await _open(tester);
    kit.sync.setScopeStatus(kemlockScope, const ScopeStatus(problem: SyncProblem.removals, count: 7));
    await tester.pumpAndSettle();

    expect(find.text(t('vaultwarden.removals.body', {'count': 7})), findsOneWidget);
    await tapButton(tester, t('vaultwarden.removals.keep'));

    expect(kit.sync.removalChoice, RemovalChoice.keep);
  });

  testWidgets('with offline mode on, says sync is paused, keeps the last sync on show and cannot sync now', (tester) async {
    final kit = await _open(tester);
    kit.sync.setScopeStatus(kemlockScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
    await kit.setOffline(tester, true);

    expect(offlineAlert(t('sync.offline')), findsOneWidget);
    expect(button(tester, t('sync.now')).onPressed, isNull);
    expect(button(tester, t('sync.off')).onPressed, isNotNull, reason: 'turning sync off needs no network here');
    expect(kit.container.read(syncProvider).status[kemlockScope]?.problem, isNull);
  });

  testWidgets('the push switch starts on, and turning it off is kept in the settings', (tester) async {
    final kit = await _open(tester);
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, t('kemlock.push'))).value, isTrue);

    await tester.tap(find.text(t('kemlock.push')));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, t('kemlock.push'))).value, isFalse);
    expect(kit.settings?.kemlock?.push, isFalse);
    expect(kit.settings?.kemlock?.toJson()['push'], false);
    expect(const SyncSettings(kemlock: _target).toJson()['kemlock'], isNot(contains('push')), reason: 'on is the default, and not written');
  });

  group('Turn off', () {
    testWidgets('signs this phone out, deletes the session, the account and the cache, removes the target and keeps every entry', (
      tester,
    ) async {
      final signedOut = <KemlockTarget>[];
      final kit = await _open(tester, signedOut: signedOut);
      for (final (i, name) in ['Larkspur Mail', 'Bank'].indexed) {
        await kit.vault.addLogin(Login(id: 'l$i', name: name, password: 'p$i', addedAt: 0));
      }
      for (final key in [keyKemlockSession, keyKemlockAccount, keyKemlockCache]) {
        await kit.vaultStore.saveEncryptedValue(key, {'sealed': key}, kit.session);
      }
      kit.sync.setScopeStatus(kemlockScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await tester.pumpAndSettle();

      await tapButton(tester, t('sync.off'));

      expect(signedOut, [_target]);
      expect(kit.settings?.kemlock, isNull);
      for (final key in [keyKemlockSession, keyKemlockAccount, keyKemlockCache]) {
        expect(await kit.vaultStore.loadEncryptedValue(key, kit.session), isNull, reason: key);
      }
      expect(kit.vaultState.logins.map((login) => login.name), ['Larkspur Mail', 'Bank']);
      expect(kit.container.read(syncProvider).status, isNot(contains(kemlockScope)));
      expect(find.text(t('sync.connect')), findsOneWidget, reason: 'the setup is back');
    });

    testWidgets('goes on when the server can’t be reached: the phone signs out anyway', (tester) async {
      final signedOut = <KemlockTarget>[];
      final kit = await _open(tester, signedOut: signedOut, unreachable: true);
      await kit.vaultStore.saveEncryptedValue(keyKemlockSession, {'tokens': 'x'}, kit.session);

      await tapButton(tester, t('sync.off'));

      expect(signedOut, hasLength(1));
      expect(kit.settings?.kemlock, isNull);
      expect(await kit.vaultStore.loadEncryptedValue(keyKemlockSession, kit.session), isNull);
    });

    testWidgets('leaves WebDAV spaces and the other sealed values alone', (tester) async {
      final kit = await _open(tester);
      await kit.vaultStore.saveEncryptedValue(keyVaultwardenKeep, {'a': 1}, kit.session);

      await tapButton(tester, t('sync.off'));

      expect(await kit.vaultStore.loadEncryptedValue(keyVaultwardenKeep, kit.session), {'a': 1});
    });
  });
}

/// A sealed value of another feature, which turning Kemlock Server sync off must not touch.
const keyVaultwardenKeep = 'backmycodes_vaultwarden';
