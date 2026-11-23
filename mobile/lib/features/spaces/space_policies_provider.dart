// The spaces' policies the open vault's app holds, for the screens that enforce them (docs/plans/add-server-spaces.md,
// task group 7). Each run of a space and each read of its chain on the Spaces sheet reports the chain it verified
// (`KmSpaceSync.onChain`); what is here is only ever a verified chain's policy set (`space_policies.dart`).
//
// It lives in memory and starts empty, and it is emptied when the vault locks: a policy that hasn't been read since the
// vault opened isn't applied by the screens that fail open on it (sign-in's ways, the master password's length, the
// invitation to a second space).

library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault/vault_controller.dart';
import 'remembered_export_policies.dart';
import 'space_policies.dart';
import 'space_state.dart';

class SpacePoliciesNotifier extends Notifier<SpacePolicies> {
  @override
  SpacePolicies build() {
    // Emptied when the vault locks, unlocks or another vault opens, and by nothing else: a password change and a key
    // replacement install a new session of the same open vault, and the policies read since stay
    ref.watch(vaultControllerProvider.select((state) => (open: state.isUnlocked, vault: state.vault.id)));
    return const SpacePolicies();
  }

  /// Takes the chain a run or a read of [space] verified, for [account], who signed in with [email].
  /// [accepted] is what the server's list said of an invitation (null when the caller read only the chain).
  void report(String space, String account, SpaceState chain, {String? email, bool? accepted}) =>
      state = state.remembering(space, account, chain, email: email, accepted: accepted);

  /// [report] for a chain whose fingerprint this device compared, which also leaves its export policy in the vault, for the
  /// file exports to follow when a chain can't be read (`rememberedExportPoliciesProvider`).
  ///
  /// [vault] is the id of the vault the run or the read belongs to, when the caller knows it: a report that comes back after
  /// another vault opened is that vault's, and is dropped.
  void reportCompared(String space, String account, SpaceState chain, {String? email, String? vault}) {
    if (vault != null && vault != ref.read(vaultControllerProvider).vault.id) {
      return;
    }
    report(space, account, chain, email: email);
    ref.read(rememberedExportPoliciesProvider.notifier).remember(space, account, chain, vault: vault);
  }

  /// Takes the name [space]'s chain opened.
  void name(String space, String name) => state = state.naming(space, name);

  /// Drops a space the account left.
  void forget(String space) => state = state.forgetting(space);
}

/// The spaces' policies, from the verified chains.
final spacePoliciesProvider = NotifierProvider<SpacePoliciesNotifier, SpacePolicies>(SpacePoliciesNotifier.new);
