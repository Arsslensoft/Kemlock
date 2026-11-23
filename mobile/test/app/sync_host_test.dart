// Sync while offline mode is on (openspec: add-offline-mode, "Sync is paused" and "Turning offline
// mode off resumes everything"): the host as the app runs it, over the fake WebDAV folder.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../features/sync/sync_screen_kit.dart';

const _dav = DavAccount(url: folder, username: 'me', password: 'app-pw');
final _path = folderPath(syncFile);

OtpAccount _account(String id) => OtpAccount(id: id, issuer: id, label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

/// An open vault under the sync host, with sync to the fake folder set up
/// and its first sync done, unless the phone is [offline] from the start.
Future<({SyncSheetKit kit, String key})> _synced(WidgetTester tester, {bool offline = false}) async {
  final kit = SyncSheetKit();
  if (offline) kit.kv.setItem(keyOffline, '{"on":true}');
  await kit.pump(tester, (_) async {}, syncHost: true);
  final key = b64(randomBytes(32));
  await kit.save(
    SyncSettings(
      personal: SyncTarget(dav: _dav, file: syncFile, key: key),
    ),
  );
  await tester.pumpAndSettle();
  return (kit: kit, key: key);
}

void _setOffline(SyncSheetKit kit, bool on) => kit.container.read(offlineProvider.notifier).set(on);

/// The issuers of the accounts in the folder's sync file.
Future<List<String>> _remoteIds(SyncSheetKit kit, String key) async {
  final doc = await decryptSyncFile(kit.server.files[_path]!.text, unb64(key));
  return [for (final account in doc.accounts) account.issuer];
}

void main() {
  testWidgets('syncs as before while offline mode is off', (tester) async {
    final (:kit, :key) = await _synced(tester);

    expect(kit.server.requests, isNotEmpty);
    expect(await _remoteIds(kit, key), isEmpty);
    expect(kit.container.read(syncProvider).status[personalScope]?.lastSyncAt, isNotNull);
  });

  testWidgets('unlocking while offline makes no request, and still shows the settings', (tester) async {
    final (:kit, key: _) = await _synced(tester, offline: true);
    expect(kit.server.requests, isEmpty, reason: 'saving the settings asked for a sync');

    kit.vault.lock();
    await tester.pumpAndSettle();
    expect(kit.settings, isNull);
    await kit.vault.open(kit.session);
    await tester.pumpAndSettle();
    // Past the five-minute sync and a return to the front
    await tester.pump(const Duration(minutes: 6));
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();

    expect(kit.server.requests, isEmpty);
    expect(kit.settings?.personal, isNotNull);
    final sync = kit.container.read(syncProvider);
    expect(sync.running, isFalse);
    expect(sync.status.values.where((status) => status.problem != null), isEmpty);
  });

  testWidgets('turning offline mode on during a run stops it and leaves the vault as it was', (tester) async {
    final (:kit, :key) = await _synced(tester);
    final syncedAt = kit.container.read(syncProvider).status[personalScope]?.lastSyncAt;
    kit.server.put(_path, await encryptSyncFile(SyncDoc(accounts: [_account('other-phone')]), unb64(key)));
    kit.server.requests.clear();
    final held = Completer<void>();
    kit.server.respond = (request) async {
      await held.future;
      return kit.server.handle(request);
    };

    kit.sync.requestSync();
    await tester.pump();
    expect(kit.container.read(syncProvider).running, isTrue);
    _setOffline(kit, true);
    await tester.pump();
    expect(kit.container.read(syncProvider).running, isFalse);
    kit.server.respond = null;
    held.complete();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 6));

    expect(kit.vaultState.accounts, isEmpty);
    expect(kit.server.requests.map((r) => r.method), ['GET'], reason: 'only the read that was under way');
    final sync = kit.container.read(syncProvider);
    expect(sync.settings?.personal, isNotNull);
    expect(sync.status[personalScope], ScopeStatus(lastSyncAt: syncedAt));
  });

  testWidgets('an account added while offline reaches the server once offline mode is turned off', (tester) async {
    final (:kit, :key) = await _synced(tester);
    _setOffline(kit, true);
    await tester.pump();
    kit.server.requests.clear();

    await kit.vault.addAccount(_account('added-offline'));
    await tester.pump(const Duration(seconds: 10));
    kit.sync.requestSync();
    await tester.pumpAndSettle();
    expect(kit.server.requests, isEmpty);
    expect(await _remoteIds(kit, key), isEmpty);
    expect(kit.vaultState.accounts.map((a) => a.issuer), ['added-offline']);

    _setOffline(kit, false);
    await tester.pumpAndSettle();

    expect(await _remoteIds(kit, key), ['added-offline']);
    expect(kit.container.read(syncProvider).status[personalScope]?.problem, isNull);
  });

  testWidgets('locking while paused forgets the settings, as locking does', (tester) async {
    final (:kit, key: _) = await _synced(tester);
    _setOffline(kit, true);
    await tester.pump();

    kit.vault.lock();
    await tester.pumpAndSettle();

    expect(kit.settings, isNull);
  });

  testWidgets('a request that slips past the host is still refused by the gate', (tester) async {
    final (:kit, key: _) = await _synced(tester, offline: true);
    final gated = GatedClient(() => kit.server.client, kit.container.read(networkGateProvider));

    await expectLater(WebDav(gated).readFile(_dav, syncFile), throwsA(isA<DavError>()));

    expect(kit.server.requests, isEmpty);
  });
}
