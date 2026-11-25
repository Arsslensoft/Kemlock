/// How this phone's push token reaches Kemlock Server (add-kemlock-server-sync, design 13; plan add-unifiedpush). The token
/// is not part of the device body of a sign-in, which the server refuses with an unknown field; it goes to
/// `POST /kem/v1/devices/push-token` once signed in, at each sync run while the push switch is on, and is taken back
/// with `DELETE` when the person turns the switch off or the distributor ends the registration.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/network.dart';
import '../../platform/push.dart';
import '../../platform/reminders.dart';
import 'kemlock/km_auth_api.dart' show KmPushToken;
import 'kemlock/km_models.dart';
import 'sync_store.dart';

/// The phone's push token as the server takes it, with the kind the phone's push service gives: `apns` on iOS, and the
/// UnifiedPush endpoint's URL as `unifiedpush` on Android. Null when there is none (no push in this build, notifications
/// refused, no distributor chosen, offline mode, a channel that fails). A phone that gives an APNs token is asked, once, to
/// show the notification a sign-in request raises; the answer changes nothing here (a UnifiedPush message is shown by no
/// one: the phone only syncs). Nothing waits on the answer, and the caller never waits on this: a channel that never
/// answers only leaves the token unregistered. Tests override it.
final kemlockPushTokenProvider = Provider<Future<KmPushToken?> Function()>((ref) {
  var asked = false;
  return () async {
    try {
      // Asking the push service for a token is a request: offline mode makes none (add-offline-mode)
      if (ref.read(networkGateProvider).offline) {
        return null;
      }
      final token = await ref.read(pushTokensProvider).pushToken();
      if (token == null) {
        return null;
      }
      if (!asked && token.kind == pushKindApns) {
        asked = true;
        try {
          unawaited(ref.read(approvalNoticeProvider).requestPermission().then<void>((_) {}, onError: (Object _) {}));
        } on Object {
          // No notification service: the request shows at the next open
        }
      }
      return (kind: token.kind, token: token.token);
    } on Object {
      return null;
    }
  };
});

/// Takes the phone's push token back from the server, when the push switch is turned off or the distributor ended the
/// registration. Throws what the request throws; the caller lets it go. Does nothing while no host runs (no open vault). Tests
/// override it.
final kemlockPushOffProvider = Provider<Future<void> Function(KemlockTarget target)>(
  (ref) => (target) async {
    final host = ref.read(kemlockHostProvider);
    if (host != null) {
      await host.unregisterPush(target);
    }
  },
);
