import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'unlock_keys_interface.dart';

export 'unlock_keys_interface.dart';

/// [UnlockKeys] over the app's method channel. A build without the native
/// side, such as the tests', has no biometrics and keeps no key.
class ChannelUnlockKeys implements UnlockKeys {
  const ChannelUnlockKeys();

  static const _channel = MethodChannel('com.kemlock.app/unlock');

  @override
  Future<bool> status() async {
    try {
      return await _channel.invokeMethod<bool>('status') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String> seal(String vault, Uint8List key, String reason) async =>
      await _call<String>('seal', {'vault': vault, 'key': key, 'reason': reason}) ?? '';

  @override
  Future<Uint8List> open(String vault, String wrap, String reason) async {
    final key = await _call<Uint8List>('open', {'vault': vault, 'wrap': wrap, 'reason': reason});
    if (key == null || key.length != 32) throw const UnlockKeyFailed('The phone gave back no key.');
    return key;
  }

  @override
  Future<void> delete(String vault) => _quiet('delete', {'vault': vault});

  @override
  Future<void> deleteAll() => _quiet('deleteAll');

  Future<T?> _call<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const UnlockKeyUnavailable();
    } on PlatformException catch (e) {
      throw unlockKeyError(e.code, e.message);
    }
  }

  Future<void> _quiet(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side: no key to delete.
    }
  }
}

/// The phone's hardware keys for biometric unlock; tests put a fake in its place.
final unlockKeysProvider = Provider<UnlockKeys>((ref) => const ChannelUnlockKeys());

/// The phone's elapsed time in milliseconds, on the clock that keeps
/// counting while the phone sleeps and that setting the date or time
/// doesn't move: Android's `SystemClock.elapsedRealtime`, iOS's
/// `CLOCK_MONOTONIC_RAW`. Auto-lock counts idle time with it. The unlock
/// channel answers it on both platforms; null where nothing does: in the
/// tests, or on Android while no screen of the app has registered the
/// channel.
Future<int?> readPhoneElapsedMs() async {
  try {
    return await ChannelUnlockKeys._channel.invokeMethod<int>('elapsed');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// How auto-lock reads the phone's elapsed clock; tests put their own.
final phoneElapsedProvider = Provider<Future<int?> Function()>((ref) => readPhoneElapsedMs);
