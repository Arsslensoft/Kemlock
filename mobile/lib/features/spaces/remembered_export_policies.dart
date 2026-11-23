// What the open vault remembers of each space's export policy (docs/plans/add-server-spaces.md, task 7.4).
//
// A file export (the encrypted backup, the plain export, the QR codes) leaves out the items of a server space whose chain
// this phone hasn't read since the vault opened (`SpaceExportRule.unknown`), because it can't tell whether the space
// forbids export. A backup made offline, with the server down or right after unlock would then lack every shared item.
//
// So each chain a run or a read verified and whose fingerprint this device compared (`KmSpaceSync.onComparedChain`) leaves
// a record of its export policy in the vault's sealed anchors (`RememberedExportPolicy`, kept with the space's anchor and
// carried to the account's other phones with it), and this notifier holds those records while the vault is open. The
// export rule follows a record until a chain read since the vault opened replaces it, and never relaxes one: a space with
// no record stays unknown, and its items stay out.

library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart' show VaultSession;
import '../sync/sync_store.dart';
import 'space_head_store.dart';
import 'space_state.dart';

/// The vault's anchors of the spaces' chains: on the device, and in the value the vault's sync carries when it syncs with
/// Kemlock Server or WebDAV, so the anchors reach the account's other phones.
final spaceAnchorStoreProvider = Provider<SyncedSpaceAnchorStore>(
  (ref) => SyncedSpaceAnchorStore(
    ref.watch(vaultStoreProvider),
    syncs: () {
      final settings = ref.read(syncProvider).settings;
      return settings != null && (settings.personal != null || settings.kemlock != null);
    },
  ),
);

/// The export policy each space's last compared chain gave, by the space's UUID, read from the vault when it opens and
/// emptied when it locks.
class RememberedExportPoliciesNotifier extends Notifier<Map<String, RememberedExportPolicy>> {
  // Null while there is nothing to wait for: a future made ahead would belong to the zone that built the notifier (a test's
  // fake-async one, say), and awaiting it from another zone waits for that zone's microtasks to run
  Future<void>? _loaded;
  Future<void>? _writes;

  /// Which build this is, and the vault it was made for: a read or a chain that comes back after the vault locked or another
  /// opened belongs to a state that is gone and is dropped.
  Object _token = Object();
  String? _vaultId;

  @override
  Map<String, RememberedExportPolicy> build() {
    // Read again when the vault locks, unlocks or another vault opens, as the policies of the chains are
    ref.watch(vaultControllerProvider.select((state) => (open: state.isUnlocked, vault: state.vault.id)));
    final vault = ref.read(vaultControllerProvider);
    final token = _token = Object();
    _vaultId = vault.vault.id;
    final session = vault.session;
    _loaded = vault.isUnlocked && session != null ? _load(session, token) : null;
    return const {};
  }

  /// Completes once the records of the open vault were read, or couldn't be, and the ones just made are saved: an export waits
  /// for it.
  Future<void> get ready async {
    final loaded = _loaded;
    if (loaded != null) {
      await loaded;
    }
    final writes = _writes;
    if (writes != null) {
      await writes;
    }
  }

  Future<void> _load(VaultSession session, Object token) async {
    try {
      final anchors = await ref.read(spaceAnchorStoreProvider).load(session);
      if (ref.mounted && identical(_token, token)) {
        // A chain read while this loaded is further on than the stored record
        state = {...anchors.exportPolicies, ...state};
      }
    } catch (_) {
      // Anchors that can't be read give no record: the spaces stay unknown, so their items stay out of an export
    }
  }

  /// Takes the export policy of [chain], which a run or a read of [space] verified and whose fingerprint this device compared,
  /// for [account]. A chain that doesn't show the account a confirmed member forbids export: the space's policies don't
  /// apply to someone who isn't a member, and its items aren't theirs to take out.
  ///
  /// [vault] is the id of the vault the run or the read belongs to, when the caller knows it: a chain that comes back after
  /// another vault opened is another vault's and is dropped.
  void remember(String space, String account, SpaceState chain, {String? vault}) {
    if (vault != null && vault != _vaultId) {
      return;
    }
    final member = chain.member(account);
    final policy = RememberedExportPolicy(
      disableExport: member == null || !member.isConfirmed || chain.policies['disableExport'] == true,
      epoch: chain.epoch,
      seq: chain.headSeq ?? 0,
      at: ref.read(clockProvider)().millisecondsSinceEpoch,
    );
    final held = state[space];
    if (held != null && !policy.supersedes(held)) {
      return;
    }
    state = {...state, space: policy};
    // The session of the vault the chain was read for: a lock before the write runs doesn't send it to another vault
    final open = ref.read(vaultControllerProvider);
    final session = open.isUnlocked ? open.session : null;
    if (session != null) {
      final store = ref.read(spaceAnchorStoreProvider);
      final token = _token;
      Future<void> write() async {
        if (identical(_token, token)) {
          await _save(store, space, policy, session);
        }
      }

      final earlier = _writes;
      _writes = earlier == null ? write() : earlier.then<void>((_) => write());
    }
  }

  /// Saves [policy] in the vault's anchors. Best effort: a write that fails leaves the record in memory, and the next chain
  /// read makes it again.
  Future<void> _save(SyncedSpaceAnchorStore store, String space, RememberedExportPolicy policy, VaultSession session) async {
    try {
      await store.rememberExport(space, policy, session);
    } catch (_) {
      // Kept in memory for this run of the vault
    }
  }
}

/// The export policies the vault remembers.
final rememberedExportPoliciesProvider = NotifierProvider<RememberedExportPoliciesNotifier, Map<String, RememberedExportPolicy>>(
  RememberedExportPoliciesNotifier.new,
);
