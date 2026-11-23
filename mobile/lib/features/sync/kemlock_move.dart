/// The move off Vaultwarden or WebDAV sync as the open vault runs it (move-off-vaultwarden-sync, designs 5 and
/// 9, tasks 3.5, 5.1, 5.3 and 8): the sealed record's state for the screens and the scheduler, the move
/// itself over the Kemlock host's session, and "Go back to Vaultwarden".
///
/// [kemlockMoveProvider] holds the record as the vault has it. The scheduler asks it whether the vault's own
/// entries wait ([KmMoveState.pausesSync]): they do while the record isn't loaded and while a move is
/// unfinished. Confirming the move saves the record first and the Kemlock target second, so no sync of the
/// vault's own entries can run in between. The run is held here, not by a sheet, so leaving the screen
/// doesn't stop it; a move that stopped resumes at the next opening of the vault ([KemlockMove.resume]) or
/// at Try again.
///
/// [kemlockMoveRunProvider] is the one place that reaches the network and the vault; tests of the screens
/// override it with a fake run.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/public_suffixes.dart';
import '../../models/json.dart';
import '../../platform/network.dart';
import '../../vault/attachment_store.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart' show VaultSession;
import '../backup/two_factor_directory.dart';
import '../duplicates/duplicate_sites.dart';
import 'attachment_sync.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_dedup.dart';
import 'kemlock/km_models.dart';
import 'kemlock/km_move.dart';
import 'kemlock/km_move_back.dart';
import 'kemlock/km_move_end.dart';
import 'kemlock/km_move_old_store.dart';
import 'kemlock/km_move_record.dart';
import 'kemlock/km_move_server.dart';
import 'kemlock/km_move_source.dart';
import 'kemlock/km_session.dart' show keyKemlockCache;
import 'kemlock_host_factory.dart';
import 'kemlock_matching.dart' show kemlockVaultOwner;
import 'removal_guard.dart';
import 'sync.dart';
import 'sync_merge.dart';
import 'sync_store.dart';
import 'vaultwarden/vw_backend.dart';
import 'vaultwarden/vw_file_sync.dart';
import 'vaultwarden/vw_models.dart';

/// The move as the screens and the scheduler see it.
class KmMoveState {
  const KmMoveState({this.loaded = false, this.record, this.running = false, this.step, this.done = 0, this.total = 0, this.error});

  /// Whether the record was read from the vault.
  final bool loaded;

  /// The vault's record, or null when no move was ever started.
  final KmMoveRecord? record;

  /// Whether the move runs now, and the step it is on with how many of its items are done out of how many.
  final bool running;
  final KmMoveStep? step;
  final int done;
  final int total;

  /// Why the last run stopped: what the old engine, the Kemlock API or the move itself threw.
  final Object? error;

  /// Whether a move has begun and isn't finished.
  bool get unfinished => kmMoveUnfinished(record);

  /// Whether the vault's own entries wait: before the record is read, and during a move.
  bool get pausesSync => !loaded || unfinished;

  KmMoveState copyWith({
    bool? loaded,
    Object? record = keep,
    bool? running,
    Object? step = keep,
    int? done,
    int? total,
    Object? error = keep,
  }) => KmMoveState(
    loaded: loaded ?? this.loaded,
    record: pick(record, this.record),
    running: running ?? this.running,
    step: pick(step, this.step),
    done: done ?? this.done,
    total: total ?? this.total,
    error: pick(error, this.error),
  );
}

/// Runs the move for [target] from where its record stands, calling [onProgress] as steps go. Throws what the
/// run throws. Tests of the screens override [kemlockMoveRunProvider] with one that doesn't reach a server.
typedef KmMoveRun = Future<KmMoveOutcome> Function(
  KemlockTarget target, {
  void Function(KmMoveStep step, int done, int total)? onProgress,
  RemovalChoice? choice,
});

/// Runs the real move. Tests override it.
final kemlockMoveRunProvider = Provider<KmMoveRun>(
  (ref) =>
      (target, {onProgress, choice}) => runKmMove(ref, target, onProgress: onProgress, choice: choice),
);

/// Restores a closed home from the Bitwarden trash, for "Go back to Vaultwarden". Tests override it.
final kemlockRestoreHomeProvider = Provider<Future<int> Function(VaultwardenTarget target)>(
  (ref) => (target) async {
    final controller = ref.read(vaultControllerProvider);
    final backend = VaultwardenBackend(
      vault: ref.read(vaultStoreProvider),
      session: controller.session!,
      clientFor: ref.read(vwClientFactoryProvider),
      clock: ref.read(clockProvider),
    );
    try {
      return await backend.restoreHome(target);
    } finally {
      backend.dispose();
    }
  },
);

/// The open vault's move record and run.
final kemlockMoveProvider = NotifierProvider<KemlockMove, KmMoveState>(KemlockMove.new);

class KemlockMove extends Notifier<KmMoveState> {
  var _generation = 0;
  Future<void> _loading = Future.value();

  @override
  KmMoveState build() {
    final session = ref.watch(vaultControllerProvider.select((s) => s.session));
    final generation = ++_generation;
    if (session != null) {
      _loading = Future(() => _load(session, generation));
    }
    return const KmMoveState();
  }

  /// Completes once the record was read from the vault.
  Future<void> get ready => _loading;

  KmMoveStore _store(VaultSession session) => KmMoveStore(VaultKmValues(ref.read(vaultStoreProvider), session));

  Future<void> _load(VaultSession session, int generation) async {
    KmMoveRecord? record;
    try {
      record = await _store(session).load();
      // Past the window "Go back to Vaultwarden" was offered, only a few keys of the move are kept
      if (record != null && record.isDone && !record.isTrimmed) {
        final at = record.finishedAt;
        if (at != null && ref.read(clockProvider)().millisecondsSinceEpoch - at >= kmGoBackWindow.inMilliseconds) {
          record = record.trimmed();
          await _store(session).save(record);
        }
      }
    } on Object {
      // A record that can't be read is no move: the vault's own sync runs as it did
    }
    if (!ref.mounted || generation != _generation) {
      return;
    }
    state = KmMoveState(loaded: true, record: record);
    ref.read(syncProvider.notifier).requestSync();
  }

  /// Begins the move to [target], once the person confirmed it: the record first, so nothing of the vault's own
  /// entries syncs, then the Kemlock target, then the run. Does nothing while a run is going.
  Future<void> start(KemlockTarget target) async {
    await _loading;
    final session = ref.read(vaultControllerProvider).session;
    final sync = ref.read(syncProvider.notifier);
    final settings = sync.snapshot.settings;
    if (session == null || settings == null || state.running) {
      return;
    }
    if (state.unfinished) {
      return resume();
    }
    final source = kmMoveSourceOf(settings, target);
    if (source == null) {
      return;
    }
    final record = KmMoveRecord(
      source: source.name,
      server: source.server,
      home: source.home,
      mode: source.mode,
      startedAt: ref.read(clockProvider)().millisecondsSinceEpoch,
      extra: {if (source.vaultwarden case final home?) kmGoBackTargetKey: home.toJson()},
    );
    await _store(session).save(record);
    state = state.copyWith(loaded: true, record: record, error: null);
    await sync.saveSettings(settings.copyWith(kemlock: target), session);
    await _run(target);
  }

  /// Runs a move that stopped again, at the next opening of the vault and at Try again. [choice] is the
  /// answer to the removal guard's question when the old store's run asked one.
  Future<void> resume({RemovalChoice? choice}) async {
    await _loading;
    final target = ref.read(syncProvider).settings?.kemlock;
    if (!state.loaded || !state.unfinished || state.running || target == null || ref.read(offlineProvider)) {
      return;
    }
    await _run(target, choice: choice);
  }

  Future<void> _run(KemlockTarget target, {RemovalChoice? choice}) async {
    final session = ref.read(vaultControllerProvider).session;
    state = state.copyWith(running: true, error: null, step: state.record?.step, done: 0, total: 0);
    try {
      final outcome = await ref.read(kemlockMoveRunProvider)(
        target,
        choice: choice ?? ref.read(syncProvider.notifier).removalChoice,
        onProgress: (step, done, total) {
          if (ref.mounted) {
            state = state.copyWith(step: step, done: done, total: total);
          }
        },
      );
      if (!ref.mounted) {
        return;
      }
      ref.read(syncProvider.notifier).clearRemovalChoice();
      state = state.copyWith(record: outcome.record, running: false, step: KmMoveStep.done);
      ref.read(syncProvider.notifier).requestSync();
    } on Object catch (e) {
      if (!ref.mounted) {
        return;
      }
      // The record says where the next run resumes
      KmMoveRecord? stored;
      try {
        stored = session == null ? null : await _store(session).load();
      } on Object {
        stored = null;
      }
      if (ref.mounted) {
        state = state.copyWith(running: false, error: e, record: stored ?? state.record);
      }
    }
  }

  /// Goes back to the Vaultwarden home a sealed move closed, while it is offered (30 days): restores the home from
  /// the trash and turns the Kemlock target off for the vault's own entries. Throws what the restore throws,
  /// and a [StateError] when going back isn't offered.
  Future<void> goBack() async {
    await _loading;
    final session = ref.read(vaultControllerProvider).session;
    final sync = ref.read(syncProvider.notifier);
    final settings = sync.snapshot.settings;
    final record = state.record;
    if (session == null || settings == null || record == null) {
      throw StateError('no move to go back from');
    }
    final stored = record.extra[kmGoBackTargetKey];
    if (stored is! Map<String, Object?>) {
      throw StateError('the home is not kept');
    }
    final target = VaultwardenTarget.fromJson(stored);
    final back = await goBackToVaultwarden(
      record: record,
      target: target,
      settings: settings,
      restore: () => ref.read(kemlockRestoreHomeProvider)(target),
      now: ref.read(clockProvider)(),
    );
    await _store(session).save(back.record);
    await sync.forgetScope(vaultwardenScope, session);
    await sync.forgetScope(kemlockScope, session);
    state = state.copyWith(record: back.record);
    await sync.saveSettings(back.settings, session);
  }
}

/// The old store of a move that isn't there any more, for a move resumed after its settings were
/// dropped: its first step is past, so it is never run.
class _GoneSource implements KmMoveSource {
  const _GoneSource(this.record);

  final KmMoveRecord record;

  @override
  String get name => record.source;

  @override
  String get server => record.server;

  @override
  String? get home => record.home;

  @override
  String? get mode => record.mode;

  @override
  Future<KmMoveSynced> sync(Lists local, ScopeState state, {required int now, RemovalChoice? choice}) =>
      throw StateError('the old store is no longer set up');
}

/// Runs the move of the open vault to [target] with the real stores: the old store's own run, the copy, the
/// files, the check and the old store, over the Kemlock host's session. See [KmMoveRunner].
Future<KmMoveOutcome> runKmMove(
  Ref ref,
  KemlockTarget target, {
  void Function(KmMoveStep step, int done, int total)? onProgress,
  RemovalChoice? choice,
}) async {
  final host = ref.read(kemlockHostProvider);
  if (host == null) {
    throw const KmError(KmProblem.network);
  }
  final vault = ref.read(vaultStoreProvider);
  final open = ref.read(vaultControllerProvider);
  final session = open.session!;
  final vaultId = open.vault.id;
  final attachments = ref.read(attachmentStoreProvider);
  final sync = ref.read(syncProvider.notifier);
  final clock = ref.read(clockProvider);
  final values = VaultKmValues(vault, session);
  final store = KmMoveStore(values);
  final settings = sync.snapshot.settings!;
  final record = await store.load();
  if (record == null) {
    throw StateError('the move has no record');
  }
  final scope = record.source == vaultwardenSource ? vaultwardenScope : personalScope;
  final stored = record.extra[kmGoBackTargetKey];
  final vaultwarden = settings.vaultwarden ?? (stored is Map<String, Object?> ? VaultwardenTarget.fromJson(stored) : null);
  VaultwardenBackend? backend;
  final KmMoveSource source;
  final KmMoveOldStore oldStore;
  if (record.source == vaultwardenSource && vaultwarden != null) {
    final used = backend = VaultwardenBackend(
      vault: vault,
      session: session,
      clientFor: ref.read(vwClientFactoryProvider),
      websiteFor: (issuer) {
        final domain = ref.read(twoFactorDirectoryProvider).value?.findService(issuer)?.domain;
        return domain == null || domain.isEmpty ? null : 'https://$domain';
      },
      files: VwFiles(store: attachments, vaultId: vaultId),
      clock: clock,
    );
    source = VaultwardenMoveSource(
      target: vaultwarden,
      run: (local, state, {required now, choice}) => used.sync(vaultwarden, local, state, now: now, choice: choice),
    );
    oldStore = VaultwardenOldStore(
      mode: vaultwarden.mode,
      close: (confirmed) => used.closeHome(vaultwarden, confirmed: confirmed),
    );
  } else if (record.source == webdavSource && settings.personal != null) {
    final webDav = ref.read(webDavProvider);
    source = WebDavMoveSource(
      webDav: webDav,
      target: settings.personal!,
      files: AttachmentSync(webDav: webDav, store: attachments, vaultId: vaultId),
    );
    oldStore = const WebDavOldStore();
  } else {
    source = _GoneSource(record);
    oldStore = record.source == webdavSource
        ? const WebDavOldStore()
        : VaultwardenOldStore(mode: VaultwardenMode.plain, close: (_) async => throw StateError('the home is not set up'));
  }
  try {
    return await host.withAccount(target, (connection, account) async {
      final accountSession = account.openSession();
      KmMatching? matching;
      try {
        final crypto = account.itemCrypto(accountSession);
        if (target.matching) {
          // The move's batches carry the logins' `cred` tags when the person turned server matching on, as a sync's do
          final sites = siteResolver(suffixes: await ref.read(publicSuffixListProvider.future));
          matching = await KmMatching.open(connection, connection.server, KmDedup(keys: crypto, sites: sites), kemlockVaultOwner(target));
        }
        final runner = KmMoveRunner(
          store: store,
          source: source,
          server: KmMoveServer(connection: connection, server: connection.server, crypto: crypto, tags: matching?.tags),
          files: VaultKmFiles(attachments, vaultId),
          oldStore: oldStore,
          lists: () => scopeLists(ref.read(vaultControllerProvider).lists, null),
          oldState: () async => (await sync.loadScopeStates(session))[scope] ?? const ScopeState(known: []),
          applySynced: (synced) async {
            final current = ref.read(vaultControllerProvider).lists;
            await ref.read(vaultControllerProvider.notifier).applySynced(applyScope(current, null, synced.doc));
            final states = await sync.loadScopeStates(session);
            states[scope] = ScopeState(known: synced.known, lastSyncAt: clock().millisecondsSinceEpoch, extra: synced.state);
            await sync.saveScopeStates(states, session);
          },
          onOldStore: (result) async {
            final end = kmEndOfMove(
              settings: sync.snapshot.settings ?? settings,
              states: await sync.loadScopeStates(session),
              result: result,
              confirmed: (await store.load())?.sent.keys ?? const [],
              now: clock().millisecondsSinceEpoch,
            );
            await sync.saveScopeStates(end.states, session);
            await sync.saveSettings(end.settings, session);
          },
          onProgress: onProgress,
          clock: clock,
        );
        final outcome = await runner.run(choice: choice);
        // The first Kemlock sync starts from what the check read back, instead of reading everything again
        if (outcome.cache case final cache?) {
          await values.save(keyKemlockCache, cache.toJson());
        }
        return outcome;
      } finally {
        matching?.dispose();
        accountSession.dispose();
      }
    });
  } finally {
    backend?.dispose();
  }
}
