/// How this phone's push token reaches Kemlock Server (add-kemlock-server-sync, design 13). The token is not part
/// of the device body of a sign-in, which the server refuses with an unknown field; it goes to
/// `POST /kem/v1/devices/push-token` once signed in, at each sync run while the push switch is on, and is taken back
/// with `DELETE` when the person turns the switch off.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/network.dart';
import '../../platform/push.dart';
import '../../platform/reminders.dart';
import 'kemlock/km_auth_api.dart' show KmPushToken;
import 'kemlock/km_models.dart';
import 'sync_store.dart';

/// The phone's push token as the server takes it, always `apns`: only iOS has a push service. Null when there is
/// none (Android, the free build, notifications refused, offline mode, a channel that fails). A phone that
/// gives a token is asked, once, to show the notification a sign-in request raises; the answer changes nothing
/// here. Nothing waits on the answer, and the caller never waits on this: a channel that never answers only leaves
/// the token unregistered. Tests override it.
final kemlockPushTokenProvider = Provider<Future<KmPushToken?> Function()>((ref) {
  var asked = false;
  return () async {
    try {
      // Asking APNs for a token is a request: offline mode makes none (add-offline-mode)
      if (ref.read(networkGateProvider).offline) {
        return null;
      }
      final token = await ref.read(pushTokensProvider).token();
      if (token == null) {
        return null;
      }
      if (!asked) {
        asked = true;
        try {
          unawaited(ref.read(approvalNoticeProvider).requestPermission().then<void>((_) {}, onError: (Object _) {}));
        } on Object {
          // No notification service: the request shows at the next open
        }
      }
      return (kind: 'apns', token: token);
    } on Object {
      return null;
    }
  };
});

/// Takes the phone's push token back from the server when the push switch is turned off. Throws what the request
/// throws; the sheet lets it go. Does nothing while no host runs (no open vault). Tests override it.
final kemlockPushOffProvider = Provider<Future<void> Function(KemlockTarget target)>(
  (ref) => (target) async {
    final host = ref.read(kemlockHostProvider);
    if (host != null) {
      await host.unregisterPush(target);
    }
  },
);
