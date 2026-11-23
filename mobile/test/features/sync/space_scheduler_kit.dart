// A scheduler on a phone that holds a WebDAV space, for the tests of a moved space's life on one phone (docs/plans/add-server-spaces.md,
// tasks 8.3 and 8.4): the phone's vault, its settings, the fake folder and the fake server through the real server-space source,
// and a scheduler whose timers the test drives.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/space_bridge.dart' show JoinOffer;
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

import '../../vault/fast_kdf.dart';

/// The Kemlock account the phone signs in as: its settings name it, and the scheduler hands it on to the space source.
const rigTarget = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'sam@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

/// The server spaces of the phone, through the real source over the fake server, which counts what it was asked and can be
/// told to answer as the list does when a space is not confirmed.
class RigSpaces implements KemlockSpacesBackend {
  RigSpaces(this.source);

  final KmServerSpaces source;

  /// When set, the ids the list answers instead of the server's own.
  List<String>? confirmedOverride;

  /// Thrown by the list while set, as a server that can't be reached.
  Object? listFailure;

  /// The space of each run, in order.
  final runs = <String>[];

  /// Runs inside a space's run, as a change the person or another writer makes while it goes.
  Future<void> Function()? duringRun;

  /// Whether each of those runs was a joining one, and the spaces the phone asked an offer for.
  final joinRuns = <bool>[];
  final offers = <String>[];

  var lists = 0;

  @override
  Future<List<String>> confirmedSpaces(KemlockTarget target) async {
    lists++;
    if (listFailure case final failure?) {
      throw failure;
    }
    return confirmedOverride ?? await source.confirmedSpaces();
  }

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
    joinRuns.add(joining);
    await duringRun?.call();
    return source.syncSpace(space, local, state, now: now, choice: choice, joining: joining, bridged: bridged);
  }

  @override
  Future<JoinOffer?> joinOffer(KemlockTarget target, String space, {required int now}) {
    offers.add(space);
    return source.joinOffer(space, now: now);
  }
}

class _Timer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

/// One phone with its scheduler.
class SchedulerRig {
  SchedulerRig(this.container, this.spaces);

  final ProviderContainer container;
  final RigSpaces spaces;
  late final SyncScheduler scheduler;
  late final VaultSession session;
  late final VaultStore vault;

  /// The phone's entries, which the scheduler reads and writes as the vault does.
  Lists lists = const Lists();

  /// The clock the scheduler uses, in ms.
  var clock = 10000;

  SyncNotifier get store => container.read(syncProvider.notifier);

  Map<String, ScopeStatus> get status => container.read(syncProvider).status;

  SyncSettings get settings => container.read(syncProvider).settings!;

  /// The account [id] of the phone's entries.
  OtpAccount account(String id) => lists.accounts.firstWhere((account) => account.id == id);

  /// The space [id] as the settings hold it now.
  Space space(String id) => settings.spaces.firstWhere((space) => space.id == id);

  /// Syncs once, as Sync now does, and waits for it and for any run it queued.
  Future<void> sync() async {
    clock += 1000;
    store.requestSync();
    await scheduler.idle;
  }
}

/// Opens a phone whose vault holds [settings], the entries [lists] and what each scope kept ([states]), and syncs once, as a vault
/// does when it opens. The test calls `sync()` for the runs after it.
Future<SchedulerRig> openRig({
  required SyncSettings settings,
  required KmServerSpaces source,
  required WebDav webDav,
  Lists lists = const Lists(),
  Map<String, ScopeState> states = const {},
  void Function(RigSpaces spaces)? configure,
}) async {
  final kv = KeyValueStore.memory();
  final container = ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(webDav)]);
  final rig = RigSpaces(source);
  configure?.call(rig);
  final s = SchedulerRig(container, rig);
  addTearDown(() {
    s.scheduler.dispose();
    container.dispose();
  });
  s.vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  s.session = await s.vault.setupVault('pw');
  await s.vault.saveEncryptedValue('backmycodes_sync', settings.toJson(), s.session);
  s
    ..lists = lists
    ..scheduler = SyncScheduler(
      store: s.store,
      webDav: webDav,
      session: s.session,
      getLists: () => s.lists,
      applySynced: (next) async => s.lists = next,
      serverSpaces: rig,
      clock: () => DateTime.fromMillisecondsSinceEpoch(s.clock),
      startTimer: (delay, callback) => _Timer(),
      startPeriodicTimer: (period, callback) => _Timer(),
    );
  if (states.isNotEmpty) {
    await s.store.saveScopeStates(states, s.session);
  }
  // Loads the settings and syncs once, as a vault does when it opens
  await s.scheduler.start();
  await s.scheduler.idle;
  return s;
}
