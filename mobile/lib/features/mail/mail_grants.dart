/// A request the person just unlocked, approved or typed a passphrase for
/// is let finish (openspec: add-pgp-mail-provider, decision 7). When a
/// request screen that asked the person something completes, its request
/// gets a grant: an `AutoLockHolds`
/// hold, so that a vault set to lock when hidden does not lock between the
/// screen closing and the mail app sending the request again. The grant
/// ends when that request is answered, or after [MailGrants.lasts]; if
/// the vault locks when hidden and no screen of Kemlock is in front then,
/// it locks. Nothing else about a mail request touches auto-lock.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_closed_lock.dart';
import '../../platform/mail_requests.dart';
import '../../vault/vault_controller.dart';
import '../settings/auto_lock.dart';
import '../settings/prefs.dart';

class MailGrants {
  MailGrants({required this._holds, required this._ended});

  /// How long a grant waits for its request to come back.
  static const lasts = Duration(seconds: 60);

  final AutoLockHolds _holds;

  /// Called as a grant ends: locks when the vault locks on hiding and the
  /// app is hidden.
  final VoidCallback _ended;
  final _grants = <String, ({VoidCallback release, Timer timer})>{};

  /// Whether the request [requestId] has a grant.
  bool holds(String requestId) => _grants.containsKey(requestId);

  /// The request screen of [requestId] completed.
  void record(String requestId) {
    _drop(requestId)?.release();
    // Its end is no activity: the idle time runs on from the person's last touch
    final release = _holds.hold(resetsIdle: false);
    _grants[requestId] = (release: release, timer: Timer(lasts, () => end(requestId)));
  }

  /// [call] got [answer]. A request sent again from a screen with a grant
  /// ends that grant; when it needs the person again, the grant goes on
  /// with the request screen it gets instead. No other request touches a
  /// grant.
  void answered(MailCall call, MailAnswer answer) {
    final from = call.resentFrom;
    if (from == null) return;
    final grant = _drop(from);
    if (grant == null) return;
    if (answer.resultCode == 2) {
      _grants[call.requestId] = (release: grant.release, timer: Timer(lasts, () => end(call.requestId)));
      return;
    }
    grant.release();
    _ended();
  }

  /// Ends the grant of [requestId], if it has one: its time is up, or its
  /// screen was cancelled.
  void end(String requestId) {
    final grant = _drop(requestId);
    if (grant == null) return;
    grant.release();
    _ended();
  }

  void dispose() {
    for (final grant in _grants.values) {
      grant.timer.cancel();
      grant.release();
    }
    _grants.clear();
  }

  ({VoidCallback release, Timer timer})? _drop(String requestId) {
    final grant = _grants.remove(requestId);
    grant?.timer.cancel();
    return grant;
  }
}

final mailGrantsProvider = Provider<MailGrants>((ref) {
  final grants = MailGrants(
    holds: ref.watch(autoLockHoldsProvider),
    ended: () {
      final vault = ref.read(vaultControllerProvider);
      if (vault.isUnlocked && ref.read(prefsProvider).lockOnHide && !ref.read(appShownProvider)()) {
        ref.read(vaultControllerProvider.notifier).lock();
      }
    },
  );
  ref.onDispose(grants.dispose);
  return grants;
});
