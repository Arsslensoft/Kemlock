import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/platform/unlock_keys.dart';

/// Stands in for the phone's hardware keys: keeps each vault's key in
/// memory, answers status as the test says, and can be told to cancel,
/// invalidate or fail.
///
/// ```dart
/// final keys = FakeUnlockKeys(android: true);
/// keys.cancelNext();                  // the next prompt is cancelled
/// keys.invalidate(mainVault);         // a fingerprint was added
/// expect(keys.calls, ['seal main', 'open main']);
/// ```
class FakeUnlockKeys implements UnlockKeys {
  FakeUnlockKeys({this.available = true, this.android = false});

  /// What [status] answers.
  bool available;

  /// Behaves as Android does: [seal] gives back a wrap, which [open] needs.
  /// Otherwise as iOS does, with an empty wrap.
  bool android;

  /// Each vault's key, as the hardware holds it.
  final Map<String, Uint8List> keys = {};

  /// The wrap [seal] gave for each vault, on Android.
  final Map<String, String> wraps = {};

  /// Vaults whose key no longer opens, as after a fingerprint was added.
  final Set<String> invalidated = {};

  /// The reason of every prompt shown, in order.
  final List<String> prompts = [];

  /// Every call but [status], in order: `seal <vault>`, `open <vault>`,
  /// `delete <vault>`, `deleteAll`.
  final List<String> calls = [];

  /// Thrown by the next [seal] or [open], after its prompt, when set.
  UnlockKeyError? nextError;

  /// Called while a prompt is up.
  void Function()? onPrompt;

  /// Keeps each prompt up until it completes, when set.
  Future<void>? promptWaits;

  Override get asOverride => unlockKeysProvider.overrideWithValue(this);

  /// The next prompt is cancelled.
  void cancelNext() => nextError = const UnlockKeyCancelled();

  /// The next [seal] or [open] fails for a reason of its own.
  void failNext([String? message]) => nextError = UnlockKeyFailed(message);

  /// The next prompt itself fails, as after too many tries.
  void failPromptNext([String? message]) => nextError = UnlockKeyPromptFailed(message);

  /// [vault]'s key stops opening, as when biometrics change.
  void invalidate(String vault) => invalidated.add(vault);

  Future<void> _prompt(String reason) async {
    prompts.add(reason);
    onPrompt?.call();
    if (promptWaits case final waits?) await waits;
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
  }

  @override
  Future<bool> status() async => available;

  @override
  Future<String> seal(String vault, Uint8List key, String reason) async {
    calls.add('seal $vault');
    if (!available) throw const UnlockKeyUnavailable();
    await _prompt(reason);
    keys[vault] = Uint8List.fromList(key);
    invalidated.remove(vault);
    if (!android) return '';
    return wraps[vault] = b64(randomBytes(60));
  }

  @override
  Future<Uint8List> open(String vault, String wrap, String reason) async {
    calls.add('open $vault');
    if (!available) throw const UnlockKeyUnavailable();
    await _prompt(reason);
    final key = keys[vault];
    if (key == null || invalidated.contains(vault) || (android && wraps[vault] != wrap)) throw const UnlockKeyInvalidated();
    return Uint8List.fromList(key);
  }

  @override
  Future<void> delete(String vault) async {
    calls.add('delete $vault');
    keys.remove(vault);
    wraps.remove(vault);
  }

  @override
  Future<void> deleteAll() async {
    calls.add('deleteAll');
    keys.clear();
    wraps.clear();
  }
}
