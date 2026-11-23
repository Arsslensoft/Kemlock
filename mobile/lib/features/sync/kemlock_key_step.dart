/// A security key's answer to a Kemlock Server passkey challenge, with the PRF
/// (add-kemlock-server-sync, task 7.1): the same step as a Vaultwarden security
/// key sign-in (`vw_key_step.dart`), over the app's own CTAP stack, NFC or USB,
/// with the key's `hmac-secret` asked for the secret of WebAuthn's PRF salt.
///
/// - the client data claims the server's web-vault origin, by `vwKeyOrigin`'s
///   rule, and the key is asked only about the server's own name
///   (`vwKeyRpIdAllowed`), as a browser would;
/// - the salt is `SHA-256("WebAuthn PRF" || 0x00 || input)` ([webAuthnPrfSalt]),
///   the mapping a browser applies to the relying party's `eval.first`;
/// - a key without `hmac-secret` still signs in, with no PRF output, and the
///   account opens by an approval or the password.
///
/// The PRF output is handed to `kmPasskeySignIn`, which unwraps the root key
/// with it and wipes it.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../core/public_suffixes.dart';
import '../../crypto/account/encoding.dart';
import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/ctap.dart';
import '../../security_key/fido/get_assertion.dart';
import '../../security_key/fido/get_info.dart';
import '../../security_key/hmac_secret.dart';
import 'kemlock/km_auth_api.dart' show KmPasskeyOptions;
import 'kemlock/km_passkey.dart';
import 'vaultwarden/vw_key_step.dart' show VwAskPin, VwKeyProblem, VwKeyStatus, VwKeyStepError;
import 'vaultwarden/vw_webauthn.dart';

/// Asks a security key over NFC or USB to sign a passkey challenge and give its PRF output.
class KmKeyStep implements KmPasskeyAsserter {
  KmKeyStep({
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
  final PublicSuffixList? suffixes;

  /// Takes a hold on "lock when hidden" while a system sheet covers the app; see `SecurityKeyHub.hold`.
  final void Function() Function()? hold;
  final String nfcMessage;
  final String? nfcFailure;
  final void Function(VwKeyStatus status)? onStatus;
  final DateTime Function() now;

  SecurityKeyHub? _hub;

  @override
  Future<KmPasskeyAssertion> assertion(KmPasskeyOptions options, Uint8List prfInput, Uri server) async {
    if (!vwKeyRpIdAllowed(options.rpId, server, suffixes: suffixes)) throw VwKeyStepError(VwKeyProblem.otherAddress, rpId: options.rpId);
    final clientData = vwKeyClientData(challenge: b64urlEncode(options.challenge), origin: vwKeyOrigin(server));
    final hash = vwKeyClientDataHash(clientData);
    final salt = webAuthnPrfSalt(prfInput);
    final hub = _hub = SecurityKeyHub(keys, now: now, hold: hold);
    Uint8List? pin;
    try {
      while (true) {
        onStatus?.call(VwKeyStatus.waiting);
        try {
          final typed = pin;
          final found = await hub.runOnKey(
            (connection) => _assert(connection, options, hash, salt, typed),
            nfcMessage: nfcMessage,
            nfcFailure: nfcFailure,
          );
          return KmPasskeyAssertion(
            credentialId: found.credentialId,
            authenticatorData: found.authenticatorData,
            clientData: clientData,
            signature: found.signature,
            userHandle: found.userHandle,
            prfOutput: found.prf,
          );
        } on _PinNeeded {
          // Asked once: a key that still wants a PIN after one was given is refusing.
          if (pin != null) throw const CtapError(CtapStatus.pinRequired);
          pin = await askPin(null);
        } on AssertionPinRequired {
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

  /// The person cancels: the wait for a key, or the request in flight, ends with a `SecurityKeyCancelled`.
  Future<void> cancel() async => _hub?.cancel();

  static void _wipe(Uint8List? pin) => pin?.fillRange(0, pin.length, 0);

  Future<({Uint8List credentialId, Uint8List authenticatorData, Uint8List signature, Uint8List? userHandle, Uint8List? prf})> _assert(
    SecurityKeyConnection connection,
    KmPasskeyOptions options,
    Uint8List hash,
    Uint8List salt,
    Uint8List? pin,
  ) async {
    connection.onTouchNeeded = (needed) => onStatus?.call(needed ? VwKeyStatus.touch : VwKeyStatus.waiting);
    try {
      final session = await connection.openFido();
      final answer = await session.request(CtapCommand.getInfo);
      final info = AuthenticatorInfo.parse(answer);
      if (!info.fido2) throw const VwKeyStepError(VwKeyProblem.notFido2);
      final exchange = HmacSecret(session, info);
      if (pin == null && info.pin == KeyPinState.set && exchange.supported) throw const _PinNeeded();
      final token = pin == null
          ? null
          : await ClientPin(session, info).token(pin, permissions: pinPermissionGetAssertion, rpId: options.rpId);
      // The server's credentials are discoverable, so the allow list is empty and the key offers its own credential
      // for the name; a list that was given goes in batches of what the key takes.
      final size = maxCredentialsInList(answer);
      final ids = options.credentialIds;
      final discoverable = ids.isEmpty;
      for (var start = 0; discoverable ? start == 0 : start < ids.length; start += size) {
        final batch = discoverable ? const <Uint8List>[] : ids.sublist(start, start + size > ids.length ? ids.length : start + size);
        try {
          if (exchange.supported) {
            final read = await exchange.assertWithSecret(
              token: token,
              rpId: options.rpId,
              clientDataHash: hash,
              allow: batch,
              discoverable: discoverable,
              salt: salt,
            );
            return (
              credentialId: read.reading.credential,
              authenticatorData: read.authenticatorData,
              signature: read.signature,
              userHandle: read.userHandle,
              prf: read.reading.output,
            );
          }
          final assertion = await getAssertion(session, rpId: options.rpId, clientDataHash: hash, allowList: batch, token: token);
          return (
            credentialId:
                assertion.credentialId ??
                (batch.isEmpty ? throw VwKeyStepError(VwKeyProblem.notRegistered, rpId: options.rpId) : batch.first),
            authenticatorData: assertion.authenticatorData,
            signature: assertion.signature,
            userHandle: assertion.userHandle,
            prf: null,
          );
        } on AssertionNoCredentials {
          continue;
        } on NoCredentialOnKey {
          continue;
        }
      }
      throw VwKeyStepError(VwKeyProblem.notRegistered, rpId: options.rpId);
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

/// The key wants its PIN before it will give a secret.
class _PinNeeded implements Exception {
  const _PinNeeded();
}
