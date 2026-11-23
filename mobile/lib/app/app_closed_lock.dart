import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/auto_lock.dart';
import '../platform/app_closed.dart';
import '../vault/vault_controller.dart';

/// Locks the open vault when the main screen is closed for good, as the end
/// of the engine did before the engine outlived it (openspec:
/// add-pgp-mail-provider, decision 2). While a hold is in place, such as
/// the grant of a mail request the person just unlocked for (decision 7),
/// it waits for the holds to end, and locks then unless a screen of
/// Kemlock is in front again.
class AppClosedLock {
  AppClosedLock({required this._holds, required this._lock, required this._shown});

  /// How often the holds are looked at while it waits.
  static const checkEvery = Duration(seconds: 1);

  final AutoLockHolds _holds;
  final VoidCallback _lock;

  /// Whether a screen of Kemlock is in front.
  final bool Function() _shown;
  Timer? _waiting;

  /// The main screen was closed for good.
  void closed() {
    if (!_holds.isHeld) {
      _stop();
      _lock();
      return;
    }
    _waiting ??= Timer.periodic(checkEvery, (_) => _check());
  }

  /// A screen came to the front: from now on the usual rules apply.
  void shown() => _stop();

  void dispose() => _stop();

  void _check() {
    if (_holds.isHeld) return;
    _stop();
    if (!_shown()) _lock();
  }

  void _stop() {
    _waiting?.cancel();
    _waiting = null;
  }
}

/// Whether the app is on screen: resumed, or inactive under a system sheet.
/// With no activity attached Flutter says detached.
bool appIsShown() => switch (WidgetsBinding.instance.lifecycleState) {
  AppLifecycleState.resumed || AppLifecycleState.inactive => true,
  _ => false,
};

/// Whether a screen of Kemlock is in front; tests put their own.
final appShownProvider = Provider<bool Function()>((ref) => appIsShown);

/// The app's [AppClosedLock], listening from launch: `main` reads it.
final appClosedLockProvider = Provider<AppClosedLock>((ref) {
  final closedLock = AppClosedLock(
    holds: ref.watch(autoLockHoldsProvider),
    lock: () {
      final vault = ref.read(vaultControllerProvider.notifier);
      if (ref.read(vaultControllerProvider).isUnlocked) vault.lock();
    },
    shown: ref.watch(appShownProvider),
  );
  final closed = ref.watch(appClosedSignalProvider).closed.listen((_) => closedLock.closed());
  final lifecycle = AppLifecycleListener(onResume: closedLock.shown);
  ref.onDispose(() {
    unawaited(closed.cancel());
    lifecycle.dispose();
    closedLock.dispose();
  });
  return closedLock;
});
