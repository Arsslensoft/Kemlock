/// The two PIN/UV auth protocols of CTAP 2.1 (section 6.5.6 and 6.5.7):
/// how the app and a key agree on a secret over P-256, and encrypt and
/// authenticate what they say about the PIN with it.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

import '../../crypto/bitwarden.dart' show hkdfExpandSha256;
import '../../crypto/p256.dart';

/// What [PinProtocol.encapsulate] gives: the app's public key for the key
/// to see, as a COSE key, and the secret the two now share.
typedef PinEncapsulation = ({Map<int, Object?> keyAgreement, Uint8List sharedSecret});

/// A value that cannot be what the protocol says it is: a peer key that is
/// no P-256 point, or a ciphertext of the wrong length.
class PinProtocolError implements Exception {
  const PinProtocolError(this.message);

  final String message;

  @override
  String toString() => 'PinProtocolError: $message';
}

final _random = Random.secure();

Uint8List _randomIv() => Uint8List.fromList([for (var i = 0; i < 16; i++) _random.nextInt(256)]);

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

/// AES-256-CBC without padding, as both protocols use it.
Uint8List _aesCbc(Uint8List key, Uint8List iv, Uint8List input, {required bool encrypt}) {
  if (input.length % 16 != 0) throw const PinProtocolError('The length is not a whole number of AES blocks.');
  final cipher = pc.CBCBlockCipher(pc.AESEngine())..init(encrypt, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

BigInt _big(Uint8List bytes) => bytes.fold(BigInt.zero, (value, byte) => value << 8 | BigInt.from(byte));

final _p = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
final _b = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);

/// Whether (x, y) is a point of P-256: y² = x³ − 3x + b. A key that is not
/// must not be multiplied with the app's private key.
bool _onP256(Uint8List x, Uint8List y) {
  final bx = _big(x);
  final by = _big(y);
  if (bx >= _p || by >= _p) return false;
  return (by * by - (bx * bx * bx - BigInt.from(3) * bx + _b)) % _p == BigInt.zero;
}

/// One of the PIN protocols.
abstract class PinProtocol {
  const PinProtocol();

  /// The protocols the app knows.
  static const known = <PinProtocol>[PinProtocolOne(), PinProtocolTwo()];

  /// The first protocol in the key's list, [offered], that the app knows,
  /// as CTAP asks of a platform. Null when it knows none of them.
  static PinProtocol? choose(List<int> offered) {
    for (final number in offered) {
      for (final protocol in known) {
        if (protocol.number == number) return protocol;
      }
    }
    return null;
  }

  /// The number the protocol goes by in messages.
  int get number;

  /// The secret the two sides share, from the ECDH x coordinate [z].
  Uint8List deriveSecret(Uint8List z);

  /// Agrees on a secret with the key whose public key is [peerKey], a COSE
  /// key from `getKeyAgreement`. [platformKey] is the app's key pair, a
  /// fresh one unless a test fixes it.
  PinEncapsulation encapsulate(Map<int, Object?> peerKey, {P256KeyPair? platformKey}) {
    final x = peerKey[-2];
    final y = peerKey[-3];
    if (x is! Uint8List || y is! Uint8List || x.length != 32 || y.length != 32) {
      throw const PinProtocolError('The key’s public key is not a P-256 point.');
    }
    if (!_onP256(x, y)) throw const PinProtocolError('The key’s public key is not a P-256 point.');
    final pair = platformKey ?? newP256KeyPair();
    final Uint8List z;
    try {
      z = p256SharedSecret(pair.d, Uint8List.fromList([0x04, ...x, ...y]));
    } on ArgumentError {
      throw const PinProtocolError('The key’s public key is not a P-256 point.');
    }
    return (
      // COSE: an EC2 key (kty 2) on P-256 (crv 1), marked ECDH-ES+HKDF-256 (alg -25) as CTAP says.
      keyAgreement: {1: 2, 3: -25, -1: 1, -2: pair.x, -3: pair.y},
      sharedSecret: deriveSecret(z),
    );
  }

  /// Encrypts [plaintext], a whole number of 16-byte blocks, with the
  /// shared secret [key]. [iv] fixes what is otherwise random, for tests.
  Uint8List encrypt(Uint8List key, Uint8List plaintext, {Uint8List? iv});

  /// Decrypts what the key encrypted with the shared secret [key].
  Uint8List decrypt(Uint8List key, Uint8List ciphertext);

  /// The tag that proves [message] comes from who holds [key]: the shared
  /// secret, or a PIN token.
  Uint8List authenticate(Uint8List key, List<int> message);
}

/// PIN protocol 1: the secret is SHA-256 of the ECDH x coordinate,
/// AES-256-CBC runs with a zero IV, and tags are the first 16 bytes of
/// HMAC-SHA-256.
class PinProtocolOne extends PinProtocol {
  const PinProtocolOne();

  @override
  int get number => 1;

  @override
  Uint8List deriveSecret(Uint8List z) => Uint8List.fromList(sha256.convert(z).bytes);

  @override
  Uint8List encrypt(Uint8List key, Uint8List plaintext, {Uint8List? iv}) => _aesCbc(key, Uint8List(16), plaintext, encrypt: true);

  @override
  Uint8List decrypt(Uint8List key, Uint8List ciphertext) => _aesCbc(key, Uint8List(16), ciphertext, encrypt: false);

  @override
  Uint8List authenticate(Uint8List key, List<int> message) => Uint8List.sublistView(_hmac(key, message), 0, 16);
}

/// PIN protocol 2: HKDF-SHA-256 makes an HMAC key and an AES key of the
/// ECDH x coordinate, AES-256-CBC runs with a random IV sent in front, and
/// tags are the whole HMAC-SHA-256.
class PinProtocolTwo extends PinProtocol {
  const PinProtocolTwo();

  @override
  int get number => 2;

  /// 64 bytes: the HMAC key, then the AES key.
  @override
  Uint8List deriveSecret(Uint8List z) {
    // HKDF-Extract with a salt of 32 zero bytes, then one Expand for each key.
    final prk = _hmac(Uint8List(32), z);
    return Uint8List.fromList([
      ...hkdfExpandSha256(prk, 'CTAP2 HMAC key'.codeUnits, 32),
      ...hkdfExpandSha256(prk, 'CTAP2 AES key'.codeUnits, 32),
    ]);
  }

  Uint8List _aesKey(Uint8List key) {
    if (key.length != 64) throw const PinProtocolError('The shared secret is not 64 bytes.');
    return Uint8List.sublistView(key, 32);
  }

  @override
  Uint8List encrypt(Uint8List key, Uint8List plaintext, {Uint8List? iv}) {
    final used = iv ?? _randomIv();
    return Uint8List.fromList([...used, ..._aesCbc(_aesKey(key), used, plaintext, encrypt: true)]);
  }

  @override
  Uint8List decrypt(Uint8List key, Uint8List ciphertext) {
    if (ciphertext.length < 16) throw const PinProtocolError('The ciphertext is too short to hold its IV.');
    return _aesCbc(_aesKey(key), Uint8List.sublistView(ciphertext, 0, 16), Uint8List.sublistView(ciphertext, 16), encrypt: false);
  }

  /// With the 64-byte shared secret the HMAC key is its first half; a PIN
  /// token is used whole.
  @override
  Uint8List authenticate(Uint8List key, List<int> message) => _hmac(key.length == 64 ? Uint8List.sublistView(key, 0, 32) : key, message);
}
