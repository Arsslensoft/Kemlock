// Turning sync of the vault's own entries on and off, and how it's going:
// SyncDialog in syncDialogs.test.tsx, and what the screen shows of
// SyncController.test.tsx.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_messages.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import 'sync_screen_kit.dart';

final _path = folderPath(syncFile);

Future<SyncSheetKit> _open(WidgetTester tester, {bool syncHost = false}) async {
  final kit = SyncSheetKit();
  await kit.pump(tester, showSyncSheet, syncHost: syncHost);
  await kit.open(tester);
  return kit;
}

Future<void> _turnOn(WidgetTester tester, SyncSheetKit kit, {String url = folder, String passphrase = 'shared secret phrase'}) async {
  await kit.fillDav(tester, url: url);
  await tester.enterText(field(t('sync.field.passphrase')), passphrase);
  await tester.pump();
  await tapButton(tester, t('sync.connect'));
}

void main() {
  testWidgets('turns sync on with a new passphrase when the folder is empty', (tester) async {
    final kit = await _open(tester);
    expect(find.text(t('sync.title')), findsOneWidget);
    expect(find.text(t('sync.body')), findsOneWidget);

    await _turnOn(tester, kit);

    expect(find.text(t('sync.on.body', {'host': 'dav.example.com'})), findsOneWidget);
    final personal = kit.settings!.personal!;
    expect(personal.dav.url, folder);
    expect(personal.dav.username, 'me');
    expect(personal.file, syncFile);
    expect(personal.kdf, isNotNull);
    expect(unb64(personal.key), hasLength(32));
    // The key is derived from the passphrase and the new salt; the passphrase itself isn't kept
    expect(personal.key, b64(await deriveSyncKey('shared secret phrase', personal.kdf!, derive: fastKdf)));
    expect(personal.toJson().toString(), isNot(contains('shared secret phrase')));
  });

  testWidgets('keeps the passphrase from the phone’s password manager and the keyboard’s learning', (tester) async {
    await _open(tester);

    final passphrase = tester.widget<TextField>(field(t('sync.field.passphrase')));
    // Null keeps it out of autofill, which the empty default doesn't
    expect(passphrase.autofillHints, isNull);
    expect(passphrase.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('joins an existing sync only with its passphrase', (tester) async {
    final kit = SyncSheetKit();
    final kdf = newKdf();
    kit.server.put(_path, await encryptSyncFile(const SyncDoc(), await deriveSyncKey('the right phrase', kdf, derive: fastKdf), kdf: kdf));
    await kit.pump(tester, showSyncSheet);
    await kit.open(tester);

    await _turnOn(tester, kit, passphrase: 'the wrong phrase');

    expect(find.text(t('sync.problem.key')), findsOneWidget);
    expect(kit.settings?.personal, isNull);

    await tester.enterText(field(t('sync.field.passphrase')), 'the right phrase');
    await tester.pump();
    await tapButton(tester, t('sync.connect'));

    expect(kit.settings?.personal?.kdf, kdf);
    expect(find.text(t('sync.problem.key')), findsNothing);
  });

  testWidgets('refuses a plain http address', (tester) async {
    final kit = await _open(tester);

    await _turnOn(tester, kit, url: 'http://nas.local/dav/');

    expect(find.text(t('sync.problem.insecure')), findsOneWidget);
    expect(kit.server.requests, isEmpty);
    expect(kit.settings?.personal, isNull);
  });

  testWidgets('turns sync off again', (tester) async {
    final kit = await _open(tester);
    await _turnOn(tester, kit);

    await tapButton(tester, t('sync.off'));

    expect(kit.settings?.personal, isNull);
    expect(kit.settings?.spaces, isEmpty);
    expect(find.text(t('sync.connect')), findsOneWidget);
    expect(find.text(t('sync.on.hint')), findsNothing);
  });

  testWidgets('asks for a passphrase of at least 8 characters', (tester) async {
    final kit = await _open(tester);

    await _turnOn(tester, kit, passphrase: 'seven77');

    expect(find.text(t('sync.error.shortPassphrase')), findsOneWidget);
    expect(kit.server.requests, isEmpty);
    expect(kit.settings?.personal, isNull);
  });

  testWidgets('turns on only once the folder, username and passphrase are in', (tester) async {
    final kit = await _open(tester);
    expect(button(tester, t('sync.connect')).enabled, isFalse);

    await tester.enterText(field(t('sync.field.url')), folder);
    await tester.enterText(field(t('sync.field.username')), '  ');
    await tester.enterText(field(t('sync.field.passphrase')), 'shared secret phrase');
    await tester.pump();
    expect(button(tester, t('sync.connect')).enabled, isFalse);

    // The app password may be empty, as some servers take none
    await tester.enterText(field(t('sync.field.username')), 'me');
    await tester.pump();
    expect(button(tester, t('sync.connect')).enabled, isTrue);
    expect(kit.settings?.personal, isNull);
  });

  testWidgets('won’t take a folder that holds a shared space’s file as the vault’s', (tester) async {
    final kit = SyncSheetKit();
    // A space's file is keyed with the space's key, not a passphrase, so it has no salt
    kit.server.put(_path, await encryptSyncFile(const SyncDoc(), randomBytes(32)));
    await kit.pump(tester, showSyncSheet);
    await kit.open(tester);

    await _turnOn(tester, kit);

    expect(find.text(t('sync.problem.format')), findsOneWidget);
    expect(kit.settings?.personal, isNull);
  });

  testWidgets('says the server refused the login, and keeps what was typed', (tester) async {
    final kit = await _open(tester);
    kit.server.respond = (request) async => http.Response('', 401);

    await _turnOn(tester, kit);

    expect(find.text(t('sync.problem.auth')), findsOneWidget);
    expect(tester.widget<TextField>(field(t('sync.field.url'))).controller?.text, folder);
    expect(button(tester, t('sync.connect')).enabled, isTrue);
  });

  testWidgets('shows how the last sync went', (tester) async {
    final kit = await _open(tester);
    await _turnOn(tester, kit);
    expect(find.text(t('sync.status.never')), findsOneWidget);
    expect(find.text(t('sync.on.hint')), findsOneWidget);

    final at = testNow.millisecondsSinceEpoch;
    kit.sync.setScopeStatus(personalScope, ScopeStatus(lastSyncAt: at));
    await tester.pump();
    final when = syncTime(tester.element(find.byType(SyncSheet)), at);
    expect(find.text(t('sync.status.synced', {'when': when})), findsOneWidget);
    expect(tester.widget<AppAlert>(find.byType(AppAlert)).severity, AlertSeverity.success);

    kit.sync.setScopeStatus(personalScope, ScopeStatus(lastSyncAt: at, problem: SyncProblem.auth));
    await tester.pump();
    expect(find.text(t('sync.problem.auth')), findsOneWidget);
    expect(tester.widget<AppAlert>(find.byType(AppAlert)).severity, AlertSeverity.error);
  });

  testWidgets('syncs now when asked, but not while a sync runs', (tester) async {
    final kit = await _open(tester);
    await _turnOn(tester, kit);
    var requests = 0;
    kit.sync.onSyncRequest(() => requests++);

    await tapButton(tester, t('sync.now'));
    expect(requests, 1);

    kit.sync.setRunning(true);
    await tester.pump();
    expect(button(tester, t('sync.now')).enabled, isFalse);
    expect(find.bySemanticsLabel(t('sync.running')), findsOneWidget);

    kit.sync.setRunning(false);
    await tester.pump();
    expect(button(tester, t('sync.now')).enabled, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('closes', (tester) async {
    final kit = await _open(tester);
    await _turnOn(tester, kit);

    await tapButton(tester, t('export.close'));

    expect(find.byType(SyncSheet), findsNothing);
  });

  testWidgets('cancels without turning anything on', (tester) async {
    final kit = await _open(tester);
    await kit.fillDav(tester);

    await tapButton(tester, t('changePw.cancel'));

    expect(find.byType(SyncSheet), findsNothing);
    expect(kit.settings?.personal, isNull);
  });

  group('with sync running as in the app', () {
    testWidgets('uploads this device’s accounts once turned on, and says when', (tester) async {
      final kit = await _open(tester, syncHost: true);
      await kit.vault.applySynced(
        Lists(
          accounts: [OtpAccount(id: 'phone', issuer: 'GitHub', label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1)],
        ),
      );

      await _turnOn(tester, kit);

      final key = unb64(kit.settings!.personal!.key);
      final remote = await decryptSyncFile(kit.server.files[_path]!.text, key);
      expect(remote.accounts.map((a) => a.id), ['phone']);
      final when = syncTime(tester.element(find.byType(SyncSheet)), testNow.millisecondsSinceEpoch);
      expect(find.text(t('sync.status.synced', {'when': when})), findsOneWidget);
    });

    testWidgets('reports a problem instead of syncing, and keeps the local accounts', (tester) async {
      final kit = await _open(tester, syncHost: true);
      final account = OtpAccount(id: 'phone', issuer: 'GitHub', label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
      await kit.vault.applySynced(Lists(accounts: [account]));
      await _turnOn(tester, kit);

      kit.server.respond = (request) async => http.Response('', 401);
      await tapButton(tester, t('sync.now'));

      expect(find.text(t('sync.problem.auth')), findsOneWidget);
      expect(kit.container.read(syncProvider).status[personalScope]?.problem, SyncProblem.auth);
      expect(kit.vaultState.accounts.map((a) => a.id), ['phone']);
    });
  });

  // openspec: add-offline-mode, "Sync is paused" and "Setting up a server waits"
  group('while offline mode is on', () {
    testWidgets('setup says so and cannot connect', (tester) async {
      final kit = await _open(tester);
      await kit.setOffline(tester, true);

      expect(offlineAlert(t('sync.offline.setup')), findsOneWidget);
      await kit.fillDav(tester);
      await tester.enterText(field(t('sync.field.passphrase')), 'shared secret phrase');
      await tester.pump();
      expect(button(tester, t('sync.connect')).onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(kit.server.requests, isEmpty);
      expect(kit.settings?.personal, isNull);

      await kit.setOffline(tester, false);
      expect(offlineAlert(t('sync.offline.setup')), findsNothing);
      expect(button(tester, t('sync.connect')).onPressed, isNotNull);
    });

    testWidgets('a vault that syncs says sync is paused, keeps the last sync on show and cannot sync now', (tester) async {
      final kit = await _open(tester);
      await _turnOn(tester, kit);
      kit.sync.setScopeStatus(personalScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.setOffline(tester, true);
      kit.server.requests.clear();

      expect(offlineAlert(t('sync.offline')), findsOneWidget);
      final when = syncTime(tester.element(find.byType(SyncSheet)), testNow.millisecondsSinceEpoch);
      expect(find.text(t('sync.status.synced', {'when': when})), findsOneWidget);
      expect(button(tester, t('sync.now')).onPressed, isNull);
      expect(button(tester, t('sync.off')).onPressed, isNotNull, reason: 'turning sync off needs no network');
      expect(kit.container.read(syncProvider).status[personalScope]?.problem, isNull);
      expect(kit.server.requests, isEmpty);
    });

    testWidgets('"Network settings" closes the sheet', (tester) async {
      final kit = await _open(tester);
      await kit.setOffline(tester, true);

      await tapButton(tester, t('offline.settings'));

      expect(find.byType(SyncSheet), findsNothing);
    });
  });
}
