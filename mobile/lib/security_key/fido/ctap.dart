/// The command and status bytes of CTAP2 (CTAP 2.1, sections 6 and 8.2),
/// and the error a key's refusal becomes.
library;

import '../connection.dart';

/// The CTAP2 commands the app sends.
abstract final class CtapCommand {
  static const makeCredential = 0x01;
  static const getAssertion = 0x02;
  static const getInfo = 0x04;
  static const clientPin = 0x06;
  static const reset = 0x07;
  static const bioEnrollment = 0x09;
  static const credentialManagement = 0x0a;

  /// The two commands as keys from before CTAP 2.1 was final have them:
  /// the same subcommands and maps, under a vendor's number.
  static const bioEnrollmentPreview = 0x40;
  static const credentialManagementPreview = 0x41;
}

/// The status bytes the app tells apart.
abstract final class CtapStatus {
  static const ok = 0x00;
  static const invalidCommand = 0x01;
  static const invalidParameter = 0x02;
  static const fingerprintDatabaseFull = 0x17;
  static const credentialExcluded = 0x19;
  static const operationDenied = 0x27;
  static const keyStoreFull = 0x28;
  static const unsupportedOption = 0x2b;
  static const invalidOption = 0x2c;
  static const keepaliveCancel = 0x2d;
  static const noCredentials = 0x2e;
  static const userActionTimeout = 0x2f;
  static const notAllowed = 0x30;
  static const pinInvalid = 0x31;
  static const pinBlocked = 0x32;
  static const pinAuthInvalid = 0x33;
  static const pinAuthBlocked = 0x34;
  static const pinNotSet = 0x35;
  static const pinRequired = 0x36;
  static const pinPolicyViolation = 0x37;
  static const invalidSubcommand = 0x3e;
  static const unauthorizedPermission = 0x40;
}

/// A key answered a request with a status other than success.
class CtapError implements Exception {
  const CtapError(this.status);

  final int status;

  @override
  String toString() => 'CtapError(0x${status.toRadixString(16).padLeft(2, '0')})';
}

/// Requests whose refusal is an error.
extension CtapRequests on CtapSession {
  /// Sends [command] with [parameters] and returns the answer's members.
  /// Throws a [CtapError] when the key answers anything but success.
  Future<Map<int, Object?>> request(int command, [Map<int, Object?>? parameters]) async {
    final answer = await send(command, parameters);
    if (answer.status != CtapStatus.ok) throw CtapError(answer.status);
    return answer.map;
  }
}
