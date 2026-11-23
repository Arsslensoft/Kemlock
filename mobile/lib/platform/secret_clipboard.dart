import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/prefs.dart';

/// The phone's side of copying codes and secrets, `com.kemlock.app/clipboard`
/// (openspec: harden-unlock-and-clipboard, secret-clipboard): on Android the
/// copy carries the sensitive mark, so Android 13 and later show no preview
/// and keyboards don't suggest it; on iOS it is local only, so Universal
/// Clipboard doesn't hand it to the person's other devices, and expires
/// after the delay even when the app was killed first.
abstract interface class SensitiveClipboard {
  /// Copies [text], expiring after [seconds] where the phone can (iOS), or
  /// never when null. Returns a token naming this copy, for [clearIfOurs].
  Future<String> copy(String text, int? seconds);

  /// Clears the clipboard unless the phone can tell that something was
  /// copied after the copy [token] names.
  Future<void> clearIfOurs(String token);
}

/// [SensitiveClipboard] over the app's method channel. Without the native
/// side, as in the tests, every call throws a [MissingPluginException].
class ChannelSensitiveClipboard implements SensitiveClipboard {
  const ChannelSensitiveClipboard();

  static const _channel = MethodChannel('com.kemlock.app/clipboard');

  @override
  Future<String> copy(String text, int? seconds) async =>
      await _channel.invokeMethod<String>('copy', {'text': text, 'seconds': seconds}) ?? '';

  @override
  Future<void> clearIfOurs(String token) => _channel.invokeMethod<void>('clearIfOurs', {'token': token});
}

/// Copies codes and secrets, as `clipboard.ts` did, through the phone's
/// sensitive copy, and clears the clipboard the delay chosen in Settings
/// after the last copy, unless it is set to never, and unless something
/// else was copied since. When the phone's sensitive copy fails, it copies
/// the ordinary way and clears blindly, as before. Best effort: a phone may
/// refuse a write while the app is away.
class SecretClipboard {
  SecretClipboard(this._delay, {this._channel = const ChannelSensitiveClipboard()});

  /// How long a copy stays, or null to leave it.
  final Duration? Function() _delay;
  final SensitiveClipboard _channel;
  Timer? _clearTimer;

  /// Copies [text]; false when the phone refused.
  Future<bool> copy(String text) async {
    final delay = _delay();
    String? token;
    try {
      token = await _channel.copy(text, delay?.inSeconds);
    } catch (_) {
      // Copied unmarked, the timer still clears it
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        return false;
      }
    }
    _clearTimer?.cancel();
    _clearTimer = null;
    if (delay != null) {
      _clearTimer = Timer(delay, () {
        _clearTimer = null;
        unawaited(_clear(token));
      });
    }
    return true;
  }

  /// Clears what the copy named by [token] left, or blindly without one.
  Future<void> _clear(String? token) async {
    if (token != null) {
      try {
        return await _channel.clearIfOurs(token);
      } catch (_) {
        // Cleared the ordinary way below
      }
    }
    try {
      await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {
      // Best effort
    }
  }

  void dispose() => _clearTimer?.cancel();
}

/// The phone's sensitive copy; tests put a fake in its place.
final sensitiveClipboardProvider = Provider<SensitiveClipboard>((ref) => const ChannelSensitiveClipboard());

final secretClipboardProvider = Provider<SecretClipboard>((ref) {
  final clipboard = SecretClipboard(() => ref.read(prefsProvider).clipboardDelay, channel: ref.watch(sensitiveClipboardProvider));
  ref.onDispose(clipboard.dispose);
  return clipboard;
});
