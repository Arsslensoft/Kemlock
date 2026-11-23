/// Sync settings and status for the open vault, ported from `syncStore.ts`,
/// shared by the scheduler (which runs syncs, see `sync_scheduler.dart`) and
/// the dialogs (which show and change them). The settings hold the WebDAV
/// password and the sync keys, so they're stored encrypted with the vault.
///
/// Watch [syncProvider] for the [SyncSnapshot]; call its notifier to load,
/// change or forget settings, and to ask for a sync:
///
/// ```dart
/// final sync = ref.watch(syncProvider);
/// final store = ref.read(syncProvider.notifier);
/// await store.saveSettings(sync.settings!.copyWith(personal: null), session);
/// await store.forgetScope(personalScope, session);
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../platform/device_keys.dart';
import '../../platform/network.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import 'kemlock/km_failover.dart' show KmAway;
import 'kemlock/km_host.dart' show KmHost;
import 'kemlock/km_models.dart';
import 'kemlock_host_factory.dart';
import 'sync.dart';
import 'vaultwarden/vw_http.dart';
import 'vaultwarden/vw_sync.dart';
import 'webdav.dart';

/// How long sync waits after the last change before syncing it, in ms.
const settleMs = 2000;

const _keySettings = 'backmycodes_sync';
const _keyState = 'backmycodes_sync_state';

/// Sync turned off: no vault sync and no spaces.
const noSync = SyncSettings();

/// How one scope's last sync went.
@immutable
class ScopeStatus {
  const ScopeStatus({this.lastSyncAt, this.problem, this.count = 0});

  /// Epoch ms of the last sync that went through, or null.
  final int? lastSyncAt;

  /// Why the last try failed, or null when it went through.
  final SyncProblem? problem;

  /// Vaultwarden: with [SyncProblem.removals], how many entries would go;
  /// after a sync that went through, how many items were left alone because
  /// they can't be read.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is ScopeStatus && other.lastSyncAt == lastSyncAt && other.problem == problem && other.count == count;

  @override
  int get hashCode => Object.hash(lastSyncAt, problem, count);

  @override
  String toString() => 'ScopeStatus($lastSyncAt, ${problem?.name}${count != 0 ? ', $count' : ''})';
}

/// Sync as the screens see it.
@immutable
class SyncSnapshot {
  const SyncSnapshot({this.settings, this.status = const {}, this.running = false});

  /// null while the vault is locked or the settings are loading.
  final SyncSettings? settings;

  /// By scope: [personalScope] or a space id.
  final Map<String, ScopeStatus> status;

  /// True while a sync runs.
  final bool running;

  SyncSnapshot _with({Object? settings = _same, Map<String, ScopeStatus>? status, bool? running}) => SyncSnapshot(
    settings: identical(settings, _same) ? this.settings : settings as SyncSettings?,
    status: status ?? this.status,
    running: running ?? this.running,
  );

  @override
  String toString() => 'SyncSnapshot($settings, $status, running: $running)';
}

const _same = Object();

/// The name of the space with [spaceId] in [settings], or null for the
/// vault's own entries and for a space this vault isn't in.
String? spaceName(SyncSettings? settings, String? spaceId) {
  if (spaceId == null || spaceId.isEmpty) return null;
  for (final space in settings?.spaces ?? const <Space>[]) {
    if (space.id == spaceId) return space.name;
  }
  return null;
}

/// Talks to WebDAV folders, through a gated client, which makes no request while offline
/// mode is on. Tests override it with a fake server's client.
final webDavProvider = Provider<WebDav>((ref) => WebDav(ref.watch(gatedClientProvider)));

/// Makes the plain client the Vaultwarden factory wraps, pinning a self-signed
/// certificate's fingerprint when given one. Tests override it to see what the gate lets
/// through.
final vwPlainClientFactoryProvider = Provider<http.Client Function(String? pin)>(
  (ref) =>
      (pin) => vwHttpClient(pin: pin),
);

/// Makes the client Vaultwarden sync talks through: a gated one, which makes no request
/// while offline mode is on. Tests override it with a fake server's client.
final vwClientFactoryProvider = Provider<http.Client Function(String? pin)>(
  (ref) => gatedClientFactory(ref.watch(networkGateProvider), ref.watch(vwPlainClientFactoryProvider)),
);

/// Makes the client Kemlock Server sync talks through: the same gated, certificate-pinning factory
/// Vaultwarden uses, so nothing is sent while offline mode is on and a server whose certificate the
/// system doesn't trust is trusted only for the one the person compared. `KmApi` makes no client of its own.
final kemlockClientFactoryProvider = Provider<http.Client Function(String? pin)>((ref) => ref.watch(vwClientFactoryProvider));

/// Signs this phone out of Kemlock Server when sync is turned off: opens the session and asks the server to
/// end this device's session. A server that can't be reached throws, and "Turn off" then only forgets the session
/// here. Tests override it.
final kemlockSignOutProvider = Provider<Future<void> Function(KemlockTarget target)>(
  (ref) => (target) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    await makeKmHost(
      vault: ref.read(vaultStoreProvider),
      session: session,
      clientFor: ref.read(kemlockClientFactoryProvider),
      deviceKeys: ref.read(deviceKeysProvider),
    ).signOut(target);
  },
);

/// The open vault's sync settings and status.
final syncProvider = NotifierProvider<SyncNotifier, SyncSnapshot>(SyncNotifier.new);

/// The name of the space an entry belongs to, or null for the vault's own
/// (`useSpaceName`).
final spaceNameProvider = Provider.autoDispose.family<String?, String?>(
  (ref, spaceId) => spaceName(ref.watch(syncProvider.select((sync) => sync.settings)), spaceId),
);

/// Loads, keeps and changes the open vault's sync settings, and passes on
/// requests to sync.
class SyncNotifier extends Notifier<SyncSnapshot> {
  final _requests = <VoidCallback>{};
  RemovalChoice? _removalChoice;

  // Counts loads and unloads, so a load that finishes after the vault locked
  // or another load started doesn't bring back what it read.
  var _generation = 0;

  @override
  SyncSnapshot build() => const SyncSnapshot();

  /// The current snapshot, for code outside the widget tree.
  SyncSnapshot get snapshot => state;

  // Reads and writes the active vault, as the encrypted values in crypto.ts do.
  VaultStore get _vault => ref.read(vaultStoreProvider);

  void _update(SyncSnapshot next) {
    if (ref.mounted) state = next;
  }

  /// What each scope held after its last sync on this device.
  Future<Map<String, ScopeState>> loadScopeStates(VaultSession session) async {
    final stored = await _vault.loadEncryptedValue(_keyState, session);
    if (stored is! Map<String, Object?>) return {};
    return {
      for (final MapEntry(:key, :value) in stored.entries)
        if (value is Map<String, Object?>) key: ScopeState.fromJson(value),
    };
  }

  Future<void> saveScopeStates(Map<String, ScopeState> states, VaultSession session) =>
      _vault.saveEncryptedValue(_keyState, {for (final MapEntry(:key, :value) in states.entries) key: value.toJson()}, session);

  /// Reads the open vault's sync settings; called when it unlocks. Throws
  /// when they can't be read, after which the caller unloads.
  Future<void> load(VaultSession session) async {
    final generation = ++_generation;
    final settings = await _vault.loadEncryptedValue(_keySettings, session);
    final states = await loadScopeStates(session);
    if (generation != _generation) return;
    _update(
      SyncSnapshot(
        settings: settings == null ? noSync : SyncSettings.fromJson(settings),
        status: {for (final MapEntry(:key, :value) in states.entries) key: ScopeStatus(lastSyncAt: value.lastSyncAt)},
      ),
    );
  }

  /// Forgets everything when the vault locks.
  void unload() {
    _generation++;
    _removalChoice = null;
    _moving.clear();
    _update(const SyncSnapshot());
  }

  /// Stores new settings, then asks for a sync with them.
  Future<void> saveSettings(SyncSettings next, VaultSession session) async {
    await _vault.saveEncryptedValue(_keySettings, next.toJson(), session);
    _update(state._with(settings: next));
    requestSync();
  }

  /// Drops the remembered state of a scope that is gone, so rejoining starts fresh.
  Future<void> forgetScope(String scope, VaultSession session) async {
    final states = await loadScopeStates(session)
      ..remove(scope);
    await saveScopeStates(states, session);
    _update(state._with(status: {...state.status}..remove(scope)));
  }

  void setScopeStatus(String scope, ScopeStatus status) => _update(state._with(status: {...state.status, scope: status}));

  void setRunning(bool running) {
    if (state.running != running) _update(state._with(running: running));
  }

  /// What the user decided about a Vaultwarden sync that stopped before
  /// removing many entries, until a sync goes through with it.
  RemovalChoice? get removalChoice => _removalChoice;

  /// Syncs again with the user's decision about the removals.
  void decideRemovals(RemovalChoice choice) {
    _removalChoice = choice;
    requestSync();
  }

  /// Forgets the decision, once a sync went through with it.
  void clearRemovalChoice() => _removalChoice = null;

  final _moving = <String>{};

  /// Whether a move of the WebDAV space [space] to Kemlock Server runs on this phone now. The scheduler leaves such a space alone:
  /// the move is copying its entries, and a run that merged the file meanwhile would change them, or write its own note over the
  /// move's. Kept in memory only: a phone that stopped midway syncs the file again, and the move runs again from the button.
  bool isMoving(String space) => _moving.contains(space);

  /// Says that a move of [space] started ([moving] true) or ended.
  void setMoving(String space, {required bool moving}) {
    if (moving) {
      _moving.add(space);
    } else {
      _moving.remove(space);
    }
  }

  /// Asks the scheduler to sync as soon as it can ("Sync now", or settings changed).
  void requestSync() {
    for (final listener in [..._requests]) {
      listener();
    }
  }

  /// Calls [listener] on each [requestSync]; returns the call that stops it.
  VoidCallback onSyncRequest(VoidCallback listener) {
    _requests.add(listener);
    return () => _requests.remove(listener);
  }
}

/// Where the phone is while the vault's home server is away, or null while it is on the home: the replica in
/// use and since when. Kemlock Server sync reports it after each run, and the sync sheet shows it. It starts
/// again from null whenever the vault locks or opens.
final kemlockAwayProvider = NotifierProvider<KemlockAway, KmAway?>(KemlockAway.new);

class KemlockAway extends Notifier<KmAway?> {
  @override
  KmAway? build() {
    ref.watch(vaultControllerProvider.select((state) => state.session));
    return null;
  }

  void set(KmAway? away) => state = away;
}

/// The open vault's Kemlock Server host, the one the scheduler runs, so approvals and the devices list use the
/// server (and replica) a sync is using. Null while the vault is locked or offline mode has stopped sync.
final kemlockHostProvider = NotifierProvider<KemlockHostHolder, KmHost?>(KemlockHostHolder.new);

class KemlockHostHolder extends Notifier<KmHost?> {
  @override
  KmHost? build() {
    // Another vault, or offline mode, is another host: the one set for them follows this being reset
    ref.watch(vaultControllerProvider.select((state) => state.session));
    ref.watch(offlineProvider);
    return null;
  }

  void set(KmHost? host) => state = host;
}
