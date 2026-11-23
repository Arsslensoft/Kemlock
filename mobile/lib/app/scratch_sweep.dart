import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/scratch.dart';
import '../vault/vault_controller.dart';

/// Deletes the plain copies picking, sharing and exporting left in the
/// phone's cache (`platform/scratch.dart`). Tests put a recorder in its place.
final scratchSweepProvider = Provider<Future<void> Function()>((ref) => sweepPhoneScratch);

/// Sweeps the cache whenever the vault stops being open: it locked, by
/// hand, by the clock or with the app, it was deleted, or every vault was
/// erased, from an open vault or from the lock screen. A lock is the
/// promise that what the vault held can no longer be read on this phone,
/// and an erase that nothing of it is left, which a plain copy in the cache
/// would break. `main` reads it once, after it has swept at start.
final scratchSweeperProvider = Provider<void>((ref) {
  ref.listen(vaultControllerProvider.select((state) => state.phase), (previous, next) {
    if (next != VaultPhase.unlocked) unawaited(ref.read(scratchSweepProvider)().catchError((Object _) {}));
  });
});
