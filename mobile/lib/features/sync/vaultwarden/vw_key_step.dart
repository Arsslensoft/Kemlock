/// The security key step of signing in to Vaultwarden
/// (openspec: add-vaultwarden-security-key): from the server's challenge
/// and the address being signed in to, to the token the server takes,
/// by asking a key the person presents. Kemlock stands where a browser
/// would: it asks the key only about the server's own name, and the PIN
/// only when the key demands it.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../core/public_suffixes.dart';
import '../../../platform/security_keys.dart';
import '../../../security_key/connection.dart';
import '../../../security_key/fido/client_pin.dart';
import '../../../security_key/fido/ctap.dart';
import '../../../security_key/fido/get_assertion.dart';
import '../../../security_key/fido/get_info.dart';
import 'vw_webauthn.dart';

/// Why the key step gave no token. The names are the ends of the
/// `vaultwarden.key.*` message ids.
enum VwKeyProblem {
  /// The challenge names another site than the address signed in to. The
  /// key was never asked.
  otherAddress,

  /// The key holds none of the account's credentials.
  notRegistered,

  /// As [notRegistered], and the challenge carries the U2F-era address: the
  /// key may have been registered before WebAuthn, which Kemlock does not serve.
  registeredOldWay,

  /// The key speaks only the older U2F, or has no FIDO application.
  notFido2,

  /// A key plugged into an iPhone: iOS gives apps FIDO2 over NFC only.
  iphoneNfcOnly,

  /// Nobody touched the key in the time it waits.
  notTouched,
}

/// The key step failed for a reason of its own. Losing the key, a locked
/// PIN and a cancellation are the connection's and the PIN's own errors.
class VwKeyStepError implements Exception {
  const VwKeyStepError(this.problem, {this.rpId});

  final VwKeyProblem problem;

  /// The name the server's challenge gave.
  final String? rpId;

  @override
  String toString() => 'VwKeyStepError(${problem.name}${rpId == null ? '' : ', $rpId'})';
}

/// What the person is waited on for.
enum VwKeyStatus {
  /// The key is to be presented, or is being talked to.
  waiting,

  /// The key waits for a touch.
  touch,
}

/// Asks the person for the key's PIN, UTF-8, after a [wrong] one when
/// there was one. Null when they back out.
typedef VwAskPin = Future<Uint8List?> Function(PinWrong? wrong);

/// Gets a key's answer to a Vaultwarden challenge.
///
/// ```dart
/// final step = VwKeyStep(keys: keys, askPin: (wrong) => promptForPin(wrong));
/// final token = await step.answer(challenge, server);
/// await api.signIn(server, …, step: VwSecondStep(provider: VwTwoFactor.webauthn, code: token));
/// ```
class VwKeyStep {
  VwKeyStep({
    required this.keys,
    required this.askPin,
    this.hold,
    this.nfcMessage = '',
    this.nfcFailure,
    this.onStatus,
    this.now = DateTime.now,
    this.suffixes,
  });

  final SecurityKeys keys;
  final VwAskPin askPin;

  /// The Public Suffix List, which tells which parent domain of the address
  /// the server may name for the key ([vwKeyRpIdAllowed]); without it, only
  /// the address's own host.
  final PublicSuffixList? suffixes;

  /// Takes a hold on "lock when hidden" while a system sheet covers the
  /// app; see [SecurityKeyHub.hold].
  final void Function() Function()? hold;

  /// The texts of iPhone's NFC sheet.
  final String nfcMessage;
  final String? nfcFailure;

  /// Told what the person is waited on for, as it changes.
  final void Function(VwKeyStatus status)? onStatus;
  final DateTime Function() now;

  SecurityKeyHub? _hub;

  /// The token for [challenge] while signing in to [server]: the JSON of
  /// the key's assertion, to send as the second step's token.
  ///
  /// Throws a [VwKeyStepError], a `SecurityKeyError` (cancelled, removed,
  /// timed out, NFC off, no way to reach a key), a [PinError] for a PIN
  /// the key locked, or a [CtapError] for any other refusal. A challenge
  /// for another site is refused before any key is looked for.
  Future<String> answer(VwKeyChallenge challenge, Uri server) async {
    if (!vwKeyRpIdAllowed(challenge.rpId, server, suffixes: suffixes)) {
      throw VwKeyStepError(VwKeyProblem.otherAddress, rpId: challenge.rpId);
    }
    final clientData = vwKeyClientData(challenge: challenge.challenge, origin: vwKeyOrigin(server));
    final hash = vwKeyClientDataHash(clientData);
    final hub = _hub = SecurityKeyHub(keys, now: now, hold: hold);
    Uint8List? pin;
    try {
      while (true) {
        onStatus?.call(VwKeyStatus.waiting);
        try {
          final typed = pin;
          final (assertion, asked) = await hub.runOnKey(
            (connection) => _assert(connection, challenge, hash, typed),
            nfcMessage: nfcMessage,
            nfcFailure: nfcFailure,
          );
          return vwKeyToken(
            // A key may leave the credential out when it was asked about one only.
            credentialId: assertion.credentialId ?? asked.single,
            authenticatorData: assertion.authenticatorData,
            clientData: clientData,
            signature: assertion.signature,
          );
        } on AssertionPinRequired {
          // Asked once: a key that still wants a PIN after one was given is refusing.
          if (pin != null) throw const CtapError(CtapStatus.pinRequired);
          pin = await askPin(null);
        } on PinWrong catch (wrong) {
          _wipe(pin);
          pin = await askPin(wrong);
        }
        if (pin == null) throw const SecurityKeyCancelled();
      }
    } finally {
      _wipe(pin);
      _hub = null;
      await hub.stop();
    }
  }

  /// The person cancels: the wait for a key, or the request in flight, ends
  /// with a `SecurityKeyCancelled`.
  Future<void> cancel() async => _hub?.cancel();

  static void _wipe(Uint8List? pin) => pin?.fillRange(0, pin.length, 0);

  Future<(Assertion, List<Uint8List>)> _assert(
    SecurityKeyConnection connection,
    VwKeyChallenge challenge,
    Uint8List hash,
    Uint8List? pin,
  ) async {
    connection.onTouchNeeded = (needed) => onStatus?.call(needed ? VwKeyStatus.touch : VwKeyStatus.waiting);
    try {
      final session = await connection.openFido();
      final answer = await session.request(CtapCommand.getInfo);
      final info = AuthenticatorInfo.parse(answer);
      if (!info.fido2) throw const VwKeyStepError(VwKeyProblem.notFido2);
      final token = pin == null
          ? null
          : await ClientPin(session, info).token(pin, permissions: pinPermissionGetAssertion, rpId: challenge.rpId);
      // A key takes a limited allow list: the ids go in batches of what it takes.
      final size = maxCredentialsInList(answer);
      final ids = challenge.allowCredentials;
      for (var start = 0; start < ids.length; start += size) {
        final batch = ids.sublist(start, start + size > ids.length ? ids.length : start + size);
        try {
          final assertion = await getAssertion(session, rpId: challenge.rpId, clientDataHash: hash, allowList: batch, token: token);
          return (assertion, batch);
        } on AssertionNoCredentials {
          continue;
        }
      }
      throw VwKeyStepError(challenge.appId == null ? VwKeyProblem.notRegistered : VwKeyProblem.registeredOldWay, rpId: challenge.rpId);
    } on FidoUnavailable catch (error) {
      // A key in an iPhone's port shows as a smartcard, and iOS carries FIDO2 over NFC only.
      final plugged = error.reason == FidoUnavailableReason.noApplication && error.kind == SecurityKeyLinkKind.smartcard;
      throw VwKeyStepError(plugged ? VwKeyProblem.iphoneNfcOnly : VwKeyProblem.notFido2);
    } on AssertionNotTouched {
      throw const VwKeyStepError(VwKeyProblem.notTouched);
    } finally {
      connection.onTouchNeeded = null;
    }
  }
}

/// Whether a phone with [capabilities] can reach a key for this step at
/// all: over NFC, or over USB on Android. A smartcard slot alone (an iPad)
/// cannot, as iOS carries FIDO2 over NFC only.
bool vwCanReachKey(SecurityKeyCapabilities capabilities) => capabilities.nfc || capabilities.usb;
