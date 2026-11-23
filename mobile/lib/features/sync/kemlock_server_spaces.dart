// The server spaces of a vault that syncs with Kemlock Server (docs/plans/add-server-spaces.md, task 5.1): the source the
// Spaces sheet lists, built from the sync host's session. A vault with no Kemlock Server, or none open (locked, or offline
// mode), has none, so the list shows no section.

library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault/vault_controller.dart';
import '../spaces/hidden_passwords.dart';
import '../spaces/km_server_spaces.dart';
import '../spaces/server_spaces.dart' show ChainReport;
import '../spaces/server_spaces_list.dart';
import '../spaces/space_bridge.dart' show JoinOffer;
import '../spaces/space_chain.dart' show ChainCrypto, RealChainCrypto;
import '../spaces/space_policies.dart' show LeaveFirst;
import '../spaces/space_policies_provider.dart';
import '../spaces/space_state.dart' show SpaceState;
import 'kemlock/km_account.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_backend.dart' show KemlockSpacesBackend, KmSyncResult;
import 'kemlock/km_failover.dart' show KmHomeAway;
import 'kemlock/km_host.dart';
import 'kemlock/km_models.dart';
import 'removal_guard.dart' show RemovalChoice;
import 'sync.dart' show ScopeState;
import 'sync_merge.dart' show Lists;
import 'sync_store.dart';

/// The check of a space's chain signatures, which a test replaces with a cheap one.
final spaceChainCryptoProvider = Provider<ChainCrypto>((ref) => const RealChainCrypto());

/// The open vault's server spaces, or null when it doesn't sync with Kemlock Server.
final kemlockServerSpacesSourceProvider = Provider<ServerSpacesSource?>((ref) {
  final host = ref.watch(kemlockHostProvider);
  final target = ref.watch(syncProvider.select((sync) => sync.settings?.kemlock));
  // The vault this source belongs to: a chain it reports after another vault opened is dropped (`reportCompared`)
  final vaultId = ref.read(vaultControllerProvider).vault.id;
  if (host == null || target == null) {
    return null;
  }
  return kmServerSpacesOf(
    host,
    target,
    chainCrypto: ref.watch(spaceChainCryptoProvider),
    // Each chain a read or a run verified says which logins hide their password (`hiddenPasswordsProvider`)
    onChain: (space, account, chain, {collections}) {
      if (ref.mounted) {
        ref.read(hiddenPasswordsProvider.notifier).report(space, account, chain, collections: collections);
      }
    },
    // Only a chain whose fingerprint this device compared says which policies apply (`spacePoliciesProvider`)
    onComparedChain: (space, account, chain, {collections}) {
      if (ref.mounted) {
        ref
            .read(spacePoliciesProvider.notifier)
            .reportCompared(space, account, chain, email: ref.read(syncProvider).settings?.kemlock?.email, vault: vaultId);
      }
    },
    // The sheet keeps the source it was built with while this provider rebuilds on every settings save (`KemlockTarget` has no
    // `==`), so each closure that reads a provider asks `ref.mounted` first: a disposed ref can't be read.
    // An invitation the member accepted counts as being in the space for one space per member
    onInvitation: (space, account, chain, {required accepted}) {
      if (ref.mounted) {
        ref
            .read(spacePoliciesProvider.notifier)
            .report(space, account, chain, email: ref.read(syncProvider).settings?.kemlock?.email, accepted: accepted);
      }
    },
    // A member of a space that allows one space per member makes no other
    makeBlockedBy: () => ref.mounted ? ref.read(spacePoliciesProvider).leaveFirstBeforeMaking() : null,
    // One space per member: an invitation to a second space says which one to leave first
    leaveFirstFor: (space, chain) => ref.mounted ? ref.read(spacePoliciesProvider).leaveFirstFor(space, chain) : null,
    // The messages of a policy name the space by the name its chain's commitment opened
    onName: (space, name) {
      if (ref.mounted) {
        ref.read(spacePoliciesProvider.notifier).name(space, name);
      }
    },
    // The notices of the policies a member was told live with the vault's Kemlock settings, as the duplicate cleaner's do
    noticesSeen: () => ref.mounted ? ref.read(syncProvider).settings?.kemlock?.matchingSeen ?? const {} : const {},
    markNoticeSeen: (key, value) async {
      if (!ref.mounted) {
        return;
      }
      final session = ref.read(vaultControllerProvider).session;
      final store = ref.read(syncProvider.notifier);
      final settings = store.snapshot.settings;
      final current = settings?.kemlock;
      if (session == null || settings == null || current == null) {
        return;
      }
      await store.saveSettings(settings.copyWith(kemlock: current.copyWith(matchingSeen: {...current.matchingSeen, key: value})), session);
    },
  );
});

/// The server spaces of the account [target] signs in as, run through [host].
KmServerSpaces kmServerSpacesOf(
  KmHost host,
  KemlockTarget target, {
  ChainCrypto chainCrypto = const RealChainCrypto(),
  ChainReport? onChain,
  ChainReport? onComparedChain,
  void Function(String space, String account, SpaceState chain, {required bool accepted})? onInvitation,
  LeaveFirst? Function()? makeBlockedBy,
  Map<String, int> Function()? noticesSeen,
  Future<void> Function(String key, int value)? markNoticeSeen,
  LeaveFirst? Function(String space, SpaceState chain)? leaveFirstFor,
  void Function(String space, String name)? onName,
}) => KmServerSpaces(
  accountId: target.accountId,
  run: <T>(Future<T> Function(KmConnection connection, KmAccount account) action) => host.withAccount<T>(target, action),
  loadValue: host.values.load,
  saveValue: host.values.save,
  loadAnchors: host.anchors?.load,
  saveAnchors: host.anchors?.save,
  homeDown: () {
    try {
      host.requireHome(target);
      return null;
    } on KmHomeAway {
      // The name of the home, which is what the person waits for, not of the replica in use
      return host.homeUrl(target).host;
    }
  },
  homeUrl: () => host.homeUrl(target),
  ownBundle: host.ownBundle,
  chainCrypto: chainCrypto,
  onChain: onChain,
  onComparedChain: onComparedChain,
  onInvitation: onInvitation,
  makeBlockedBy: makeBlockedBy,
  noticesSeen: noticesSeen,
  markNoticeSeen: markNoticeSeen,
  leaveFirstFor: leaveFirstFor,
  onName: onName,
);

/// The scheduler's backend for the account's server spaces (docs/plans/add-server-spaces.md, "Server spaces as a sync
/// scope"): the spaces [host] lists with the account confirmed, and one run of each, through the host's session. Every
/// chain a run verifies goes to [onChain].
class KmSpacesBackend implements KemlockSpacesBackend {
  KmSpacesBackend({required this.host, this.chainCrypto = const RealChainCrypto(), this.onChain, this.onComparedChain});

  final KmHost host;
  final ChainCrypto chainCrypto;
  final ChainReport? onChain;

  /// Every chain of a space whose fingerprint this device compared, which the policies are read from.
  final ChainReport? onComparedChain;

  KmServerSpaces _of(KemlockTarget target) =>
      kmServerSpacesOf(host, target, chainCrypto: chainCrypto, onChain: onChain, onComparedChain: onComparedChain);

  @override
  Future<List<String>> confirmedSpaces(KemlockTarget target) => _of(target).confirmedSpaces();

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
  }) => _of(target).syncSpace(space, local, state, now: now, choice: choice, joining: joining, bridged: bridged);

  @override
  Future<JoinOffer?> joinOffer(KemlockTarget target, String space, {required int now}) => _of(target).joinOffer(space, now: now);
}
