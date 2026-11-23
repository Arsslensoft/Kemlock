/// Server matching as the open vault runs it outside a sync (add-duplicate-cleaner, task group 7): the calls the
/// switches and the cleaner make, the groups the last run read from the server, the spaces whose admins can turn
/// matching on, and the notice every member sees when they do.
///
/// - [kemlockMatchingProvider] turns matching on or off for an owner, reads its settings and shares "Not
///   duplicates", over the Kemlock host's session. Tests override the host, not this.
/// - [kemlockHintsProvider] holds the server's groups of the vault's logins from the last run. They are hints: the
///   cleaner opens the items and compares them before it shows any (`duplicate_server.dart`).
/// - [kemlockDedupSpacesProvider] lists the server spaces the account is in, with its role in each. It is empty
///   until docs/plans/add-server-spaces.md puts spaces in the app, which fills it.
/// - [kemlockMatchingNoticesProvider] tells a member of a space that an admin turned matching on, once.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault/vault_controller.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_dedup_api.dart';
import 'kemlock/km_host.dart';
import 'kemlock/km_models.dart';
import 'sync_store.dart';

/// The server's owner text of the account's own vault.
String kemlockVaultOwner(KemlockTarget target) => 'user:${target.accountId}';

/// The server's owner text of the space with [spaceId], a UUID.
String kemlockSpaceOwner(String spaceId) => 'space:$spaceId';

/// Turns server matching on or off for an owner, reads its settings and shares "Not duplicates", through the host
/// in use. Each call throws what the request throws: a [KmError] when the server can't be reached or refuses.
class KemlockMatching {
  KemlockMatching(this._host);

  final KmHost? Function() _host;

  Future<T> _call<T>(KemlockTarget target, Future<T> Function(KmDedupApi api, Uri server, String token) request) async {
    final host = _host();
    if (host == null) {
      throw const KmError(KmProblem.network);
    }
    return host.withAccount(
      target,
      (connection, account) => connection.call((token) => request(KmDedupApi(connection.api), connection.server, token)),
    );
  }

  /// Whether the server groups [owner]'s tags, who last changed it and when.
  Future<KmMatchingSettings> settings(KemlockTarget target, String owner) =>
      _call(target, (api, server, token) => api.settings(server, token, owner));

  /// Turns it on for [owner]. The server lets a person do it for their vault and a space's owners and admins for the space.
  Future<KmMatchingSettings> turnOn(KemlockTarget target, String owner) =>
      _call(target, (api, server, token) => api.turnOn(server, token, owner));

  /// Turns it off for [owner] and deletes every tag it uploaded: `DELETE /kem/v1/duplicates/tags`.
  Future<KmMatchingSettings> turnOff(KemlockTarget target, String owner) =>
      _call(target, (api, server, token) => api.deleteTags(server, token, owner));

  /// Saves "Not duplicates" for the vault's logins [itemIds] (server item ids) and returns the answer's id.
  Future<String> dismiss(KemlockTarget target, List<String> itemIds) =>
      _call(target, (api, server, token) => api.dismiss(server, token, kemlockVaultOwner(target), itemIds));

  /// Takes the saved answer [dismissalId] back.
  Future<void> restore(KemlockTarget target, String dismissalId) =>
      _call(target, (api, server, token) => api.undismiss(server, token, dismissalId));
}

/// The vault's server matching calls, over the host a sync is using. Null host (no open vault, or offline mode) makes
/// each call throw a network [KmError].
final kemlockMatchingProvider = Provider<KemlockMatching>((ref) => KemlockMatching(() => ref.read(kemlockHostProvider)));

/// The server's groups of the vault's logins as the last run on the home read them, or null before one, with matching
/// off, and after the vault locks. The cleaner checks them against the items before it shows any.
final kemlockHintsProvider = NotifierProvider<KemlockHints, KmHints?>(KemlockHints.new);

class KemlockHints extends Notifier<KmHints?> {
  @override
  KmHints? build() {
    ref.watch(vaultControllerProvider.select((state) => state.session));
    return null;
  }

  void set(KmHints? hints) => state = hints;
}

/// A server space the account belongs to, with whether it may turn matching on or off for it.
class KmDedupSpace {
  const KmDedupSpace({required this.id, required this.name, required this.admin});

  /// The space's UUID.
  final String id;
  final String name;

  /// Whether the account is an owner or an admin of the space, which the server asks of whoever turns matching on or off.
  final bool admin;

  String get owner => kemlockSpaceOwner(id);
}

/// The server spaces the account is in. Empty until server spaces are in the app; tests override it.
final kemlockDedupSpacesProvider = Provider<List<KmDedupSpace>>((ref) => const []);

/// What a member is told: an admin turned server matching on for [name], when the server says it changed ([at], Unix seconds).
class KmMatchingNotice {
  const KmMatchingNotice({required this.owner, required this.name, required this.at});

  final String owner;
  final String name;
  final int at;
}

/// The notices to show: each space of [spaces] whose [settings] say matching is on, changed by someone else than [me],
/// and later than the change [seen] last told about. An admin who turned it on isn't told of their own change.
List<KmMatchingNotice> matchingNotices({
  required String me,
  required Iterable<KmDedupSpace> spaces,
  required Map<String, KmMatchingSettings> settings,
  required Map<String, int> seen,
}) {
  final notices = <KmMatchingNotice>[];
  for (final space in spaces) {
    final state = settings[space.owner];
    final at = state?.changedAt;
    if (state == null || !state.enabled || at == null || state.changedBy == me || at <= (seen[space.owner] ?? 0)) {
      continue;
    }
    notices.add(KmMatchingNotice(owner: space.owner, name: space.name, at: at));
  }
  return notices;
}

/// The notices the open vault's member has not seen, read from the server after each sync run.
final kemlockMatchingNoticesProvider = NotifierProvider<KemlockMatchingNotices, List<KmMatchingNotice>>(KemlockMatchingNotices.new);

class KemlockMatchingNotices extends Notifier<List<KmMatchingNotice>> {
  @override
  List<KmMatchingNotice> build() {
    ref.watch(vaultControllerProvider.select((state) => state.session));
    return const [];
  }

  /// Reads the settings of each space and sets the notices. A server that can't be reached leaves them as they were.
  Future<void> refresh() async {
    final target = ref.read(syncProvider).settings?.kemlock;
    final spaces = ref.read(kemlockDedupSpacesProvider);
    if (target == null || spaces.isEmpty) {
      state = const [];
      return;
    }
    final matching = ref.read(kemlockMatchingProvider);
    final settings = <String, KmMatchingSettings>{};
    try {
      for (final space in spaces) {
        settings[space.owner] = await matching.settings(target, space.owner);
      }
    } on KmError {
      return;
    }
    if (!ref.mounted) {
      return;
    }
    state = matchingNotices(me: target.accountId, spaces: spaces, settings: settings, seen: target.matchingSeen);
  }

  /// Marks [notice] as told, so it doesn't come back: the settings keep when it was last changed.
  Future<void> dismiss(KmMatchingNotice notice) async {
    final session = ref.read(vaultControllerProvider).session;
    final store = ref.read(syncProvider.notifier);
    final settings = store.snapshot.settings;
    final target = settings?.kemlock;
    state = [
      for (final other in state)
        if (other.owner != notice.owner) other,
    ];
    if (session == null || settings == null || target == null) {
      return;
    }
    await store.saveSettings(
      settings.copyWith(kemlock: target.copyWith(matchingSeen: {...target.matchingSeen, notice.owner: notice.at})),
      session,
    );
  }
}
