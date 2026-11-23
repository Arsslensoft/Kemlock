import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/breaches/hibp.dart';
import 'package:kemlock/features/settings/offline_alert.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/settings/settings_page.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../features/breaches/breach_kit.dart' show fixtureBreachList;
import '../features/sync/fake_webdav.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

const _dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const _syncPath = '/files/me/Kemlock/$syncFile';

Finder _switchOf(String primary) => find.descendant(of: find.widgetWithText(GroupRow, primary), matching: find.byType(Switch));

/// Offline mode from end to end (openspec: add-offline-mode): a vault with WebDAV sync,
/// the breach list update and the leak check all on, on a phone whose every way out is a
/// fake that keeps what it was asked. With the switch on, a whole session sends nothing;
/// turned off, sync runs once.
void main() {
  testWidgets('a session with offline mode on sends nothing, and turning it off resumes sync', (tester) async {
    final dav = FakeWebDav();
    // Have I Been Pwned and Pwned Passwords: nothing has leaked, and no newer breach is listed
    final hibp = <http.Request>[];
    final hibpClient = MockClient((request) async {
      hibp.add(request);
      return request.url.host == 'api.pwnedpasswords.com' ? http.Response('${'0' * 35}:0', 200) : http.Response('', 503);
    });
    final vaultwarden = <http.Request>[];
    final app = TestApp();
    final syncKey = b64(randomBytes(32));
    await tester.runAsync(() async {
      final session = await app.createVault('first-password');
      await app.vaultStore.saveEncryptedValue(
        'backmycodes_sync',
        const SyncSettings()
            .copyWith(
              personal: SyncTarget(dav: _dav, file: syncFile, key: syncKey),
            )
            .toJson(),
        session,
      );
    });
    app.store.setItem(prefsKey, jsonEncode({'breachRefresh': true, 'leakCheck': true}));
    await startApp(
      tester,
      app,
      overrides: [
        fixtureBreachList,
        webDavProvider.overrideWithValue(WebDav(dav.client)),
        hibpClientProvider.overrideWithValue(hibpClient),
        hibpUserAgentProvider.overrideWith((ref) async => 'Kemlock/1.1.0'),
        vwClientFactoryProvider.overrideWithValue(
          (_) => MockClient((request) async {
            vaultwarden.add(request);
            return http.Response('', 503);
          }),
        ),
      ],
    );

    // Online: unlocking syncs and asks for newer breaches
    await app.unlock(tester, 'first-password');
    expect(dav.requests, isNotEmpty);
    expect(hibp, isNotEmpty);
    expect(app.state.isUnlocked, isTrue);

    // The switch, in Settings
    await goTo(tester, app, '/settings');
    await tapOn(tester, _switchOf(t('settings.offline')));
    expect(app.store.getItem(keyOffline), '{"on":true}');
    dav.requests.clear();
    hibp.clear();

    // A change made while offline is kept on the phone
    await app.controller.addAccount(const OtpAccount(id: '', issuer: 'Added offline', label: '', secret: rfcSecret, addedAt: 1));
    await tester.pump(const Duration(seconds: 5));

    // Lock, unlock and every tab, a minute on each, short of the auto-lock
    app.controller.lock();
    await tester.pumpAndSettle();
    await app.unlock(tester, 'first-password');
    for (final path in ['/accounts', '/backup', '/vault', '/settings']) {
      await goTo(tester, app, path);
      await tester.pump(const Duration(minutes: 1));
    }
    expect(find.widgetWithText(GroupRow, t('settings.offline.sync')), findsWidgets);

    // The sync sheet says it is paused. Settings is a lazy list: its sync row is built once scrolled to
    final syncRow = find.widgetWithText(GroupRow, t('settings.sync.hint'));
    await tester.scrollUntilVisible(syncRow, 300, scrollable: find.byType(Scrollable).first);
    await tapOn(tester, syncRow);
    expect(find.widgetWithText(OfflineAlert, t('sync.offline')), findsOneWidget);
    await tapOn(tester, find.text(t('offline.settings')));
    expect(find.byType(SettingsPage), findsOneWidget);

    // A new master password, with the leak check on: not checked, and said so
    await tapOn(tester, find.widgetWithText(GroupRow, t('app.menu.changePassword')));
    expect(find.text(t('leakCheck.offline')), findsOneWidget);
    await tester.enterText(field(t('changePw.field.current')), 'first-password');
    await tester.enterText(field(t('changePw.field.new')), 'second-password');
    await tester.enterText(field(t('changePw.field.confirm')), 'second-password');
    await tester.pump();
    await tapOn(tester, find.text(t('changePw.button')));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.runAsync(() => app.vaultStore.unlockVault('second-password'));

    // Nothing was sent, by anything
    expect(dav.requests, isEmpty);
    expect(hibp, isEmpty);
    expect(vaultwarden, isEmpty);
    expect(app.state.accounts.map((account) => account.issuer), ['Added offline']);
    expect(app.container.read(syncProvider).status.values.where((status) => status.problem != null), isEmpty);
    expect(app.container.read(prefsProvider).leakCheck, isTrue);
    expect(app.container.read(prefsProvider).breachRefresh, isTrue);

    // Off again: one sync, which takes the account to the folder
    await goTo(tester, app, '/settings');
    await tapOn(tester, _switchOf(t('settings.offline')));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(app.store.getItem(keyOffline), isNull);
    expect(dav.requests.where((request) => request.method == 'GET' && request.url.path == _syncPath), hasLength(1));
    final synced = await decryptSyncFile(dav.files[_syncPath]!.text, unb64(syncKey));
    expect(synced.accounts.map((account) => account.issuer), ['Added offline']);
    expect(app.container.read(networkGateProvider).offline, isFalse);
  });
}
