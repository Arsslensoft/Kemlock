/// The Bitwarden copy of a plain home, kept beside Kemlock Server sync after a move (move-off-vaultwarden-sync,
/// design 8, tasks 6.1 and 6.2): the app reads the account's device list at most once a day and whenever Settings
/// opens Sync, applies the rule of `km_move_devices.dart`, and offers to remove the copy once no device used the
/// Bitwarden API for 30 days. The copy is never removed without the person's confirmation, and an offer made
/// before a device returned is withdrawn: the list is read again right before the removal.
///
/// Removing the copy is `VwAccountSetup.removeFromVault`: Kemlock's own plain items and the home note go to the
/// Bitwarden trash, and the codes come off the person's own logins with their other fields unchanged. Then the
/// home stops syncing. Nothing on Kemlock Server changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/json.dart';
import '../../platform/network.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import 'kemlock/km_auth_api.dart';
import 'kemlock/km_models.dart';
import 'kemlock/km_move_devices.dart';
import 'kemlock_move.dart';
import 'sync.dart';
import 'sync_store.dart';
import 'vaultwarden/vw_backend.dart';
import 'vaultwarden/vw_models.dart';

/// Where the copy stands, as the Settings sheet shows it.
class KmCopyState {
  const KmCopyState({this.devices = const [], this.standing, this.checkedAt, this.busy = false, this.error, this.notice});

  /// The account's devices, as last read.
  final List<KmDevice> devices;

  /// Null until the list was read.
  final KmCopyStanding? standing;
  final DateTime? checkedAt;
  final bool busy;

  /// Why the list couldn't be read or the copy couldn't be removed.
  final Object? error;

  /// `removed` or `withdrawn`, the last thing a removal did.
  final String? notice;

  /// The devices that still use the Bitwarden API, as of [checkedAt].
  List<KmDevice> get using => checkedAt == null ? const [] : kmBitwardenDevices(devices, checkedAt!);

  KmCopyState copyWith({
    List<KmDevice>? devices,
    Object? standing = keep,
    DateTime? checkedAt,
    bool? busy,
    Object? error = keep,
    Object? notice = keep,
  }) => KmCopyState(
    devices: devices ?? this.devices,
    standing: pick(standing, this.standing),
    checkedAt: checkedAt ?? this.checkedAt,
    busy: busy ?? this.busy,
    error: pick(error, this.error),
    notice: pick(notice, this.notice),
  );
}

/// Reads the account's devices through the open vault's Kemlock session. Tests override it.
final kemlockDeviceListProvider = Provider<Future<List<KmDevice>> Function(KemlockTarget target)>(
  (ref) => (target) async {
    final host = ref.read(kemlockHostProvider);
    if (host == null) {
      throw StateError('Kemlock Server sync is not running');
    }
    return host.withAccount(
      target,
      (connection, account) => connection.call((token) => KmAuthApi(connection.api).devices(connection.server, token)),
    );
  },
);

/// Takes Kemlock out of the Bitwarden copy's home: `VwAccountSetup.removeFromVault`. Tests override it.
final kemlockCopyRemovalProvider = Provider<Future<int> Function(VaultwardenTarget target)>(
  (ref) => (target) async {
    final backend = VaultwardenBackend(
      vault: ref.read(vaultStoreProvider),
      session: ref.read(vaultControllerProvider).session!,
      clientFor: ref.read(vwClientFactoryProvider),
      info: ref.read(vwClientInfoProvider),
      clock: ref.read(clockProvider),
    );
    try {
      return await VwAccountSetup.removeFromVault(await backend.connect(target), target);
    } finally {
      backend.dispose();
    }
  },
);

final kemlockCopyProvider = NotifierProvider<KemlockCopy, KmCopyState>(KemlockCopy.new);

class KemlockCopy extends Notifier<KmCopyState> {
  @override
  KmCopyState build() {
    // Another vault starts again
    ref.watch(vaultControllerProvider.select((s) => s.session));
    return const KmCopyState();
  }

  /// Whether a copy is kept: a plain home that syncs beside the Kemlock target.
  bool get _kept {
    final settings = ref.read(syncProvider).settings;
    return settings?.kemlock != null && settings?.vaultwarden != null;
  }

  /// Reads the device list, unless it was read less than a day ago and [force] isn't set, or offline mode is on.
  Future<void> check({bool force = false}) async {
    final target = ref.read(syncProvider).settings?.kemlock;
    if (!_kept || target == null || ref.read(offlineProvider) || state.busy) {
      return;
    }
    final now = ref.read(clockProvider)();
    final last = state.checkedAt;
    if (!force && last != null && now.difference(last) < const Duration(days: 1)) {
      return;
    }
    try {
      final devices = await ref.read(kemlockDeviceListProvider)(target);
      // The day the move finished is in its record
      await ref.read(kemlockMoveProvider.notifier).ready;
      if (!ref.mounted) {
        return;
      }
      final movedAt = ref.read(kemlockMoveProvider).record?.finishedAt;
      state = state.copyWith(
        devices: devices,
        checkedAt: now,
        error: null,
        standing: kmCopyStanding(devices: devices, now: now, movedAt: movedAt),
      );
    } on Object catch (e) {
      // The copy goes on syncing, and the list is read again at the next opening
      if (ref.mounted) {
        state = state.copyWith(error: e);
      }
    }
  }

  /// Removes the copy, after the person confirmed it. The list is read again first, and a device that used the
  /// Bitwarden API since the offer withdraws it: nothing is removed then.
  Future<void> remove() async {
    final settings = ref.read(syncProvider).settings;
    final session = ref.read(vaultControllerProvider).session;
    final vaultwarden = settings?.vaultwarden;
    if (settings == null || vaultwarden == null || session == null || state.busy) {
      return;
    }
    await check(force: true);
    if (!ref.mounted) {
      return;
    }
    if (state.standing != KmCopyStanding.offered) {
      state = state.copyWith(notice: 'withdrawn');
      return;
    }
    state = state.copyWith(busy: true, error: null, notice: null);
    try {
      await ref.read(kemlockCopyRemovalProvider)(vaultwarden);
      final store = ref.read(syncProvider.notifier);
      await store.forgetScope(vaultwardenScope, session);
      await store.saveSettings((store.snapshot.settings ?? settings).copyWith(vaultwarden: null), session);
      if (ref.mounted) {
        state = state.copyWith(busy: false, notice: 'removed', standing: null);
      }
    } on Object catch (e) {
      if (ref.mounted) {
        state = state.copyWith(busy: false, error: e);
      }
    }
  }
}
