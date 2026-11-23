import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// The system's biometric prompt failed in a way worth telling the person
/// about. [message] is the system's description, when it gave one.
class BiometricError implements Exception {
  const BiometricError([this.message]);

  final String? message;

  @override
  String toString() => message ?? 'Biometric authentication failed.';
}

/// Face ID, Touch ID or the fingerprint sensor: the gate in front of the
/// stored biometric unlock, as `@aparajita/capacitor-biometric-auth` was.
abstract interface class Biometrics {
  /// True when the phone has biometrics set up that the app can use.
  Future<bool> isAvailable();

  /// Shows the system prompt with [reason]. True when the person passed it,
  /// false when they cancelled; throws [BiometricError] when it can't run.
  Future<bool> authenticate(String reason);
}

/// [Biometrics] through `local_auth`, biometrics only, without the device
/// passcode as a fallback, as the Capacitor app asked for.
class LocalAuthBiometrics implements Biometrics {
  LocalAuthBiometrics([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } on LocalAuthException catch (e) {
      if (e.code == LocalAuthExceptionCode.userCanceled || e.code == LocalAuthExceptionCode.systemCanceled) return false;
      throw BiometricError(e.description);
    } on PlatformException catch (e) {
      throw BiometricError(e.message);
    }
  }
}
