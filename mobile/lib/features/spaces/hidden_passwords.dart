// Hidden passwords of a server space (docs/plans/add-server-spaces.md, task 5.5; the space chain section of
// docs/crypto.md, "Grants"). A grant of "view, passwords hidden" or "edit, passwords hidden" hides the password of the
// space's logins in that collection from the member: the login sheet shows no password, no Show and no Copy for it.
// AutoFill still fills it, because it reads the login itself and never the sheet. The member holds the collection's key
// all the same, so this guards against shoulder-surfing and careless copying, not against the member (the words
// `space.collection.hidden` the grants section shows).
//
// What decides is the verified chain, never the server's list: the account's access to the login's collection is
// `SpaceState.accessOf`, where grants combine so that passwords stay hidden only when every grant hides them. The
// collection of an entry is the scope state's (`space_scope.dart`). The run of a space reports both through
// [HiddenPasswordsNotifier.report] each time it verifies the chain (`KmSpaceSync.onChain`), so a grant that changed
// follows the next read; the sync run adds the collection of each entry.
//
// It fails closed. The reports live in memory and start empty, and the list of the account's server spaces is only known
// after a network call (the settings hold the WebDAV spaces and the Kemlock account, not the server's spaces). So a login
// with a `spaceId` counts as hidden until its space has reported its chain, unless the vault's settings are loaded and
// list that id as a WebDAV space that has not moved, which has no grants and never hides; a moved space keeps its WebDAV id and
// reports under its UUID, so its logins stay hidden until its chain says otherwise. Between unlock and a space's first sync, or with no
// network at all, no password of a space is shown, copied, exported or sent. Only a reported chain whose grant for this
// account doesn't hide passwords releases a login. A login with no `spaceId` is the vault's own and is never hidden.
//
// An entry whose collection isn't known is hidden unless some collection the account has access to lets it read
// passwords, so a gap in the scope state never shows what a grant hides.

library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/login.dart';
import '../../models/vault_entry.dart';
import '../sync/sync.dart' show SyncSettings;
import '../sync/sync_store.dart' show syncProvider;
import 'space_bridge.dart' show plainWebDavSpaceIds;
import 'space_scope.dart' show serverSpaceUuidOrNull;
import 'space_state.dart';

/// What one server space tells about passwords: its verified chain, the account whose app this is, and the collection
/// of each entry by the entry's own id.
class SpaceHold {
  const SpaceHold({required this.chain, required this.account, this.collections = const {}});

  final SpaceState chain;
  final String account;
  final Map<String, String> collections;
}

/// Which logins hide their password, from the spaces the app holds a verified chain of.
class HiddenPasswords {
  const HiddenPasswords([this.spaces = const {}, this.webDavSpaces]);

  /// By the id the logins of the space carry as their `spaceId`.
  final Map<String, SpaceHold> spaces;

  /// The ids of the WebDAV spaces in the vault's sync settings that are still WebDAV spaces (`plainWebDavSpaceIds`: one that moved
  /// is a server space's), which have no grants, or null while the settings aren't loaded (locked, loading). A `spaceId` that is
  /// neither one of these nor a space that reported its chain is a server space whose chain isn't known yet, and its logins
  /// stay hidden.
  final Set<String>? webDavSpaces;

  /// Whether [login]'s password is hidden from this account. A login of a space with no reported chain is hidden unless
  /// the space is a known WebDAV space, and so is one whose chain gives this account no access at all.
  bool hides(Login login) {
    final space = login.spaceId;
    if (space == null || space.isEmpty) {
      return false;
    }
    // A moved WebDAV space keeps its WebDAV id on the phone, and its chain reports under the UUID the server knows it by
    final hold = spaces[space] ?? _heldUnderUuid(space);
    if (hold == null) {
      return !(webDavSpaces?.contains(space) ?? false);
    }
    final collection = hold.collections[login.id];
    if (collection != null) {
      final access = hold.chain.accessOf(hold.account, collection);
      return access == null || access.hidePasswords;
    }
    final mine = hold.chain.collectionsOf(hold.account);
    if (mine.isEmpty) {
      return true;
    }
    return mine.every((id) => hold.chain.accessOf(hold.account, id)?.hidePasswords ?? true);
  }

  /// Whether this account may change [entry]: an entry of the vault's own always, one of a WebDAV space that has not moved (it
  /// has no roles), and one of a server space only when the verified chain gives the account edit access to its collection.
  /// It fails closed like [hides]: a space whose chain isn't reported yet is not one the account may write.
  bool canEdit(VaultEntry<Object?> entry) {
    final space = entry.spaceId;
    if (space == null || space.isEmpty) {
      return true;
    }
    final hold = spaces[space] ?? _heldUnderUuid(space);
    if (hold == null) {
      return webDavSpaces?.contains(space) ?? false;
    }
    final collection = hold.collections[entry.id];
    if (collection != null) {
      return hold.chain.accessOf(hold.account, collection)?.edit ?? false;
    }
    final mine = hold.chain.collectionsOf(hold.account);
    return mine.isNotEmpty && mine.every((id) => hold.chain.accessOf(hold.account, id)?.edit ?? false);
  }

  /// The report of the server space that [space], a WebDAV space's id, has become when it moved: its chain is reported under
  /// the space's UUID. Null for an id that has no UUID.
  SpaceHold? _heldUnderUuid(String space) {
    final uuid = serverSpaceUuidOrNull(space);
    return uuid == null ? null : spaces[uuid];
  }

  /// [logins] less the ones whose password is hidden from this account, for what must never carry a hidden password out
  /// (an export).
  List<Login> withoutHidden(List<Login> logins) => [
    for (final login in logins)
      if (!hides(login)) login,
  ];

  /// The ids of the logins among [logins] whose password is hidden from this account.
  Set<String> hiddenIds(Iterable<Login> logins) => {
    for (final login in logins)
      if (hides(login)) login.id,
  };

  HiddenPasswords remembering(String space, SpaceHold hold) => HiddenPasswords({...spaces, space: hold}, webDavSpaces);

  HiddenPasswords forgetting(String space) => HiddenPasswords({...spaces}..remove(space), webDavSpaces);

  /// These reports with the WebDAV spaces [settings] lists, or with none known while they aren't loaded.
  HiddenPasswords withSettings(SyncSettings? settings) =>
      HiddenPasswords(spaces, settings == null ? null : plainWebDavSpaceIds(settings.spaces));
}

/// Keeps what the account's server spaces say about passwords, for the login sheet.
class HiddenPasswordsNotifier extends Notifier<HiddenPasswords> {
  @override
  HiddenPasswords build() {
    // The WebDAV spaces follow the settings, which are there right after unlock, before any network
    ref.listen(syncProvider.select((sync) => sync.settings), (_, settings) => state = state.withSettings(settings));
    return const HiddenPasswords().withSettings(ref.read(syncProvider).settings);
  }

  /// Takes what a run of [space] found: its verified chain and the collection of each entry.
  void remember(String space, SpaceHold hold) => state = state.remembering(space, hold);

  /// Takes the chain a run of [space] verified, for [account]. [collections] is the collection of each entry when the
  /// run knows them (a sync run); a read of the chain alone (the Spaces sheet) passes none and keeps the ones known, so
  /// a changed grant is followed at once while the items stay mapped.
  void report(String space, String account, SpaceState chain, {Map<String, String>? collections}) {
    final known = state.spaces[space]?.collections ?? const <String, String>{};
    state = state.remembering(space, SpaceHold(chain: chain, account: account, collections: collections ?? known));
  }

  /// Drops a space the account left.
  void forget(String space) => state = state.forgetting(space);
}

/// The server spaces' hidden passwords. Until a run of a space reports its chain, its logins are hidden (see the top of
/// this file).
final hiddenPasswordsProvider = NotifierProvider<HiddenPasswordsNotifier, HiddenPasswords>(HiddenPasswordsNotifier.new);
