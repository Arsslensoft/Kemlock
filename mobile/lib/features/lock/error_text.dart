import 'package:flutter/services.dart';

import '../../platform/unlock_keys.dart';
import '../../vault/biometrics.dart';
import '../../vault/vault_store.dart';

/// What to tell the person about [error], as the web app showed an
/// `Error`'s message: the message of errors that carry one written for
/// people (the system's biometric prompt, the hardware key's, a platform
/// call, a missing vault), else [fallback].
String errorText(Object error, String fallback) => switch (error) {
  BiometricError(:final message) => message ?? fallback,
  UnlockKeyFailed(:final message) => message ?? fallback,
  UnlockKeyPromptFailed(:final message) => message ?? fallback,
  PlatformException(:final message) => message ?? fallback,
  VaultMissingError(:final message) => message,
  _ => fallback,
};
