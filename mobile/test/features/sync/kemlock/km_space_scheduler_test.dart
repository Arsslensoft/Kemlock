// The scheduler running the server spaces of a vault signed in to Kemlock Server (docs/plans/add-server-spaces.md,
// "Server spaces as a sync scope"): each space the account is a confirmed member of is a scope under its UUID, run on
// open, on settle, in front, on the period and on Sync now, as the vault's own Kemlock scope is; paused while a move off
// Vaultwarden runs; its problems go into the sync problems; and a space that stops, because its chain fails to verify or
// its keys are being replaced, stops alone.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/spaces/server_spaces.dart' show SpaceSyncError, SpaceSyncIssue;
import 'package:kemlock/features/spaces/space_bridge.dart' show JoinOffer;
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/removal_guard.dart' show RemovalChoice;
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../../vault/fast_kdf.dart';

const _spaceA = '00000000-0000-4000-8000-0000000000a1';
const _spaceB = '00000000-0000-4000-8000-0000000000b2';
const _spaceC = '00000000-0000-4000-8000-0000000000c3';

OtpAccount _acct(String id, {String? spaceId}) =>
    OtpAccount(id: id, issuer: id, label: '', secret: 'JBSWY3DPEHPK3PXP', spaceId: spaceId, addedAt: 1);

List<String> _ids(Lists lists) => [for (final account in lists.accounts) account.id]..sort();

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

/// The vault's own Kemlock scope, which answers from a script and counts its calls.
class _Backend implements KemlockBackend {
  var calls = 0;
  Object? failure;
  final choices = <RemovalChoice?>[];

  @override
  Future<KmSyncResult> sync(KemlockTarget target, Lists local, ScopeState state, {required int now, RemovalChoice? choice}) async {
    calls++;
    choices.add(choice);
    if (failure case final failure?) {
      throw failure;
    }
    final doc = SyncDoc(accounts: local.accounts);
    return (doc: doc, known: doc.ids.toList(), state: {'cursor': 'own$calls'}, skipped: 0);
  }

  @override
  void dispose() {}
}

/// The server spaces, which answer from a script and record each call.
class _Spaces implements KemlockSpacesBackend {
  /// The spaces the server lists as confirmed.
  List<String> confirmed = const [];

  /// Thrown by the list.
  Object? listFailure;

  /// Thrown by the run of a space.
  final failures = <String, Object>{};

  /// Held while set, so a test can act while a space's run is going.
  Completer<void>? gate;

  /// What a space's run adds to the vault's accounts.
  final added = <String, List<OtpAccount>>{};

  var lists = 0;

  /// The space of each run, in order.
  final runs = <String>[];

  /// The entries a space's run was given, and the state, by space.
  final locals = <String, Lists>{};
  final states = <String, ScopeState>{};
  final choices = <RemovalChoice?>[];

  @override
  Future<List<String>> confirmedSpaces(KemlockTarget target) async {
    lists++;
    if (listFailure case final failure?) {
      throw failure;
    }
    return confirmed;
  }

  @override
  Future<JoinOffer?> joinOffer(KemlockTarget target, String space, {required int now}) async => null;

  @override
  Future<KmSyncResult> syncSpace(
    KemlockTarget target,
    String space,
    Lists local,
    ScopeState state, {
    required int now,
    RemovalChoice? choice,
    bool joining = false,
    bool bridged = false,
  }) async {
    runs.add(space);
    locals[space] = local;
    states[space] = state;
    choices.add(choice);
    await gate?.future;
    if (failures[space] case final failure?) {
      throw failure;
    }
    final doc = SyncDoc(accounts: [...local.accounts, ...?added[space]]);
    return (doc: doc, known: doc.ids.toList(), state: {'cursor': '$space#${runs.length}'}, skipped: 1);
  }
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
  _Setup(this.container, this.backend, this.spaces);

  final ProviderContainer container;
  final _Backend backend;
  final _Spaces spaces;
  late final SyncScheduler scheduler;
  late final VaultSession session;
  late final VaultStore vault;
  Lists lists = const Lists();
  var moving = false;
  final settleTimers = <_Timer>[];
  void Function(Timer)? period;

  SyncNotifier get store => container.read(syncProvider.notifier);
  Map<String, ScopeStatus> get status => container.read(syncProvider).status;
}

Future<_Setup> _setup({
  SyncSettings? settings,
  List<OtpAccount> local = const [],
  List<String> confirmed = const [_spaceA],
  bool start = true,
}) async {
  final kv = KeyValueStore.memory();
  final container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      webDavProvider.overrideWithValue(WebDav(MockClient((_) async => http.Response('', 500)))),
    ],
  );
  addTearDown(container.dispose);
  final backend = _Backend();
  final spaces = _Spaces()..confirmed = confirmed;
  final s = _Setup(container, backend, spaces);
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
      serverSpaces: spaces,
      ownEntriesPaused: () => s.moving,
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
  test('syncs each confirmed space in its own scope when the vault opens, and keeps what each run returned', () async {
    final s = await _setup(
      confirmed: const [_spaceA, _spaceB],
      local: [
        _acct('mine'),
        _acct('a1', spaceId: _spaceA),
        _acct('b1', spaceId: _spaceB),
      ],
    );
    s.spaces.added[_spaceA] = [_acct('a2', spaceId: _spaceA)];

    // The run on open found nothing to add; the next one takes what the space now holds
    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.spaces.runs, [_spaceA, _spaceB, _spaceA, _spaceB]);
    expect(_ids(s.spaces.locals[_spaceA]!), ['a1'], reason: 'only the space’s own entries');
    expect(_ids(s.spaces.locals[_spaceB]!), ['b1']);
    expect(_ids(s.lists), ['a1', 'a2', 'b1', 'mine'], reason: 'what the space’s run returned is taken into the vault');
    expect(s.lists.accounts.firstWhere((account) => account.id == 'a2').spaceId, _spaceA);
    final states = await s.store.loadScopeStates(s.session);
    expect(states[_spaceA]?.known, unorderedEquals(['a1', 'a2']));
    expect(states[_spaceB]?.known, ['b1']);
    expect(states[_spaceA]?.extra, {'cursor': '$_spaceA#3'});
    expect(s.status[_spaceA]?.lastSyncAt, isNotNull);
    expect(s.status[_spaceA]?.problem, isNull);
    expect(s.status[_spaceA]?.count, 1, reason: 'what the run left alone is shown');
    expect(s.backend.calls, 2, reason: 'the vault’s own Kemlock scope runs beside them');
  });

  test('gives a space the state its last run kept', () async {
    final s = await _setup(local: [_acct('a1', spaceId: _spaceA)]);

    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.spaces.states[_spaceA]?.extra, {'cursor': '$_spaceA#1'});
    expect(s.spaces.runs, hasLength(2));
  });

  test('runs a space on Sync now, when the app comes to the front, every period, and a moment after a change', () async {
    final s = await _setup(local: [_acct('a1', spaceId: _spaceA)]);
    expect(s.spaces.runs, hasLength(1), reason: 'on open');

    s.store.requestSync();
    await s.scheduler.idle;
    expect(s.spaces.runs, hasLength(2), reason: 'Sync now');

    s.scheduler.setVisible(false);
    s.scheduler.setVisible(true);
    await s.scheduler.idle;
    expect(s.spaces.runs, hasLength(3), reason: 'front');

    s.period!(_Timer(() {}));
    await s.scheduler.idle;
    expect(s.spaces.runs, hasLength(4), reason: 'the period');

    s.scheduler.userChanged();
    s.settleTimers.last.callback();
    await s.scheduler.idle;
    expect(s.spaces.runs, hasLength(5), reason: 'settled');
  });

  test('does not run a space on the period while the app is behind', () async {
    final s = await _setup();
    s.scheduler.setVisible(false);
    await s.scheduler.idle;

    s.period!(_Timer(() {}));
    await s.scheduler.idle;

    expect(s.spaces.runs, hasLength(1));
  });

  test('leaves out a space the server doesn’t list as confirmed, such as an invitation or a space the account left', () async {
    final s = await _setup(confirmed: const [], local: [_acct('mine')]);

    expect(s.spaces.lists, 1, reason: 'the list is read');
    expect(s.spaces.runs, isEmpty);
    expect(s.backend.calls, 1);
  });

  test('runs no space for a vault that is not signed in to Kemlock Server', () async {
    final s = await _setup(
      settings: const SyncSettings(
        personal: SyncTarget(
          dav: DavAccount(url: 'https://dav.example.com/', username: 'me', password: 'pw'),
          file: syncFile,
          key: 'AAAA',
        ),
      ),
    );

    expect(s.spaces.lists, 0);
    expect(s.spaces.runs, isEmpty);
    expect(s.backend.calls, 0);
  });

  test('leaves a space with a WebDAV space’s id to its WebDAV scope, and ignores an id that is not a UUID', () async {
    final s = await _setup(
      settings: const SyncSettings(
        kemlock: _target,
        spaces: [
          Space(
            id: _spaceA,
            name: 'Family',
            target: SyncTarget(
              dav: DavAccount(url: 'https://dav.example.com/', username: 'me', password: 'pw'),
              file: 'backmycodes-space-$_spaceA.json',
              key: 'AAAA',
            ),
            joinedAt: 1,
          ),
        ],
      ),
      confirmed: const [_spaceA, 'personal', 'not-a-space', _spaceB],
    );

    // _spaceA is the WebDAV space’s UUID as well: the server’s word alone joins nothing (the fake offers no merge), and no scope
    // of its own is made for it
    expect(s.spaces.runs, [_spaceB]);
    expect(s.status[_spaceA]?.problem, isNotNull, reason: 'the WebDAV scope ran under that id, and the fake folder refuses');
  });

  test('waits while a move off Vaultwarden runs, and syncs the spaces once it is over', () async {
    final s = await _setup(local: [_acct('a1', spaceId: _spaceA)], start: false);
    s.moving = true;
    await s.scheduler.start();
    await s.scheduler.idle;

    expect(s.backend.calls, 0, reason: 'the vault’s own entries wait for the move');
    expect(s.spaces.lists, 0, reason: 'so do the spaces');
    expect(s.spaces.runs, isEmpty);
    expect(s.status[_spaceA], isNull);

    s.moving = false;
    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.backend.calls, 1);
    expect(s.spaces.runs, [_spaceA]);
    expect(s.status[_spaceA]?.lastSyncAt, isNotNull);
  });

  test('puts each space’s problem into the sync problems, under its own scope, and keeps when it last synced', () async {
    final s = await _setup(confirmed: const [_spaceA, _spaceB, _spaceC], local: [_acct('mine')]);
    final syncedAt = s.status[_spaceA]?.lastSyncAt;
    expect(syncedAt, isNotNull);

    s.spaces.failures[_spaceA] = const SpaceSyncError(SpaceSyncIssue.cantBeChecked);
    s.spaces.failures[_spaceB] = const SpaceSyncError(SpaceSyncIssue.keysPending);
    s.spaces.failures[_spaceC] = const KmError(KmProblem.network);
    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.status[_spaceA]?.problem, SyncProblem.spaceCantBeChecked);
    expect(s.status[_spaceB]?.problem, SyncProblem.spaceKeysPending);
    expect(s.status[_spaceC]?.problem, SyncProblem.network);
    expect(s.status[_spaceA]?.lastSyncAt, syncedAt, reason: 'the last run that went through is still shown');
    expect(s.status[kemlockScope]?.problem, isNull, reason: 'the vault’s own scope is no worse for them');

    // Once the keys are replaced, the next run goes through
    s.spaces.failures.remove(_spaceB);
    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.status[_spaceB]?.problem, isNull);
    expect(s.status[_spaceA]?.problem, SyncProblem.spaceCantBeChecked);
  });

  test('a space whose chain fails to verify stops alone: the vault’s own scope and the other spaces sync, and its entries stay', () async {
    final s = await _setup(
      confirmed: const [_spaceA, _spaceB],
      local: [
        _acct('mine'),
        _acct('a1', spaceId: _spaceA),
        _acct('b1', spaceId: _spaceB),
      ],
      start: false,
    );
    s.spaces.failures[_spaceA] = const SpaceSyncError(SpaceSyncIssue.cantBeChecked);
    s.spaces.added[_spaceB] = [_acct('b2', spaceId: _spaceB)];
    await s.scheduler.start();
    await s.scheduler.idle;

    expect(s.backend.calls, 1, reason: 'the vault’s own scope ran');
    expect(s.status[kemlockScope]?.problem, isNull);
    expect(s.status[kemlockScope]?.lastSyncAt, isNotNull);
    expect(s.spaces.runs, [_spaceA, _spaceB], reason: 'the space after it still ran');
    expect(s.status[_spaceA]?.problem, SyncProblem.spaceCantBeChecked);
    expect(s.status[_spaceB]?.problem, isNull);
    expect(_ids(s.lists), ['a1', 'b1', 'b2', 'mine'], reason: 'nothing of the stopped space changed, and the other one’s run was taken');
  });

  test('a space whose keys are being replaced stops with its problem and does not block the vault’s own scope', () async {
    final s = await _setup(
      local: [
        _acct('mine'),
        _acct('a1', spaceId: _spaceA),
      ],
      start: false,
    );
    s.spaces.failures[_spaceA] = const SpaceSyncError(SpaceSyncIssue.keysPending);
    await s.scheduler.start();
    await s.scheduler.idle;

    expect(s.status[_spaceA]?.problem, SyncProblem.spaceKeysPending);
    expect(s.backend.calls, 1);
    expect(s.status[kemlockScope]?.lastSyncAt, isNotNull);
    expect(_ids(s.lists), ['a1', 'mine']);
  });

  test('a vault’s own scope that fails does not stop the spaces', () async {
    final s = await _setup(local: [_acct('a1', spaceId: _spaceA)], start: false);
    s.backend.failure = const KmError(KmProblem.network);
    await s.scheduler.start();
    await s.scheduler.idle;

    expect(s.status[kemlockScope]?.problem, SyncProblem.network);
    expect(s.spaces.runs, [_spaceA]);
    expect(s.status[_spaceA]?.problem, isNull);
  });

  test('a list of spaces that can’t be read shows its problem, runs no space, and leaves the vault’s own scope alone', () async {
    final s = await _setup(local: [_acct('mine')], start: false);
    s.spaces.listFailure = const KmError(KmProblem.sessionEnded, reason: 'signed-out');
    await s.scheduler.start();
    await s.scheduler.idle;

    expect(s.status[kemlockSpacesScope]?.problem, SyncProblem.sessionEnded);
    expect(s.spaces.runs, isEmpty);
    expect(s.backend.calls, 1);

    s.spaces.listFailure = null;
    s.store.requestSync();
    await s.scheduler.idle;

    expect(s.status[kemlockSpacesScope]?.problem, isNull);
    expect(s.spaces.runs, [_spaceA]);
  });

  test('keeps the removal choice for the vault’s own entries: a space’s run never gets it', () async {
    final s = await _setup(local: [_acct('mine')]);

    s.store.decideRemovals(RemovalChoice.keep);
    await s.scheduler.idle;

    expect(s.backend.choices.last, RemovalChoice.keep);
    expect(s.spaces.choices.every((choice) => choice == null), isTrue);
    expect(s.spaces.runs, hasLength(2));
  });

  test('a run that raced a change the user made is thrown away, and the spaces are run again with it', () async {
    final s = await _setup(local: [_acct('a1', spaceId: _spaceA)]);
    final before = s.spaces.runs.length;
    s.spaces
      ..gate = Completer<void>()
      ..added[_spaceA] = [_acct('a2', spaceId: _spaceA)];

    s.store.requestSync();
    // The run reaches the space's run, which waits at the gate
    for (var i = 0; i < 50 && s.spaces.runs.length == before; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    s.scheduler.userChanged();
    s.spaces.gate!.complete();
    await s.scheduler.idle;

    expect(s.spaces.runs.length, before + 2, reason: 'the raced run and its redo');
    expect(_ids(s.lists), ['a1', 'a2']);
  });
}
