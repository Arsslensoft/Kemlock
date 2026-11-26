// The open vault's duplicate groups, for the vault health card and the
// Duplicates screen (the add-duplicate-cleaner plan, task 4.2).
//
// The groups are found again whenever the vault's items change, which is
// after an import, after a sync and after a merge, and on Check again. Each
// pass tags only what moved (`DedupStore.refresh`) and compares what the
// tags suggest, so it is cheap when little changed. Nothing here makes a
// network request.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/public_suffixes.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart' show VaultSession;
import '../sync/kemlock_matching.dart';
import '../sync/sync_store.dart';
import 'dedup_store.dart';
import 'dedup_tagger.dart';
import 'duplicate_matcher.dart';
import 'duplicate_merge.dart';
import 'duplicate_rules.dart' show DuplicateReason;
import 'duplicate_server.dart';
import 'duplicate_sites.dart';

/// What the last check found.
@immutable
class DuplicatesState {
  const DuplicatesState({this.groups = const [], this.records = const [], this.checked = false, this.checking = false, this.checkedAt});

  /// The groups to show: the ones the person hasn't said are not duplicates.
  final List<DuplicateGroup> groups;

  /// The merges Undo merge can still put back, oldest first.
  final List<MergeRecord> records;

  int get merges => records.length;

  /// Whether a check has finished for the open vault. Without one there is nothing to count.
  final bool checked;

  /// Whether a check is running now.
  final bool checking;

  /// Epoch ms the last check finished.
  final int? checkedAt;

  DuplicatesState copyWith({List<DuplicateGroup>? groups, List<MergeRecord>? records, bool? checked, bool? checking, int? checkedAt}) =>
      DuplicatesState(
        groups: groups ?? this.groups,
        records: records ?? this.records,
        checked: checked ?? this.checked,
        checking: checking ?? this.checking,
        checkedAt: checkedAt ?? this.checkedAt,
      );
}

/// The hash of the bundled Public Suffix List, which the tag cache records. `none` when it can't be read.
final suffixListHashProvider = FutureProvider<String>((ref) async {
  try {
    return suffixListHash(await rootBundle.loadString(publicSuffixListAsset));
  } catch (_) {
    return suffixListHash(null);
  }
});

/// The signature of what the groups are made from: the open session and every list of items. A list
/// that is replaced is a different object, so a change of any of them is a change here.
Object? _signature(VaultState state) => (
  state.isUnlocked ? state.session : null,
  state.accounts,
  state.backupServices,
  state.notes,
  state.passkeys,
  state.keys,
  state.contacts,
  state.logins,
  state.cards,
  state.identities,
  state.files,
);

class DuplicatesController extends Notifier<DuplicatesState> {
  int _pass = 0;
  bool _disposed = false;

  @override
  DuplicatesState build() {
    ref.onDispose(() => _disposed = true);
    ref.listen(vaultControllerProvider.select(_signature), (previous, next) => unawaited(check()));
    // A space that joins or leaves, or whose key changes, changes who owns what
    ref.listen(syncProvider.select((sync) => sync.settings?.spaces), (previous, next) => unawaited(check()));
    // Server matching turned on or off, and the groups the server suggested after a sync, change what is shown
    ref.listen(syncProvider.select((sync) => sync.settings?.kemlock?.matching ?? false), (previous, next) => unawaited(check()));
    ref.listen(kemlockHintsProvider, (previous, next) => unawaited(check()));
    // The first check starts once the provider is built, not inside it
    scheduleMicrotask(() => unawaited(check()));
    return const DuplicatesState();
  }

  /// Finds the groups again: Check again, and what runs after an import, a sync or a merge. A check
  /// that a later one overtakes leaves nothing behind, and finishes when the later one does, so the state
  /// is the newest answer whenever a caller's `await check()` returns.
  Future<void> check() => _latest = _check();

  /// The newest check started, which an overtaken one waits for.
  Future<void>? _latest;

  Future<void> _check() async {
    final vault = ref.read(vaultControllerProvider);
    final session = vault.session;
    final pass = ++_pass;
    if (!vault.isUnlocked || session == null) {
      state = const DuplicatesState();
      return;
    }
    state = state.copyWith(checking: true);
    try {
      final suffixes = await ref.read(publicSuffixListProvider.future);
      final listHash = await ref.read(suffixListHashProvider.future);
      final items = dedupItems(
        accounts: vault.accounts,
        services: vault.backupServices,
        notes: vault.notes,
        passkeys: vault.passkeys,
        keys: vault.keys,
        logins: vault.logins,
        cards: vault.cards,
        identities: vault.identities,
        contacts: vault.contacts,
        files: vault.files,
      );
      final sites = siteResolver(suffixes: suffixes);
      final store = DedupStore(ref.read(vaultStoreProvider));
      final tags = await store.refresh(
        session,
        items: items,
        spaces: ref.read(syncProvider).settings?.spaces ?? const [],
        listHash: listHash,
        sites: sites,
      );
      var found = await findDuplicatesAsync(items: items, tags: tags, sites: sites, keyIdentityOf: dedupKeyIdentity);
      // With server matching on, the groups the server suggested are checked against the items before they are shown
      final target = ref.read(syncProvider).settings?.kemlock;
      final hints = ref.read(kemlockHintsProvider);
      if (target != null && target.matching && hints != null) {
        found = withServerHints(
          found: found,
          items: items,
          hints: hints,
          accountId: target.accountId,
          sites: sites,
          keyIdentityOf: dedupKeyIdentity,
        );
      }
      final now = ref.read(clockProvider)().millisecondsSinceEpoch;
      var answers = await store.loadAnswers(session);
      // Records past their 30 days go when the vault opens, which is when the first check runs
      final pruned = answers.pruned(now);
      if (pruned.merges.length != answers.merges.length) {
        await store.saveAnswers(pruned, session);
        answers = pruned;
      }
      if (_disposed || pass != _pass) {
        if (!_disposed) {
          await _latest;
        }
        return;
      }
      state = DuplicatesState(
        groups: withoutDismissed(found, answers.dismissed),
        records: answers.mergeRecords,
        checked: true,
        checkedAt: now,
      );
    } catch (_) {
      // A vault that can't be matched shows no count rather than a wrong one
      if (!_disposed && pass == _pass) {
        state = const DuplicatesState();
      }
    }
  }

  /// Remembers that the items of [group] are not duplicates. Check again leaves the group out until
  /// another item joins it, which gives it another key. True once it is saved.
  Future<bool> dismiss(DuplicateGroup group) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) {
      return false;
    }
    try {
      final store = DedupStore(ref.read(vaultStoreProvider));
      final answers = await store.loadAnswers(session);
      await store.saveAnswers(answers.withDismissed(group.key), session);
      unawaited(_share(group, session));
      if (!_disposed) {
        state = state.copyWith(
          groups: [
            for (final other in state.groups)
              if (other.key != group.key) other,
          ],
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tells the server that the group is not duplicates, when server matching is on and the group is one it can see (a
  /// same sign-in of the vault's own logins), so another phone hides it after its next sync. The answer's id is kept
  /// apart, for [restore]. Best effort: the answer is kept on this phone either way.
  Future<void> _share(DuplicateGroup group, VaultSession session) async {
    if (_disposed) {
      return;
    }
    final target = ref.read(syncProvider).settings?.kemlock;
    if (target == null || !target.matching || group.reason != DuplicateReason.sameSignIn) {
      return;
    }
    final ids = serverIdsOfGroup(group, target.accountId);
    if (ids == null || ids.length < 2 || ids.length > 500) {
      return;
    }
    try {
      final id = await ref.read(kemlockMatchingProvider).dismiss(target, ids);
      final store = DedupStore(ref.read(vaultStoreProvider));
      await store.saveAnswers((await store.loadAnswers(session)).withShared(group.key, id), session);
    } catch (_) {
      // The server can't be reached: the answer stays on this phone
    }
  }

  /// Takes "Not duplicates" back for the group with [key]: it is asked again at the next check, and the answer the server
  /// holds for it, if this phone shared one, is deleted. True once the answer is gone from this phone.
  Future<bool> restore(String key) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) {
      return false;
    }
    try {
      final store = DedupStore(ref.read(vaultStoreProvider));
      final answers = await store.loadAnswers(session);
      final shared = answers.sharedDismissals[key];
      await store.saveAnswers(answers.withoutDismissal(key), session);
      final target = ref.read(syncProvider).settings?.kemlock;
      if (shared != null && target != null) {
        try {
          await ref.read(kemlockMatchingProvider).restore(target, shared);
        } catch (_) {
          // The server can't be reached: its answer stays, and hides the group on the other phones
        }
      }
      await check();
      return true;
    } catch (_) {
      return false;
    }
  }
}

final duplicatesProvider = NotifierProvider<DuplicatesController, DuplicatesState>(DuplicatesController.new);
