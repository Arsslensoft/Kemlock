import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/sync/kemlock/km_sso.dart';
import 'network.dart';

/// The system browser sheet for SSO (add-kemlock-server-sync, design 9): `ASWebAuthenticationSession` on iOS
/// (`ios/Runner/BrowserAuthChannel.swift`, callback scheme `kemlock`, which delivers only to the session that
/// started it) and a Custom Tab on Android (`android/.../browserauth/BrowserAuthChannel.kt`, returning through
/// an activity filtered on `kemlock://sso`). Either way the platform checks the redirect's `state` against the
/// one given here and drops any other. The sheet is the system's: the app draws none, and never sees the
/// provider's page.
///
/// This opens a connection on the person's behalf, so it passes [NetworkGate] first: with offline mode on, no
/// sheet opens. It is one of the files `network_callers_test.dart` lists.
class ChannelBrowserAuth implements KmBrowserAuth {
  const ChannelBrowserAuth(this._gate);

  final NetworkGate _gate;

  static const _channel = MethodChannel('com.kemlock.app/browser_auth');

  @override
  Future<Uri?> authenticate(Uri url, {required String state}) async {
    _gate.check(url);
    try {
      final redirect = await _channel.invokeMethod<String>('authenticate', {'url': url.toString(), 'state': state});
      return redirect == null ? null : Uri.tryParse(redirect);
    } on MissingPluginException {
      throw const KmBrowserFailure('This build has no browser sheet.');
    } on PlatformException catch (e) {
      // The person closing the sheet is a cancel, not a failure
      if (e.code == 'cancelled') return null;
      throw KmBrowserFailure(e.message ?? e.code);
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // No native side: nothing is open
    } on PlatformException {
      // Nothing to close
    }
  }
}

/// The browser sheet for SSO. Tests put a fake in its place.
final browserAuthProvider = Provider<KmBrowserAuth>((ref) => ChannelBrowserAuth(ref.watch(networkGateProvider)));
