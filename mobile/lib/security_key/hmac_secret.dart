/// A secret from a security key, for opening a vault (openspec:
/// add-security-key-unlock, decisions 4 to 6): a credential made with
/// FIDO2's `hmac-secret` extension (CTAP 2.1, section 12.5), and the 32
/// bytes the key gives for it and a salt, HMAC-SHA-256(CredRandom, salt).
///
/// The credential is not discoverable: it takes none of the key's passkey
/// places, is in no list the key gives, and says nothing of Kemlock to
/// whoever finds the key. Its id is kept by the vault and sent back at
/// every read. The salts and the outputs cross the link encrypted under
/// the PIN protocol's shared secret.
///
/// Nothing here was run against a real key yet: it is written from the
/// CTAP text and tested against the software key of `test/security_key`.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../crypto/bytes.dart';
import '../crypto/p256.dart';
import 'cbor.dart';
import 'connection.dart';
import 'fido/client_pin.dart';
import 'fido/ctap.dart';
import 'fido/get_info.dart';
import 'fido/pin_protocol.dart';

/// The relying party the vault's credentials are made under. It is not a
/// domain name, so no browser can ever hand these credentials to a website.
/// It never changes: another one would orphan every enrolled key.
const vaultUnlockRpId = 'kemlock:vault-unlock';

/// The `credProtect` level at which a credential is used only once the key
/// has verified its owner (`userVerificationRequired`).
const credProtectUvRequired = 3;

/// Why a key gave no secret.
sealed class HmacSecretError implements Exception {
  const HmacSecretError();
}

/// The key does not offer `hmac-secret`, or made a credential without it.
class KeyLacksHmacSecret extends HmacSecretError {
  const KeyLacksHmacSecret();
}

/// The key already holds one of the credentials it was told to exclude: it
/// is enrolled already.
class CredentialAlreadyOnKey extends HmacSecretError {
  const CredentialAlreadyOnKey();
}

/// The key holds none of the credentials it was asked for.
class NoCredentialOnKey extends HmacSecretError {
  const NoCredentialOnKey();
}

/// The key answered without having verified its owner by PIN or
/// fingerprint. Its answer is not used.
class KeyDidNotVerifyOwner extends HmacSecretError {
  const KeyDidNotVerifyOwner();
}

/// The key's answer is not what the standard says it is.
class MalformedKeyAnswer extends HmacSecretError {
  const MalformedKeyAnswer(this.message);

  final String message;

  @override
  String toString() => 'MalformedKeyAnswer: $message';
}

/// A credential a key just made.
class MadeCredential {
  const MadeCredential({required this.id, this.credProtect});

  final Uint8List id;

  /// The `credProtect` level the key says it gave the credential, when it
  /// says.
  final int? credProtect;
}

/// What a key gave for a credential and one or two salts.
class SecretReading {
  const SecretReading({required this.credential, required this.output, this.second});

  /// The credential that answered, one of those asked for.
  final Uint8List credential;

  /// 32 bytes for the first salt.
  final Uint8List output;

  /// 32 bytes for the second salt, when there was one.
  final Uint8List? second;
}

/// Whether a key ties the secret of the credential it [made] to its PIN or
/// fingerprint (decision 6): a CTAP 2.1 key keeps a different secret for
/// when its owner was not verified, and a credential at the highest
/// `credProtect` level is not used without that check at all. A key that
/// does neither gives its one secret on a touch.
bool tiesSecretToOwner(AuthenticatorInfo info, MadeCredential made) =>
    info.versions.contains('FIDO_2_1') || (info.extensions.contains('credProtect') && made.credProtect == credProtectUvRequired);

/// The `hmac-secret` exchange with one key, over its FIDO [session].
class HmacSecret {
  HmacSecret(this.session, this.info, {this.platformKey, this.iv, Uint8List Function(int length)? random})
    : _random = random ?? randomBytes;

  final CtapSession session;
  final AuthenticatorInfo info;

  /// The app's key pair and the IV of protocol 2, fixed by tests; fresh
  /// and random otherwise.
  final P256KeyPair Function()? platformKey;
  final Uint8List Function()? iv;
  final Uint8List Function(int length) _random;

  /// Whether the key says it can give a secret.
  bool get supported => info.extensions.contains('hmac-secret') && PinProtocol.choose(info.pinUvAuthProtocols) != null;

  /// What says how the key's owner was verified: the tag of a PIN [token]
  /// over [clientDataHash], or, without a token, the request that the key
  /// use its own fingerprint reader.
  static Map<int, Object?> _verification(PinToken? token, Uint8List clientDataHash, {required int options, required int tag}) =>
      token == null
      ? {
          options: {'uv': true},
        }
      : {tag: token.authenticate(clientDataHash), tag + 1: token.protocol.number};

  /// Makes the vault's credential on the key (decision 4): not
  /// discoverable, ES256, with `hmac-secret`, and at the highest
  /// `credProtect` level where the key has that extension. [exclude] holds
  /// the vault's other credentials, so a key already enrolled refuses.
  ///
  /// Throws [KeyLacksHmacSecret], [CredentialAlreadyOnKey],
  /// [KeyDidNotVerifyOwner], or a [CtapError] for any other refusal.
  Future<MadeCredential> makeCredential({PinToken? token, List<Uint8List> exclude = const []}) async {
    if (!supported) throw const KeyLacksHmacSecret();
    final clientDataHash = _random(32);
    final Map<int, Object?> answer;
    try {
      answer = await session.request(CtapCommand.makeCredential, {
        1: clientDataHash,
        2: {'id': vaultUnlockRpId, 'name': 'Kemlock'},
        3: {'id': _random(16), 'name': 'Kemlock'},
        4: [
          {'alg': -7, 'type': 'public-key'},
        ],
        if (exclude.isNotEmpty)
          5: [
            for (final id in exclude) {'id': id, 'type': 'public-key'},
          ],
        6: {'hmac-secret': true, if (info.extensions.contains('credProtect')) 'credProtect': credProtectUvRequired},
        // No "rk": the credential is not discoverable.
        ..._verification(token, clientDataHash, options: 7, tag: 8),
      });
    } on CtapError catch (error) {
      if (error.status == CtapStatus.credentialExcluded) throw const CredentialAlreadyOnKey();
      rethrow;
    }
    final data = _AuthData.parse(answer[2], vaultUnlockRpId);
    final id = data.credentialId;
    if (id == null || id.isEmpty) throw const MalformedKeyAnswer('The key made no credential.');
    if (!data.userVerified) throw const KeyDidNotVerifyOwner();
    if (data.extensions['hmac-secret'] != true) throw const KeyLacksHmacSecret();
    final level = data.extensions['credProtect'];
    return MadeCredential(id: id, credProtect: level is int ? level : null);
  }

  /// Reads what the key gives for [salt], and for [secondSalt] when given,
  /// with whichever credential of [allow] it holds. Each salt is 32 bytes.
  ///
  /// Throws [NoCredentialOnKey] when the key holds none of them,
  /// [KeyDidNotVerifyOwner] when it answered without checking its owner,
  /// or a [CtapError] for any other refusal.
  Future<SecretReading> read({PinToken? token, required List<Uint8List> allow, required Uint8List salt, Uint8List? secondSalt}) async =>
      (await _read(token: token, allow: allow, salt: salt, secondSalt: secondSalt, rpId: vaultUnlockRpId)).reading;

  /// An assertion for [rpId] over [clientDataHash], as a browser would ask a website's key, that also asks
  /// for the secret of [salt] (WebAuthn's PRF is this extension with the salt mapping
  /// `SHA-256("WebAuthn PRF" || 0x00 || input)`, see [webAuthnPrfSalt]). It gives the secret and what a server
  /// verifies the sign-in with: the authenticator data and the signature. With [discoverable] the request has no
  /// allow list, and the key offers a credential of its own for [rpId], which it must name; its user handle comes
  /// back too. Throws what [read] throws.
  Future<({SecretReading reading, Uint8List authenticatorData, Uint8List signature, Uint8List? userHandle})> assertWithSecret({
    PinToken? token,
    required String rpId,
    required Uint8List clientDataHash,
    required List<Uint8List> allow,
    bool discoverable = false,
    required Uint8List salt,
  }) => _read(token: token, allow: allow, salt: salt, rpId: rpId, clientDataHash: clientDataHash, discoverable: discoverable);

  Future<({SecretReading reading, Uint8List authenticatorData, Uint8List signature, Uint8List? userHandle})> _read({
    PinToken? token,
    required List<Uint8List> allow,
    required Uint8List salt,
    Uint8List? secondSalt,
    required String rpId,
    Uint8List? clientDataHash,
    bool discoverable = false,
  }) async {
    if (!supported) throw const KeyLacksHmacSecret();
    if (allow.isEmpty && !discoverable) throw const NoCredentialOnKey();
    if (salt.length != 32 || (secondSalt != null && secondSalt.length != 32)) throw ArgumentError('A salt is 32 bytes.');
    final protocol = token?.protocol ?? PinProtocol.choose(info.pinUvAuthProtocols)!;
    // A fresh agreement for this read: the salts and the outputs cross the link under its secret.
    final peer = cborIntMap((await session.request(CtapCommand.clientPin, {1: protocol.number, 2: 2}))[1]);
    final agreed = protocol.encapsulate(peer, platformKey: platformKey?.call());
    final saltEnc = protocol.encrypt(agreed.sharedSecret, Uint8List.fromList([...salt, ...?secondSalt]), iv: iv?.call());
    final hash = clientDataHash ?? _random(32);
    final Map<int, Object?> answer;
    try {
      answer = await session.request(CtapCommand.getAssertion, {
        1: rpId,
        2: hash,
        if (allow.isNotEmpty)
          3: [
            for (final id in allow) {'id': id, 'type': 'public-key'},
          ],
        4: {
          'hmac-secret': {
            1: agreed.keyAgreement,
            2: saltEnc,
            3: protocol.authenticate(agreed.sharedSecret, saltEnc),
            // Protocol 1 is what a key from before CTAP 2.1 assumes, and such a key may refuse the member.
            if (protocol.number != 1) 4: protocol.number,
          },
        },
        ..._verification(token, hash, options: 5, tag: 6),
      });
    } on CtapError catch (error) {
      if (error.status == CtapStatus.noCredentials) throw const NoCredentialOnKey();
      rethrow;
    }
    final data = _AuthData.parse(answer[2], rpId);
    if (!data.userVerified) throw const KeyDidNotVerifyOwner();
    final encrypted = data.extensions['hmac-secret'];
    if (encrypted is! Uint8List) throw const KeyLacksHmacSecret();
    final Uint8List outputs;
    try {
      outputs = protocol.decrypt(agreed.sharedSecret, encrypted);
    } on PinProtocolError catch (error) {
      throw MalformedKeyAnswer(error.message);
    }
    if (outputs.length != (secondSalt == null ? 32 : 64)) throw const MalformedKeyAnswer('The key’s secret has the wrong length.');
    // A key may leave the credential out when it was asked for one only.
    final named = cborTextMap(answer[1])['id'];
    final Uint8List credential;
    if (named is Uint8List) {
      credential = named;
    } else if (allow.length == 1 && !discoverable) {
      credential = allow.single;
    } else {
      throw const MalformedKeyAnswer('The key does not say which credential answered.');
    }
    if (!discoverable && !allow.any((id) => _same(id, credential))) {
      throw const MalformedKeyAnswer('The key answered with another credential than it was asked for.');
    }
    final signature = answer[3];
    if (signature is! Uint8List) throw const MalformedKeyAnswer('The answer has no signature.');
    return (
      reading: SecretReading(
        credential: Uint8List.fromList(credential),
        output: Uint8List.fromList(outputs.sublist(0, 32)),
        second: secondSalt == null ? null : Uint8List.fromList(outputs.sublist(32)),
      ),
      authenticatorData: answer[2]! as Uint8List,
      signature: signature,
      userHandle: _userHandle(answer[4]),
    );
  }
}

/// The salt WebAuthn's PRF extension gives a key for an [input]: `SHA-256("WebAuthn PRF" || 0x00 || input)`,
/// 32 bytes. A browser maps the relying party's `eval.first` this way before it asks the key's `hmac-secret`.
Uint8List webAuthnPrfSalt(List<int> input) => Uint8List.fromList(sha256.convert([...'WebAuthn PRF'.codeUnits, 0, ...input]).bytes);

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// The authenticator data of a credential or an assertion (WebAuthn,
/// section 6.1), as far as the exchange needs it.
class _AuthData {
  _AuthData(this.flags, this.credentialId, this.extensions);

  final int flags;
  final Uint8List? credentialId;
  final Map<String, Object?> extensions;

  /// The key verified its owner, by PIN or fingerprint.
  bool get userVerified => flags & 0x04 != 0;

  static _AuthData parse(Object? value, String rpId) {
    if (value is! Uint8List || value.length < 37) throw const MalformedKeyAnswer('The answer has no authenticator data.');
    if (!_same(value.sublist(0, 32), sha256.convert(rpId.codeUnits).bytes)) {
      throw const MalformedKeyAnswer('The answer is for another relying party.');
    }
    final flags = value[32];
    var offset = 37;
    Uint8List? credentialId;
    try {
      if (flags & 0x40 != 0) {
        // The key's model (16 bytes), the credential id and its length, then its public key.
        if (value.length < offset + 18) throw const MalformedKeyAnswer('The credential is cut short.');
        final length = value[offset + 16] << 8 | value[offset + 17];
        offset += 18;
        if (value.length < offset + length) throw const MalformedKeyAnswer('The credential is cut short.');
        credentialId = Uint8List.fromList(value.sublist(offset, offset + length));
        offset += length;
        offset += cborDecodeFirst(Uint8List.sublistView(value, offset)).$2;
      }
      final extensions = flags & 0x80 != 0
          ? cborTextMap(cborDecodeFirst(Uint8List.sublistView(value, offset)).$1)
          : const <String, Object?>{};
      return _AuthData(flags, credentialId, extensions);
    } on CborError catch (error) {
      throw MalformedKeyAnswer(error.message);
    }
  }
}

/// The user handle of a discoverable credential in a key's answer, which names the credential's user as its `id`.
Uint8List? _userHandle(Object? user) {
  final id = cborTextMap(user)['id'];
  return id is Uint8List && id.isNotEmpty ? Uint8List.fromList(id) : null;
}
