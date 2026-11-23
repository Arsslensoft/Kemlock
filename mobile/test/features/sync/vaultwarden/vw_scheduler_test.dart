// The scheduler running Vaultwarden sync for an open vault, beside WebDAV:
// what it takes, the state it keeps, the problems it shows, and the
// removal guard's answer.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../../vault/fast_kdf.dart';
import '../fake_webdav.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

OtpAccount _acct(String id, String secret) => OtpAccount(id: id, issuer: id, label: '', secret: secret, addedAt: 1);

const _secrets = ['JBSWY3DPEHPK3PXP', 'KRSXG5CTMVRXEZLU', 'GEZDGNBVGY3TQOJQ', 'MFRGGZDFMZTWQ2LK', 'NBSWY3DPO5XXE3DE', 'ONSWG4TFOQYTEMZU'];

class _Setup {
  _Setup(this.container, this.server, this.session, this.backend);

  final ProviderContainer container;
  final FakeVaultwarden server;
  final VaultSession session;
  final VaultwardenBackend backend;
  late final SyncScheduler scheduler;
  Lists lists = const Lists();

  SyncNotifier get store => container.read(syncProvider.notifier);
  ScopeStatus? get status => container.read(syncProvider).status[vaultwardenScope];
}

Future<_Setup> _setup({required List<OtpAccount> local, bool signedIn = true}) async {
  final kv = KeyValueStore.memory();
  final server = FakeVaultwarden();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(WebDav(FakeWebDav().client))],
  );
  addTearDown(container.dispose);
  final vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  final session = await vault.setupVault('pw');
  final target = await makeHome(server, VaultwardenMode.sealed);
  await vault.saveEncryptedValue('backmycodes_sync', SyncSettings(vaultwarden: target).toJson(), session);
  final backend = VaultwardenBackend(vault: vault, session: session, clientFor: (_) => server.newClient());
  if (signedIn) await backend.saveCredentials(server.credentials());

  final s = _Setup(container, server, session, backend)..lists = Lists(accounts: local);
  var clock = DateTime.utc(2026, 11, 7, 10);
  s.scheduler = SyncScheduler(
    store: s.store,
    webDav: container.read(webDavProvider),
    session: session,
    getLists: () => s.lists,
    applySynced: (lists) async => s.lists = lists,
    vaultwarden: backend,
    clock: () => clock = clock.add(const Duration(seconds: 1)),
    startTimer: (delay, callback) => _NoTimer(),
    startPeriodicTimer: (period, callback) => _NoTimer(),
  );
  addTearDown(s.scheduler.dispose);
  await s.scheduler.start();
  await s.scheduler.idle;
  return s;
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

void main() {
  test('syncs the vault with Vaultwarden when it opens, and keeps the state for next time', () async {
    final s = await _setup(local: [_acct('phone', _secrets[0])]);

    expect(s.status?.lastSyncAt, isNotNull);
    expect(s.status?.problem, isNull);
    expect(s.server.ciphers.length, 2, reason: 'the home and the entry');

    // The second run reads everything once more after its own writes; the third only asks the revision date
    s.store.requestSync();
    await s.scheduler.idle;
    s.server.requests.clear();
    s.store.requestSync();
    await s.scheduler.idle;
    expect(s.server.requests.map((r) => r.url.path), ['/api/accounts/revision-date']);
  });

  test('takes what another phone put in Vaultwarden', () async {
    final s = await _setup(local: [_acct('phone', _secrets[0])]);
    final target = s.container.read(syncProvider).settings!.vaultwarden!;
    final writer = VwWriter(userKey: s.server.userKey, userId: FakeVaultwarden.userId);
    s.server.put(
      await writer.create(
        _acct('tablet', _secrets[1]),
        form: VaultwardenMode.sealed,
        home: target.home,
        folderId: target.folderId,
        sealKey: unb64(target.seal!.key),
      ),
    );

    s.store.requestSync();
    await s.scheduler.idle;

    expect([for (final account in s.lists.accounts) account.id]..sort(), ['phone', 'tablet']);
  });

  test('shows a signed-out problem when there is no session', () async {
    final s = await _setup(local: [_acct('phone', _secrets[0])], signedIn: false);

    expect(s.status?.problem, SyncProblem.signedOut);
    expect(s.server.ciphers.length, 1, reason: 'only the home');
  });

  test('stops before removing many entries, and syncs once the user decides', () async {
    final s = await _setup(local: [for (var i = 0; i < 6; i++) _acct('a$i', _secrets[i])]);
    // Vaultwarden loses most of them
    final entries = s.server.ciphers.keys.toList().sublist(1, 6);
    entries.forEach(s.server.purge);

    s.store.requestSync();
    await s.scheduler.idle;
    expect(s.status?.problem, SyncProblem.removals);
    expect(s.status?.count, 5);
    expect(s.lists.accounts, hasLength(6));

    s.store.decideRemovals(RemovalChoice.keep);
    await s.scheduler.idle;
    expect(s.status?.problem, isNull);
    expect(s.lists.accounts, hasLength(6));
    expect(s.store.removalChoice, isNull);
    expect(s.server.ciphers.length, 7, reason: 'the missing ones went back up');
  });
}
