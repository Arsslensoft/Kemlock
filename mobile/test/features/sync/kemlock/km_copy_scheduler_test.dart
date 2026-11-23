// The Bitwarden copy beside Kemlock Server sync (move-off-vaultwarden-sync, task 6.3): a copy whose session ended
// shows its problem on its own scope, and never stops or rolls back the Kemlock API's sync.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart' show VwError, VwProblem;
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
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

/// A copy whose Bitwarden session ended: its sync throws what the Vaultwarden sync throws.
class _SignedOutCopy extends VaultwardenBackend {
  _SignedOutCopy({required super.vault, required super.session}) : super(clientFor: _noClient);

  static http.Client _noClient(String? pin) => throw StateError('no network in this test');

  @override
  Future<VwSyncResult> sync(VaultwardenTarget target, Lists local, ScopeState state, {required int now, RemovalChoice? choice}) =>
      throw const VwError(VwProblem.signedOut);
}

void main() {
  test('a copy whose session ended shows its problem on its own line, and the Kemlock API keeps syncing', () async {
    final kv = KeyValueStore.memory();
    final container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(WebDav(FakeWebDav().client))],
    );
    addTearDown(container.dispose);
    final vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
    final session = await vault.setupVault('pw');
    await vault.saveEncryptedValue(
      'backmycodes_sync',
      const SyncSettings(
        kemlock: _target,
        vaultwarden: VaultwardenTarget(
          server: 'https://kem.example.com',
          email: 'me@example.com',
          home: 'home-1',
          mode: VaultwardenMode.plain,
          folderId: 'folder-1',
        ),
      ).toJson(),
      session,
    );
    final backend = _Backend();
    final scheduler = SyncScheduler(
      store: container.read(syncProvider.notifier),
      webDav: container.read(webDavProvider),
      session: session,
      getLists: () => const Lists(
        accounts: [OtpAccount(id: 'a', issuer: 'a', label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1)],
      ),
      applySynced: (lists) async {},
      kemlock: backend,
      vaultwarden: _SignedOutCopy(vault: vault, session: session),
      startTimer: (delay, callback) => _Timer(),
      startPeriodicTimer: (period, callback) => _Timer(),
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await scheduler.idle;

    final status = container.read(syncProvider).status;
    expect(status[vaultwardenScope]?.problem, SyncProblem.signedOut);
    expect(backend.calls, 1, reason: 'the Kemlock API synced');
    expect(status[kemlockScope]?.problem, isNull);
    expect(status[kemlockScope]?.lastSyncAt, isNotNull);
  });
}
