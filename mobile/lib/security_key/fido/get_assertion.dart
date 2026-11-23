/// Asking a key to prove it holds a credential
/// (`authenticatorGetAssertion`, CTAP 2.1 section 6.2), for a site that
/// lists the credentials it knows: the request, the key's answer, and how
/// many credentials a key takes in one request
/// (openspec: add-vaultwarden-security-key).
library;

import 'dart:typed_data';

import '../cbor.dart';
import '../connection.dart';
import 'client_pin.dart';
import 'ctap.dart';

/// The command byte of `authenticatorGetAssertion`.
const ctapGetAssertion = 0x02;

/// The permission a PIN token needs to sign an assertion (`ga`). A token
/// with it is asked for with the site's name.
const pinPermissionGetAssertion = 0x02;

/// Why a key gave no assertion.
sealed class AssertionError implements Exception {
  const AssertionError();
}

/// The key holds none of the credentials it was asked about.
class AssertionNoCredentials extends AssertionError {
  const AssertionNoCredentials();

  @override
  String toString() => 'The key holds none of these credentials.';
}

/// The key answers only with its PIN: it is set to always verify.
class AssertionPinRequired extends AssertionError {
  const AssertionPinRequired();

  @override
  String toString() => 'The key wants its PIN first.';
}

/// Nobody touched the key in the time it waits.
class AssertionNotTouched extends AssertionError {
  const AssertionNotTouched();

  @override
  String toString() => 'The key was not touched in time.';
}

/// A key's proof: what it signed and the signature.
class Assertion {
  const Assertion({required this.credentialId, required this.authenticatorData, required this.signature, this.userHandle});

  /// The credential that signed, when the key says. A key may leave it
  /// out when it was asked about one credential only.
  final Uint8List? credentialId;

  /// The authenticator data: the hash of the site's name, the flags and
  /// the signature counter.
  final Uint8List authenticatorData;

  /// The signature over [authenticatorData] followed by the client data hash.
  final Uint8List signature;

  /// The user handle of a discoverable credential, when the key gives one.
  final Uint8List? userHandle;
}

/// The parameters of a request for [rpId] and [clientDataHash], listing
/// the credentials with the ids [allowList]. `up` is asked for; `uv` is
/// not. With [token], a token that has [pinPermissionGetAssertion] for
/// [rpId], the request carries the PIN's proof.
Map<int, Object?> getAssertionParameters({
  required String rpId,
  required Uint8List clientDataHash,
  required List<Uint8List> allowList,
  PinToken? token,
}) => {
  1: rpId,
  2: clientDataHash,
  if (allowList.isNotEmpty)
    3: [
      for (final id in allowList) {'id': id, 'type': 'public-key'},
    ],
  5: {'up': true},
  if (token != null) ...{6: token.authenticate(clientDataHash), 7: token.protocol.number},
};

/// Asks the key for an assertion. Throws [AssertionNoCredentials],
/// [AssertionPinRequired], [AssertionNotTouched], or a [CtapError] for
/// any other refusal.
Future<Assertion> getAssertion(
  CtapSession session, {
  required String rpId,
  required Uint8List clientDataHash,
  required List<Uint8List> allowList,
  PinToken? token,
}) async {
  final answer = await session.send(
    ctapGetAssertion,
    getAssertionParameters(rpId: rpId, clientDataHash: clientDataHash, allowList: allowList, token: token),
  );
  switch (answer.status) {
    case CtapStatus.ok:
      break;
    case CtapStatus.noCredentials:
      throw const AssertionNoCredentials();
    case CtapStatus.pinRequired:
      throw const AssertionPinRequired();
    case CtapStatus.userActionTimeout:
      throw const AssertionNotTouched();
    default:
      throw CtapError(answer.status);
  }
  final map = answer.map;
  final credential = cborTextMap(map[1])['id'];
  final authenticatorData = map[2];
  final signature = map[3];
  if (authenticatorData is! Uint8List || signature is! Uint8List) throw const CtapError(CtapStatus.invalidParameter);
  final handle = cborTextMap(map[4])['id'];
  return Assertion(
    credentialId: credential is Uint8List ? credential : null,
    authenticatorData: authenticatorData,
    signature: signature,
    userHandle: handle is Uint8List && handle.isNotEmpty ? handle : null,
  );
}

/// How many credentials [info], a key's `authenticatorGetInfo` answer by
/// member number, says the key takes in one allow list
/// (`maxCredentialCountInList`). A key that does not say is asked about
/// one credential at a time.
int maxCredentialsInList(Map<int, Object?> info) {
  final count = info[7];
  return count is int && count > 0 ? count : 1;
}
