import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why the phone's hardware key for biometric unlock didn't give or keep a
/// key (openspec: harden-unlock-and-clipboard, biometric-unlock).
sealed class UnlockKeyError implements Exception {
  const UnlockKeyError();

  /// The code the platform channel sends for it.
  String get code;
}

/// The person cancelled the system's prompt.
class UnlockKeyCancelled extends UnlockKeyError {
  const UnlockKeyCancelled();

  @override
  String get code => 'cancelled';

  @override
  String toString() => 'The biometric prompt was cancelled.';
}

/// The key no longer opens: a face or fingerprint was added, the phone's
/// passcode was removed, or the key is gone.
class UnlockKeyInvalidated extends UnlockKeyError {
  const UnlockKeyInvalidated();

  @override
  String get code => 'invalidated';

  @override
  String toString() => 'The phone’s biometrics changed since biometric unlock was turned on.';
}

/// The phone has no biometrics the key can be bound to (on Android, none of
/// Class 3), or a build without the native side.
class UnlockKeyUnavailable extends UnlockKeyError {
  const UnlockKeyUnavailable();

  @override
  String get code => 'unavailable';

  @override
  String toString() => 'This phone has no biometrics Kemlock can use.';
}

/// The system's prompt itself failed: biometrics locked out after too many
/// tries, the prompt timed out, or the sensor's own error, with the
/// system's [message]. Nothing else may open the vault in its place: the
/// old entry's fallback prompt is weaker (on Android it takes Class 2
/// biometrics), and would undo the lockout.
class UnlockKeyPromptFailed extends UnlockKeyError {
  const UnlockKeyPromptFailed([this.message]);

  final String? message;

  @override
  String get code => 'prompt';

  @override
  String toString() => message ?? 'The biometric prompt failed.';
}

/// Anything else, with the system's [message] when it gave one: the
/// Keystore or Keychain failing, after the prompt was passed or before it
/// showed.
class UnlockKeyFailed extends UnlockKeyError {
  const UnlockKeyFailed([this.message]);

  final String? message;

  @override
  String get code => 'failed';

  @override
  String toString() => message ?? 'Biometric unlock failed.';
}

/// The error a platform channel [code] stands for, with its [message].
UnlockKeyError unlockKeyError(String code, [String? message]) => switch (code) {
  'cancelled' => const UnlockKeyCancelled(),
  'invalidated' => const UnlockKeyInvalidated(),
  'unavailable' => const UnlockKeyUnavailable(),
  'prompt' => UnlockKeyPromptFailed(message),
  _ => UnlockKeyFailed(message),
};

/// The phone's side of biometric unlock: a 32-byte key per vault, kept in
/// the iOS Keychain (`ios/Runner/UnlockKeyChannel.swift`) or wrapped by an
/// Android Keystore key (`android/.../unlock/UnlockKeyChannel.kt`), and
/// given out only after the system's biometric prompt, which these calls
/// show. On Android that has to be the prompt that authorises the key, so
/// `local_auth` can't show it.
abstract interface class UnlockKeys {
  /// Whether the phone has biometrics the key can be bound to: Face ID or
  /// Touch ID with a passcode set on iOS, Class 3 biometrics on Android.
  Future<bool> status();

  /// Shows the prompt with [reason], then puts [key] in the hardware for
  /// [vault], replacing any earlier one. Returns what the vault's entry
  /// keeps beside it to open it again: the wrapped key on Android, nothing
  /// on iOS. Throws an [UnlockKeyError].
  Future<String> seal(String vault, Uint8List key, String reason);

  /// Shows the prompt with [reason] and returns [vault]'s key, given the
  /// [wrap] that [seal] returned. Throws an [UnlockKeyError].
  Future<Uint8List> open(String vault, String wrap, String reason);

  /// Deletes [vault]'s key, if there is one.
  Future<void> delete(String vault);

  /// Deletes every vault's key, and no other key of the app.
  Future<void> deleteAll();
}

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
