/// When sync runs, ported from the part of `SyncController.tsx` that isn't
/// React: on unlock, [settleMs] after the user's last change, when the app
/// comes back to the front, every five minutes while it's in front, and on
/// "Sync now" or a change of settings. One sync runs at a time; a request
/// while one runs queues one more. A run that raced a change the user made
/// is thrown away and repeated, so it never overwrites what they just did.
///
/// The shell makes one scheduler per open vault session, and drives it:
///
/// ```dart
/// final scheduler = SyncScheduler(
///   store: ref.read(syncProvider.notifier),
///   webDav: ref.read(webDavProvider),
///   session: session,
///   getLists: () => lists,              // the latest accounts and services
///   applySynced: saveWithoutCounting,   // stores merged lists, no change counted
/// );
/// unawaited(scheduler.start());
/// // After each change the user makes:  scheduler.userChanged();
/// // AppLifecycleListener: onShow → scheduler.setVisible(true), onHide → false
/// // On lock, or a new session after a password change: scheduler.dispose();
/// ```
library;

import 'dart:async';

import '../../models/secure_note.dart';
import '../../vault/vault_store.dart';
import '../spaces/space_bridge.dart';
import '../spaces/space_head_store.dart';
import '../spaces/space_scope.dart' show isServerSpaceId, rescopedTo, serverSpaceUuidOrNull;
import 'attachment_sync.dart';
import 'kemlock/km_backend.dart';
import 'kemlock/km_models.dart';
import 'space_bridge_run.dart';
import 'sync.dart';
import 'sync_crypto.dart' show isSpaceId;
import 'sync_merge.dart';
import 'sync_personal.dart';
import 'sync_store.dart';
import 'vaultwarden/vw_backend.dart';
import 'vaultwarden/vw_models.dart';
import 'vaultwarden/vw_sync.dart';
import 'webdav.dart';

/// Syncs at least this often while the app is open and in front.
const syncPeriod = Duration(minutes: 5);

/// Starts a one-shot timer, as [Timer.new] does; tests pass fake timers.
typedef StartTimer = Timer Function(Duration delay, void Function() callback);

/// Starts a repeating timer, as [Timer.periodic] does; tests pass fake timers.
typedef StartPeriodicTimer = Timer Function(Duration period, void Function(Timer timer) callback);

/// Keeps one open vault in sync through the [SyncNotifier].
class SyncScheduler {
  SyncScheduler({
    required this.store,
    required this.webDav,
    required this.session,
    required this.getLists,
    required this.applySynced,
    this.vaultwarden,
    this.kemlock,
    this.serverSpaces,
    this.files,
    this.fetchFiles,
    this.ownEntriesPaused,
    this.anchors,
    this._clock = DateTime.now,
    this._startTimer = Timer.new,
    this._startPeriodicTimer = Timer.periodic,
  });

  final SyncNotifier store;
  final WebDav webDav;

  /// The open vault's session; a new session needs a new scheduler.
  final VaultSession session;

  /// The vault's latest accounts and backup services.
  final Lists Function() getLists;

  /// Stores lists that sync merged, without counting them as a user change.
  final Future<void> Function(Lists lists) applySynced;

  /// Syncs with Vaultwarden, when the settings say so.
  final VaultwardenBackend? vaultwarden;

  /// Syncs with Kemlock Server, when the settings say so.
  final KemlockBackend? kemlock;

  /// Syncs the server spaces the account is a confirmed member of, one scope each under the space's UUID, when the
  /// settings sign this vault in to Kemlock Server. They run beside the vault's own scopes, and a space that stops
  /// with a problem (its chain doesn't verify, its keys are being replaced) stops alone.
  final KemlockSpacesBackend? serverSpaces;

  /// Syncs the files attached to notes beside each WebDAV scope's document.
  final AttachmentSync? files;

  /// Takes the files a scope's notes name that this phone lacks, to fetch
  /// from [dav] outside the run.
  final void Function(DavAccount dav, List<NoteAttachment> files)? fetchFiles;

  /// Whether the vault's own entries wait for a move to Kemlock Server that isn't finished
  /// (`kmMoveUnfinished`): then neither WebDAV, Vaultwarden nor Kemlock Server syncs them, and edits on this
  /// phone wait for the first Kemlock sync. WebDAV spaces keep syncing, and server spaces wait too: they share the
  /// account's session and anchors with the move.
  final bool Function()? ownEntriesPaused;

  /// Where this phone keeps the anchors of the account's server spaces. The vault's own WebDAV file carries them between the
  /// account's devices (`syncAnchorsKey`); a space's file never does, so a space file stays as released.
  final SpaceAnchorStorage? anchors;

  final DateTime Function() _clock;
  final StartTimer _startTimer;
  final StartPeriodicTimer _startPeriodicTimer;

  bool _visible = true;
  bool _started = false;
  bool _disposed = false;

  /// Counts the user's changes, so a run that raced one is dropped.
  int _revision = 0;

  bool _running = false;
  bool _again = false;
  int _busy = 0;
  final _idleWaiters = <Completer<void>>[];

  Timer? _settle;
  Timer? _period;
  void Function()? _stopRequests;

  /// Loads the vault's sync settings and syncs with them. If they can't be
  /// read, sync stays unloaded.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _stopRequests = store.onSyncRequest(_trigger);
    _period = _startPeriodicTimer(syncPeriod, (_) {
      if (_visible) _trigger();
    });
    try {
      await store.load(session);
    } catch (_) {
      if (!_disposed) store.unload();
      return;
    }
    // Settings loaded
    if (!_disposed && store.snapshot.settings != null) _trigger();
  }

  /// The user changed something: sync once they pause for [settleMs].
  void userChanged() {
    if (_disposed) return;
    _revision++;
    _settle?.cancel();
    _settle = _startTimer(const Duration(milliseconds: settleMs), _trigger);
  }

  /// The app came to the front ([visible]) or went to the back. Coming to
  /// the front syncs, and the five-minute syncs only run while in front.
  void setVisible(bool visible) {
    _visible = visible;
    if (visible) _trigger();
  }

  /// Stops syncing and forgets the settings, when the vault locks or its
  /// session is replaced. A run still going is dropped when it ends. Without
  /// [unload] the settings and each scope's last status stay for the screens
  /// to show, as while offline mode pauses sync.
  void dispose({bool unload = true}) {
    if (_disposed) return;
    _disposed = true;
    vaultwarden?.dispose();
    kemlock?.dispose();
    _settle?.cancel();
    _period?.cancel();
    _stopRequests?.call();
    if (unload) {
      store.unload();
    } else {
      store.setRunning(false);
    }
  }

  /// Resolves once no sync runs and none is queued.
  Future<void> get idle {
    if (_busy == 0) return Future.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  void _trigger() {
    if (!_disposed) unawaited(run());
  }

  /// Syncs every scope now, or queues one more run if one is going.
  Future<void> run() async {
    final settings = store.snapshot.settings;
    if (_disposed || settings == null) return;
    final vaultwarden = this.vaultwarden;
    final kemlock = this.kemlock;
    // WebDAV and Kemlock Server both holding the vault's own entries: neither syncs until the sheet
    // has asked which keeps them. The vault's spaces go on.
    final clash = settings.ownEntriesClash;
    // A move that isn't finished holds the vault's own entries still: the move copies them, and a sync meanwhile
    // would change what it is copying
    final moving = ownEntriesPaused?.call() ?? false;
    final ownScopes = <({String key, String? scope, _RunScope sync})>[
      if (settings.personal case final personal? when !clash && !moving)
        (key: personalScope, scope: null, sync: _webDavScope(personal, carriesAnchors: true)),
      if (settings.vaultwarden case final target? when vaultwarden != null && !moving)
        (key: vaultwardenScope, scope: null, sync: _vaultwardenScope(vaultwarden, target)),
      if (settings.kemlock case final target? when kemlock != null && !clash && !moving)
        (key: kemlockScope, scope: null, sync: _kemlockScope(kemlock, target)),
    ];
    // A space joined before invites were checked could carry one of the vault's own scope names
    final davSpaces = [
      for (final space in settings.spaces)
        if (isSpaceId(space.id)) space,
    ];
    // Server spaces are listed during the run, once the vault's own scopes are known: a move that isn't finished holds
    // them too, as it holds the Kemlock scope
    final spaces = serverSpaces;
    final spacesTarget = spaces == null || moving ? null : settings.kemlock;
    if (ownScopes.isEmpty && davSpaces.isEmpty && spacesTarget == null) {
      return;
    }
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _busy++;
    store.setRunning(true);
    try {
      final revision = _revision;
      final states = await store.loadScopeStates(session);
      var lists = getLists();
      final statuses = <(String, ScopeStatus)>[];
      var choiceUsed = false;

      // Runs one scope and answers whether it went through, with nothing of it failing on either side
      Future<bool> runScope(String key, String? scope, _RunScope sync) async {
        try {
          final result = await sync(scopeLists(lists, scope), states[key] ?? const ScopeState(known: []), _clock().millisecondsSinceEpoch);
          // What the document holds under the id of an entry kept in another scope stays out of this
          // one, and out of what it held: the next run must not write it down as deleted here
          final keptOut = heldElsewhere(lists, scope, result.doc);
          lists = applyScope(lists, scope, result.doc);
          final at = _clock().millisecondsSinceEpoch;
          final known = keptOut.isEmpty ? result.known : [...result.known.where((id) => !keptOut.contains(id))];
          states[key] = ScopeState(known: known, lastSyncAt: at, extra: result.state);
          // One side of a moved space that failed (its file or its server) shows as the scope's problem; the other side synced
          final failure = result.failure;
          statuses.add((key, ScopeStatus(lastSyncAt: at, problem: failure == null ? null : problemOf(failure), count: result.count)));
          if (key == vaultwardenScope || key == kemlockScope) {
            choiceUsed = true;
          }
          return failure == null;
        } catch (e) {
          statuses.add((
            key,
            ScopeStatus(lastSyncAt: states[key]?.lastSyncAt, problem: problemOf(e), count: e is VwSyncError ? e.count : 0),
          ));
          return false;
        }
      }

      for (final (:key, :scope, :sync) in ownScopes) {
        await runScope(key, scope, sync);
      }

      // The account's confirmed server spaces, listed once for the run: a WebDAV space that moved, or that a server space
      // was found for, is told from it. A list that can't be read leaves every space as it was: the problem shows under the
      // list's own scope, and a moved space whose server can't be reached carries on through its file if it bridges
      List<String>? confirmed;
      if (spaces != null && spacesTarget != null) {
        try {
          confirmed = await spaces.confirmedSpaces(spacesTarget);
          statuses.add((kemlockSpacesScope, ScopeStatus(lastSyncAt: _clock().millisecondsSinceEpoch)));
        } catch (e) {
          statuses.add((kemlockSpacesScope, ScopeStatus(problem: problemOf(e))));
        }
      }

      // A WebDAV space under the same id keeps its own scope, and so does the server space it moved to, which the phone
      // knows by the space's WebDAV id and the server by its legacy-id UUID; an id that isn't a space's UUID is never one
      final taken = {for (final scope in ownScopes) scope.key};
      final noted = <String, SpaceOnServer>{};
      // The notes the run started from, which a change it makes is checked against
      final startNotes = {for (final space in settings.spaces) space.id: space.onServer};
      for (final space in davSpaces) {
        taken.add(space.id);
        final uuid = serverSpaceUuidOrNull(space.id);
        if (uuid != null) {
          taken.add(uuid);
        }
        // A move of this space runs on this phone: it is copying the entries, so a run leaves the space alone until it ends
        if (store.isMoving(space.id)) {
          continue;
        }
        final note = space.onServer;
        final serverUp = spaces != null && spacesTarget != null && confirmed != null && uuid != null;
        final listed = confirmed != null && uuid != null && confirmed.contains(uuid);
        final at = _clock().millisecondsSinceEpoch;
        // What each way of syncing the space says of its WebDAV copy, to keep in its note
        BridgeSignal? signal;
        SpaceCopyClosed? reason;
        var ran = false;
        void told(BridgeSignal? found, SpaceCopyClosed? why) {
          signal = found;
          reason = why;
          ran = true;
        }

        // Keeps the note of the space when what a run said of its WebDAV copy changes it
        void keep(SpaceOnServer base) {
          final next = _afterRun(base, at, signal, reason);
          if (next != note) {
            noted[space.id] = next;
          }
        }

        switch (note?.state) {
          case null when listed:
            // The server lists a space under the UUID this WebDAV id gives, which anyone who can list the folder can compute.
            // Nothing is merged on that: the person is asked first, naming the Owner, and only for a space whose chain this
            // account compared a fingerprint for already (an anchor is stored; none is made here). Meanwhile the file syncs as
            // any WebDAV space's does
            final offer = await _offerFor(spaces!, spacesTarget!, uuid, at);
            if (offer != null) {
              noted[space.id] = SpaceOnServer(state: SpaceCopy.offered, uuid: uuid, at: at, owner: offer.owner);
            }
            await runScope(space.id, space.id, _webDavScope(space.target));
          case SpaceCopy.joining when listed:
            // The person agreed: merge the file in once and stop writing it. A file or server that can't be reached leaves
            // the space joining, and it is tried again
            final merged = await runScope(
              space.id,
              space.id,
              _bridgedScope(space, uuid, spaces!, spacesTarget!, writeFile: false, told: told),
            );
            if (ran) {
              // Joined only when the space says its move is whole (its marker), or that it is closed; a run that says nothing, or that
              // this account isn't a member, leaves it joining
              final done = merged && (signal == BridgeSignal.open || signal == BridgeSignal.closed);
              keep(done ? note!.to(SpaceCopy.joined, at) : note!);
            }
          case SpaceCopy.bridged when listed:
            await runScope(space.id, space.id, _bridgedScope(space, uuid, spaces!, spacesTarget!, writeFile: true, told: told));
            if (ran) {
              keep(note!);
            }
          case SpaceCopy.bridged when serverUp:
            // The account is no longer a confirmed member: the WebDAV copy is closed for it
            noted[space.id] = note!.to(SpaceCopy.closed, at, reason: SpaceCopyClosed.left);
          case SpaceCopy.joined || SpaceCopy.closed when listed:
            await runScope(space.id, space.id, _movedServerScope(space, uuid, spaces!, spacesTarget!, told: told));
            if (ran && note!.state == SpaceCopy.joined) {
              keep(note);
            }
          case SpaceCopy.joined || SpaceCopy.closed:
            // The server can't say whether the account is still in the space, or it isn't: nothing of the file or the space
            // is touched this time
            break;
          case _:
            // Not moved, moving or offered: the file alone, as any WebDAV space. A bridged or joining space whose server can't be
            // asked is read and never written: its chain may close the copy
            final stillBridging = note?.state == SpaceCopy.bridged || note?.state == SpaceCopy.joining;
            await runScope(space.id, space.id, _webDavScope(space.target, readOnly: stillBridging));
        }
      }
      if (spaces != null && spacesTarget != null && confirmed != null) {
        for (final space in confirmed) {
          if (isServerSpaceId(space) && taken.add(space)) {
            await runScope(space, space, _serverSpaceScope(spaces, spacesTarget, space));
          }
        }
      }
      if (_disposed) return;
      if (_revision != revision) {
        // The user changed something meanwhile; merge that in with a fresh run
        _again = true;
        return;
      }
      if (!sameLists(lists, getLists())) await applySynced(lists);
      await store.saveScopeStates(states, session);
      if (choiceUsed) store.clearRemovalChoice();
      for (final (key, status) in statuses) {
        store.setScopeStatus(key, status);
      }
      if (noted.isNotEmpty) {
        // What the moved spaces learned of their WebDAV copy: offered, joined or closed. Kept last, so a phone that stops before
        // this learns it again at its next run, which does no harm. A change is applied only to the note the run started from: one
        // that changed meanwhile (a move that began, the person's word, the Owner's close) is newer than what this run saw and
        // is never written over, and a space whose move runs on this phone is left alone
        final current = store.snapshot.settings;
        if (current != null) {
          final applied = {
            for (final space in current.spaces)
              if (noted[space.id] case final next? when space.onServer == startNotes[space.id] && !store.isMoving(space.id)) space.id: next,
          };
          if (applied.isNotEmpty) {
            await store.saveSettings(
              current.copyWith(
                spaces: [
                  for (final space in current.spaces)
                    if (applied[space.id] case final next?) space.withOnServer(next) else space,
                ],
              ),
              session,
            );
          }
        }
      }
    } finally {
      _running = false;
      // Once disposed, the store was unloaded and may belong to the next session's scheduler
      if (!_disposed) store.setRunning(false);
      if (_again && !_disposed) {
        _again = false;
        _busy++;
        unawaited(Future(run).whenComplete(_leave));
      }
      _leave();
    }
  }

  _RunScope _webDavScope(SyncTarget target, {bool carriesAnchors = false, bool readOnly = false}) => (local, state, now) async {
    if (readOnly) {
      // A bridged space whose server can't be asked: the file is read and never written, since the copy may be closed
      final read = await readWebDavOnce(webDav, target, local, state, now);
      return (doc: read.doc, known: read.known, state: read.state, count: 0, failure: null);
    }
    final store = carriesAnchors ? anchors : null;
    final held = store == null ? null : await _heldAnchors(store);
    final run = await runWebDavScope(
      webDav: webDav,
      target: target,
      local: local,
      state: state,
      now: now,
      files: files,
      fetchFiles: fetchFiles,
      anchors: held == null || (held.length == 0 && held.extra.isEmpty) ? null : held.toJson(),
    );
    if (store != null && held != null) {
      await _keepAnchors(store, held, run.doc.extra[syncAnchorsKey]);
    }
    return (doc: run.doc, known: run.known, state: run.state, count: 0, failure: null);
  };

  /// The anchors [store] holds, or null when they can't be read: a run then carries none and saves none, so it
  /// never writes over a value it couldn't read.
  Future<SpaceAnchors?> _heldAnchors(SpaceAnchorStorage store) async {
    try {
      return await store.load(session);
    } catch (_) {
      return null;
    }
  }

  /// Keeps the anchors a file carried ([merged], their union with [held]) in [store], when they differ.
  Future<void> _keepAnchors(SpaceAnchorStorage store, SpaceAnchors held, Object? merged) async {
    if (merged == null || canonical(merged) == canonical(held.toJson())) {
      return;
    }
    try {
      await store.save(SpaceAnchors.fromJson(merged), session);
    } catch (_) {
      // The next run merges again and keeps it
    }
  }

  _RunScope _vaultwardenScope(VaultwardenBackend backend, VaultwardenTarget target) => (local, state, now) async {
    final result = await backend.sync(target, local, state, now: now, choice: store.removalChoice);
    return (doc: result.doc, known: result.known, state: result.state, count: result.skipped, failure: null);
  };

  _RunScope _kemlockScope(KemlockBackend backend, KemlockTarget target) => (local, state, now) async {
    final result = await backend.sync(target, local, state, now: now, choice: store.removalChoice);
    return (doc: result.doc, known: result.known, state: result.state, count: result.skipped, failure: null);
  };

  /// One server space's run. The removal choice is for the vault's own entries and is not passed on: a "keep" that stopped
  /// the vault's run would otherwise make a space's run ignore the deletions other members made. What the run says of a WebDAV
  /// copy is for a moved space alone, and is not kept.
  _RunScope _serverSpaceScope(KemlockSpacesBackend backend, KemlockTarget target, String space) => (local, state, now) async {
    // A space that never had a WebDAV copy carries no closure: what a run throws is its problem as it is
    final result = await backend.syncSpace(target, space, local, state, now: now);
    return (doc: result.doc, known: result.known, state: takeBridgeSignal(result.state).state, count: result.skipped, failure: null);
  };

  /// One run of a moved WebDAV space whose copies are both synced (`runBridged`): [writeFile] false for a phone that found the
  /// space and merges the file in once. The server knows the space by [uuid] and its entries as that space's, so they go
  /// under it and come back under it; the phone keeps the WebDAV id. [told] gets what the run said of the WebDAV copy.
  _RunScope _bridgedScope(
    Space space,
    String uuid,
    KemlockSpacesBackend backend,
    KemlockTarget target, {
    required bool writeFile,
    required void Function(BridgeSignal? signal, SpaceCopyClosed? reason) told,
  }) => (local, state, now) async {
    final run = await runBridged(
      webDav: webDav,
      target: space.target,
      scope: space.id,
      local: local,
      state: state,
      now: now,
      writeFile: writeFile,
      files: files,
      fetchFiles: fetchFiles,
      server: (entries, kept) =>
          backend.syncSpace(target, uuid, rescopedTo(entries, uuid), kept, now: now, joining: !writeFile, bridged: true),
    );
    told(run.signal, run.reason);
    return (doc: run.doc, known: run.known, state: run.state, count: run.skipped, failure: run.failure);
  };

  /// One run of a moved space that no longer syncs its file: the server space alone, under the WebDAV id on the phone.
  _RunScope _movedServerScope(
    Space space,
    String uuid,
    KemlockSpacesBackend backend,
    KemlockTarget target, {
    required void Function(BridgeSignal? signal, SpaceCopyClosed? reason) told,
  }) => (local, state, now) async {
    final KmSyncResult result;
    try {
      result = await backend.syncSpace(target, uuid, rescopedTo(local, uuid), state, now: now, bridged: true);
    } on ClosedRunError catch (e) {
      // A failure after the chain showed the copy closed: the copy is closed, and the failure is the run's problem
      told(BridgeSignal.closed, e.reason);
      throw e.cause;
    }
    final taken = takeBridgeSignal(result.state);
    told(taken.signal, taken.reason);
    if (taken.signal == BridgeSignal.gone || taken.signal == BridgeSignal.uncompared) {
      // This account isn't a confirmed member, or no fingerprint was compared for the space: the empty answer deletes nothing here,
      // as in a bridged run, and the entries and the ids the scope knew stay as they were
      return (doc: listsAsDoc(local), known: state.known, state: state.extra, count: 0, failure: null);
    }
    return (doc: result.doc, known: result.known, state: taken.state, count: result.skipped, failure: null);
  };

  /// [base], the note of a moved space, once a run said [signal] of its WebDAV copy: closed for the reason it gave, or for
  /// good when the account turned out not to be a member. A copy that is closed already stays as it is, and so does one whose
  /// space no fingerprint was compared for ([BridgeSignal.uncompared]): that is no leaving.
  SpaceOnServer _afterRun(SpaceOnServer base, int at, BridgeSignal? signal, SpaceCopyClosed? reason) {
    if (base.state == SpaceCopy.closed) {
      return base;
    }
    return switch (signal) {
      BridgeSignal.closed => base.to(SpaceCopy.closed, at, reason: reason ?? SpaceCopyClosed.keys),
      // A phone that agreed to join and isn't a member yet (or any more) has left nothing: it stays as it was
      BridgeSignal.gone when base.state == SpaceCopy.joining => base,
      BridgeSignal.gone => base.to(SpaceCopy.closed, at, reason: SpaceCopyClosed.left),
      _ => base,
    };
  }

  /// The offer of the server space [uuid] to merge into, or null when it has none or can't be read now: the next run asks again.
  Future<JoinOffer?> _offerFor(KemlockSpacesBackend backend, KemlockTarget target, String uuid, int at) async {
    try {
      return await backend.joinOffer(target, uuid, now: at);
    } catch (_) {
      return null;
    }
  }

  void _leave() {
    if (--_busy > 0) return;
    for (final waiter in _idleWaiters) {
      waiter.complete();
    }
    _idleWaiters.clear();
  }
}

/// One scope's sync: this device's entries in it and what it held after the
/// last sync, to the merged document, the ids it holds, the state to keep
/// for next time, a count to show (Vaultwarden's skipped items), and the failure of one side of a moved space that synced on
/// the other (null otherwise).
typedef _RunScope = Future<({SyncDoc doc, List<String> known, Map<String, Object?> state, int count, Object? failure})> Function(
  Lists local,
  ScopeState state,
  int now,
);
