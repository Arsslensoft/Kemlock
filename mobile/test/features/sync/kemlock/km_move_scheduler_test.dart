// The scheduler while a move is unfinished (move-off-vaultwarden-sync, task 3.5): the vault's own entries
// wait, the spaces keep syncing, and everything runs again once the move is done.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/removal_guard.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../../vault/fast_kdf.dart';
import '../fake_webdav.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

const _dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');

class _Backend implements KemlockBackend {
  var calls = 0;

  @override
  Future<KmSyncResult> sync(KemlockTarget target, Lists local, ScopeState state, {required int now, RemovalChoice? choice}) async {
    calls++;
    return (doc: SyncDoc(accounts: local.accounts), known: local.ids.toList(), state: const <String, Object?>{}, skipped: 0);
  }

  @override
  void dispose() {}
}

class _Timer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

void main() {
  test('does not sync the vault’s own entries while a move is unfinished, keeps syncing a space, and syncs again after', () async {
    final folder = FakeWebDav();
    final kv = KeyValueStore.memory();
    final container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(WebDav(folder.client))],
    );
    addTearDown(container.dispose);
    final vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
    final session = await vault.setupVault('pw');
    final space = Space(
      id: 'team-1',
      name: 'Team',
      target: SyncTarget(dav: _dav, file: spaceFile('team-1'), key: b64(randomBytes(32))),
      joinedAt: 1,
    );
    await vault.saveEncryptedValue('backmycodes_sync', SyncSettings(kemlock: _target, personal: null, spaces: [space]).toJson(), session);
    final backend = _Backend();
    var moving = true;
    final scheduler = SyncScheduler(
      store: container.read(syncProvider.notifier),
      webDav: container.read(webDavProvider),
      session: session,
      getLists: () => const Lists(
        accounts: [OtpAccount(id: 'a', issuer: 'a', label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1)],
      ),
      applySynced: (lists) async {},
      kemlock: backend,
      ownEntriesPaused: () => moving,
      startTimer: (delay, callback) => _Timer(),
      startPeriodicTimer: (period, callback) => _Timer(),
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await scheduler.idle;

    expect(backend.calls, 0, reason: 'the vault’s own entries wait for the move');
    final status = container.read(syncProvider).status;
    expect(status[kemlockScope], isNull);
    expect(status['team-1']?.lastSyncAt, isNotNull, reason: 'the space still syncs');
    expect(status['team-1']?.problem, isNull);
    expect(folder.files.keys, contains('/files/me/Kemlock/${spaceFile('team-1')}'));

    moving = false;
    container.read(syncProvider.notifier).requestSync();
    await scheduler.idle;

    expect(backend.calls, 1);
    expect(container.read(syncProvider).status[kemlockScope]?.lastSyncAt, isNotNull);
  });
}
