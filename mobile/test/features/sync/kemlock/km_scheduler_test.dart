// The scheduler running Kemlock Server sync for an open vault: it runs on open,
// after a change settles, on coming to the front, every period and on "Sync
// now"; a run that raced the user's change is redone; and WebDAV and Kemlock
// Server both holding the vault's own entries pauses both.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart' show RemovalChoice;
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../../vault/fast_kdf.dart';

OtpAccount _acct(String id) => OtpAccount(id: id, issuer: id, label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

const _dav = SyncTarget(
  dav: DavAccount(url: 'https://dav.example.com/', username: 'me', password: 'pw'),
  file: syncFile,
  key: 'AAAA',
);

/// A backend that answers from a script, and counts and records its calls.
class _Backend implements KemlockBackend {
  var calls = 0;
  var disposed = false;
  final choices = <RemovalChoice?>[];
  final states = <ScopeState>[];

  /// Held while set, so a test can act while a run is going.
  Completer<void>? gate;

  /// What the run adds to the vault's accounts.
  List<OtpAccount> add = const [];

  @override
  Future<KmSyncResult> sync(KemlockTarget target, Lists local, ScopeState state, {required int now, RemovalChoice? choice}) async {
    calls++;
    choices.add(choice);
    states.add(state);
    await gate?.future;
    final doc = SyncDoc(accounts: [...local.accounts, ...add]);
    return (doc: doc, known: doc.ids.toList(), state: {'cursor': 'c$calls'}, skipped: 2);
  }

  @override
  void dispose() => disposed = true;
}

class _Timer implements Timer {
  _Timer(this.callback);

  final void Function() callback;
  var cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

class _Setup {
  _Setup(this.container, this.backend);

  final ProviderContainer container;
  final _Backend backend;
  late final SyncScheduler scheduler;
  late final VaultSession session;
  late final VaultStore vault;
  Lists lists = const Lists();
  final settleTimers = <_Timer>[];
  void Function(Timer)? period;

  SyncNotifier get store => container.read(syncProvider.notifier);
  ScopeStatus? get status => container.read(syncProvider).status[kemlockScope];
}

Future<_Setup> _setup({SyncSettings? settings, List<OtpAccount> local = const [], bool start = true}) async {
  final kv = KeyValueStore.memory();
  final container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      webDavProvider.overrideWithValue(WebDav(MockClient((_) async => http.Response('', 500)))),
    ],
  );
  addTearDown(container.dispose);
  final backend = _Backend();
  final s = _Setup(container, backend);
  s.vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  s.session = await s.vault.setupVault('pw');
  await s.vault.saveEncryptedValue('backmycodes_sync', (settings ?? const SyncSettings(kemlock: _target)).toJson(), s.session);
  s
    ..lists = Lists(accounts: local)
    ..scheduler = SyncScheduler(
      store: s.store,
      webDav: container.read(webDavProvider),
      session: s.session,
      getLists: () => s.lists,
      applySynced: (lists) async => s.lists = lists,
      kemlock: backend,
      startTimer: (delay, callback) {
        final timer = _Timer(callback);
        s.settleTimers.add(timer);
        return timer;
      },
      startPeriodicTimer: (period, callback) {
        s.period = callback;
        return _Timer(() {});
      },
    );
  addTearDown(s.scheduler.dispose);
  if (start) {
    await s.scheduler.start();
    await s.scheduler.idle;
  }
  return s;
}

void main() {
  test('syncs the vault with Kemlock Server when it opens, and keeps what the run returned', () async {
    final s = await _setup(local: [_acct('a')]);

    expect(s.backend.calls, 1);
    expect(s.status?.lastSyncAt, isNotNull);
    expect(s.status?.problem, isNull);
    expect(s.status?.count, 2, reason: 'what the run left alone is shown');
    final states = await s.store.loadScopeStates(s.session);
    expect(states[kemlockScope]?.extra, {'cursor': 'c1'});
    expect(states[kemlockScope]?.known, ['a']);
  });

  test('gives the next run the state the last one kept', () async {
    final s = await _setup(local: [_acct('a')]);

    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.backend.calls, 2);
    expect(s.backend.states.last.extra, {'cursor': 'c1'});
  });

  test('runs on Sync now, when the app comes to the front, every period, and a moment after a change', () async {
    final s = await _setup(local: [_acct('a')]);

    s.store.requestSync();
    await s.scheduler.idle;
    expect(s.backend.calls, 2, reason: 'Sync now');

    s.scheduler.setVisible(false);
    s.scheduler.setVisible(true);
    await s.scheduler.idle;
    expect(s.backend.calls, 3, reason: 'front');

    s.period!(_Timer(() {}));
    await s.scheduler.idle;
    expect(s.backend.calls, 4, reason: 'the period');

    s.scheduler.userChanged();
    s.settleTimers.last.callback();
    await s.scheduler.idle;
    expect(s.backend.calls, 5, reason: 'settled');
  });

  test('does not run on the period while the app is behind', () async {
    final s = await _setup(local: [_acct('a')]);
    s.scheduler.setVisible(false);
    await s.scheduler.idle;

    s.period!(_Timer(() {}));
    await s.scheduler.idle;

    expect(s.backend.calls, 1);
  });

  test('a run that raced a change the user made is thrown away and redone', () async {
    final s = await _setup(local: [_acct('a')]);
    s.backend
      ..gate = Completer<void>()
      ..add = [_acct('remote')];

    s.store.requestSync();
    await Future<void>.delayed(Duration.zero);
    s.scheduler.userChanged();
    s.backend.gate!.complete();
    await s.scheduler.idle;

    expect(s.backend.calls, 3, reason: 'the open, the raced run and its redo');
    expect(s.lists.accounts.map((a) => a.id), contains('remote'));
  });

  test('gives the removal choice to the run, and forgets it once a run used it', () async {
    final s = await _setup(local: [_acct('a')]);

    s.store.decideRemovals(RemovalChoice.keep);
    await s.scheduler.idle;

    expect(s.backend.choices.last, RemovalChoice.keep);
    expect(s.store.removalChoice, isNull);
  });

  test('lets the backend go when the scheduler is disposed', () async {
    final s = await _setup(local: [_acct('a')]);

    s.scheduler.dispose();

    expect(s.backend.disposed, isTrue);
  });

  test('WebDAV and Kemlock Server both holding the vault’s own entries pause both', () async {
    final s = await _setup(
      settings: const SyncSettings(personal: _dav, kemlock: _target),
      local: [_acct('a')],
    );

    expect(s.backend.calls, 0);
    expect(s.container.read(syncProvider).status, isEmpty);
  });
}
