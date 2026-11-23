/// A key's PIN (`authenticatorClientPIN`, CTAP 2.1 section 6.5): how many
/// tries are left, setting and changing it, and trading it for the token
/// that the commands the PIN guards are signed with.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../crypto/p256.dart';
import '../cbor.dart';
import '../connection.dart';
import 'ctap.dart';
import 'get_info.dart';
import 'pin_protocol.dart';

/// Why something about a key's PIN did not go through.
sealed class PinError implements Exception {
  const PinError();
}

/// The PIN typed is not the key's. [retries] is how many tries the key
/// says are left, when it could be asked.
class PinWrong extends PinError {
  const PinWrong(this.retries);

  final int? retries;
}

/// Wrong PINs came three times in a row: the key takes no more until it
/// has been unplugged, or taken away, and presented again.
class PinLockedUntilReconnected extends PinError {
  const PinLockedUntilReconnected();
}

/// No tries are left. Only a reset, which erases the key, clears this.
class PinBlocked extends PinError {
  const PinBlocked();
}

/// The key has no PIN.
class PinNotSet extends PinError {
  const PinNotSet();
}

/// The key refused the new PIN under rules of its own.
class PinRefusedByKey extends PinError {
  const PinRefusedByKey();
}

/// The new PIN has fewer than [minimum] characters. Nothing was sent.
class PinTooShort extends PinError {
  const PinTooShort(this.minimum);

  final int minimum;
}

/// The new PIN is longer than the 63 bytes a key takes. Nothing was sent.
class PinTooLong extends PinError {
  const PinTooLong();
}

/// The key offers no PIN protocol the app knows.
class PinProtocolUnknown extends PinError {
  const PinProtocolUnknown();
}

/// What a PIN token may be used for.
abstract final class PinPermission {
  /// Making a credential.
  static const makeCredential = 0x01;

  /// Using a credential.
  static const getAssertion = 0x02;

  /// Listing and deleting passkeys.
  static const credentialManagement = 0x04;

  /// Managing fingerprints.
  static const bioEnrollment = 0x08;
}

/// The longest PIN a key takes, in UTF-8 bytes.
const pinMaxBytes = 63;

/// Checks a new PIN, as UTF-8, against the rules every key shares: at
/// least [minimum] characters (code points) and at most 63 bytes. Throws
/// [PinTooShort] or [PinTooLong].
void checkNewPin(Uint8List pin, int minimum) {
  final characters = utf8.decode(pin, allowMalformed: true).runes.length;
  if (characters < minimum) throw PinTooShort(minimum);
  if (pin.length > pinMaxBytes) throw const PinTooLong();
}

/// A token the key gave for a PIN, and the protocol its tags are made with.
class PinToken {
  const PinToken(this.protocol, this.token);

  final PinProtocol protocol;
  final Uint8List token;

  /// The `pinUvAuthParam` of a command whose signed bytes are [message].
  Uint8List authenticate(List<int> message) => protocol.authenticate(token, message);
}

/// The PIN commands of one key, over its FIDO [session].
class ClientPin {
  ClientPin(this.session, this.info, {this.platformKey, this.iv});

  final CtapSession session;
  final AuthenticatorInfo info;

  /// The app's key pair and the IV of protocol 2, fixed by tests; fresh
  /// and random otherwise.
  final P256KeyPair Function()? platformKey;
  final Uint8List Function()? iv;

  /// The protocol used with this key: the first it lists that the app
  /// knows. Throws [PinProtocolUnknown] when there is none.
  PinProtocol get protocol => PinProtocol.choose(info.pinUvAuthProtocols) ?? (throw const PinProtocolUnknown());

  /// Whether the key's PIN can be managed here at all.
  bool get supported => PinProtocol.choose(info.pinUvAuthProtocols) != null;

  Future<Map<int, Object?>> _send(int subCommand, [Map<int, Object?> more = const {}]) =>
      session.request(CtapCommand.clientPin, {1: protocol.number, 2: subCommand, ...more});

  /// How many tries are left before the key locks its PIN for good.
  Future<int> retries() async {
    final retries = (await _send(1))[3];
    if (retries is! int) throw const CtapError(CtapStatus.invalidParameter);
    return retries;
  }

  Future<PinEncapsulation> _agree() async {
    final peer = cborIntMap((await _send(2))[1]);
    return protocol.encapsulate(peer, platformKey: platformKey?.call());
  }

  Uint8List _encrypt(Uint8List secret, Uint8List plaintext) => protocol.encrypt(secret, plaintext, iv: iv?.call());

  /// The PIN padded with zeros to the 64 bytes it is sent as.
  static Uint8List _padded(Uint8List pin) => Uint8List(64)..setAll(0, pin);

  /// The first 16 bytes of the PIN's SHA-256, which stand for it.
  static Uint8List _hash(Uint8List pin) => Uint8List.fromList(sha256.convert(pin).bytes.sublist(0, 16));

  /// Sets [pin], UTF-8, on a key that has none. Throws [PinTooShort] or
  /// [PinTooLong] before anything is sent, and [PinRefusedByKey] when the
  /// key's own rules refuse it.
  Future<void> setPin(Uint8List pin) async {
    checkNewPin(pin, info.minPinLength);
    final agreed = await _agree();
    final newPinEnc = _encrypt(agreed.sharedSecret, _padded(pin));
    await _mapped(() => _send(3, {3: agreed.keyAgreement, 4: protocol.authenticate(agreed.sharedSecret, newPinEnc), 5: newPinEnc}));
  }

  /// Changes the PIN from [current] to [next], both UTF-8. Throws as
  /// [setPin] does for [next], and as [token] does for a wrong [current].
  Future<void> changePin(Uint8List current, Uint8List next) async {
    checkNewPin(next, info.minPinLength);
    final agreed = await _agree();
    final newPinEnc = _encrypt(agreed.sharedSecret, _padded(next));
    final pinHashEnc = _encrypt(agreed.sharedSecret, _hash(current));
    await _mapped(
      () => _send(4, {
        3: agreed.keyAgreement,
        4: protocol.authenticate(agreed.sharedSecret, [...newPinEnc, ...pinHashEnc]),
        5: newPinEnc,
        6: pinHashEnc,
      }),
    );
  }

  /// Trades [pin], UTF-8, for a token: one that only allows [permissions]
  /// (see [PinPermission]) where the key hands those out, and the older
  /// all-purpose token where it does not, as keys from before CTAP 2.1.
  ///
  /// Throws [PinWrong] with the tries left, [PinLockedUntilReconnected],
  /// [PinBlocked] or [PinNotSet]. The PIN is sent once: after a refusal
  /// nothing is tried again until the caller calls again.
  ///
  /// [rpId] ties a token for making or using a credential to one relying
  /// party, as CTAP 2.1 asks with those permissions.
  Future<PinToken> token(Uint8List pin, {required int permissions, String? rpId}) async {
    final agreed = await _agree();
    final pinHashEnc = _encrypt(agreed.sharedSecret, _hash(pin));
    final answer = await _mapped(
      () => info.pinUvAuthToken
          ? _send(9, {3: agreed.keyAgreement, 6: pinHashEnc, 9: permissions, 10: ?rpId})
          : _send(5, {3: agreed.keyAgreement, 6: pinHashEnc}),
    );
    final encrypted = answer[2];
    if (encrypted is! Uint8List) throw const CtapError(CtapStatus.invalidParameter);
    return PinToken(protocol, protocol.decrypt(agreed.sharedSecret, encrypted));
  }

  /// Runs a PIN command and turns the key's refusals into [PinError]s.
  Future<Map<int, Object?>> _mapped(Future<Map<int, Object?>> Function() command) async {
    try {
      return await command();
    } on CtapError catch (error) {
      switch (error.status) {
        case CtapStatus.pinInvalid:
          int? left;
          try {
            left = await retries();
          } on CtapError {
            // The key will not say: the PIN is still wrong.
          }
          throw PinWrong(left);
        case CtapStatus.pinAuthBlocked:
          throw const PinLockedUntilReconnected();
        case CtapStatus.pinBlocked:
          throw const PinBlocked();
        case CtapStatus.pinNotSet:
          throw const PinNotSet();
        case CtapStatus.pinPolicyViolation:
          throw const PinRefusedByKey();
        default:
          rethrow;
      }
    }
  }
}
