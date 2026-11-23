import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/sync/kemlock/km_platform_passkey.dart';
import 'security_keys.dart' show SecurityKeyCancelled;

/// The phone's own passkeys for Kemlock Server sign-in (add-kemlock-server-sync, task 7.2): Android 14 and
/// later through Credential Manager (`android/.../platformpasskey/PlatformPasskeyChannel.kt`), in both builds,
/// as it is part of the platform and needs no Play services. iOS has none: an app can use a platform passkey
/// only for a relying party associated with it, which no self-hosted domain can be, so it is never offered
/// there, and a build without the native side offers nothing either.
///
/// The channel opens no connection of its own: the credential provider talks to the person, and the server
/// only hears the signed answer, through the gated client. It is not a network caller.
class ChannelPlatformPasskeys implements KmPlatformPasskeys {
  ChannelPlatformPasskeys({bool? ios}) : _ios = ios ?? Platform.isIOS;

  final bool _ios;

  static const _channel = MethodChannel('com.kemlock.app/platform_passkeys');

  @override
  Future<KmPlatformPasskeyInfo> info() async {
    if (_ios) return KmPlatformPasskeyInfo.unsupported;
    try {
      final answer = await _channel.invokeMapMethod<String, Object?>('info');
      final package = answer?['package'];
      return KmPlatformPasskeyInfo(supported: answer?['supported'] == true, package: package is String ? package : null);
    } on MissingPluginException {
      return KmPlatformPasskeyInfo.unsupported;
    } on PlatformException {
      return KmPlatformPasskeyInfo.unsupported;
    }
  }

  @override
  Future<String> get(String requestJson) async {
    try {
      final response = await _channel.invokeMethod<String>('get', {'requestJson': requestJson});
      if (response == null || response.isEmpty) throw const KmPlatformPasskeyError('failed', 'The phone gave back nothing.');
      return response;
    } on MissingPluginException {
      throw const KmPlatformPasskeyError('unsupported');
    } on PlatformException catch (e) {
      // Closing the picker is a cancel, not a failure
      if (e.code == 'cancelled') throw const SecurityKeyCancelled();
      throw KmPlatformPasskeyError(e.code, e.message);
    }
  }
}

/// The phone's credential provider. Tests put a fake in its place.
final platformPasskeysProvider = Provider<KmPlatformPasskeys>((ref) => ChannelPlatformPasskeys());
