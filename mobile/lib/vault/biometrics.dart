import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'biometrics_interface.dart';

export 'biometrics_interface.dart';

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
