import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/security_key/fido/pin_protocol.dart';
import 'package:pointycastle/export.dart' as pc;

import '../hex.dart';

// Each expected value below is worked out here from plain SHA-256, HMAC
// and AES-CBC calls, and again from values OpenSSL made
// (test/fixtures/security_keys/pin_protocol_openssl.json).

Uint8List _sha(List<int> bytes) => Uint8List.fromList(sha256.convert(bytes).bytes);

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

Uint8List _aesCbc(Uint8List key, Uint8List iv, Uint8List input, {required bool encrypt}) {
  final cipher = pc.CBCBlockCipher(pc.AESEngine())..init(encrypt, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

void main() {
  final vectors = jsonDecode(File('test/fixtures/security_keys/pin_protocol_openssl.json').readAsStringSync()) as Map<String, Object?>;
  Uint8List vector(String name, [String? of]) => unhex((of == null ? vectors : vectors[of]! as Map<String, Object?>)[name]! as String);

  final platform = P256KeyPair.fromScalar(vector('d', 'platformKey'));
  final peer = P256KeyPair.fromScalar(vector('d', 'keyKey'));
  final peerCose = <int, Object?>{1: 2, 3: -25, -1: 1, -2: peer.x, -3: peer.y};
  final z = p256SharedSecret(platform.d, peer.point);
  final plaintext = vector('paddedPin');
  final iv = vector('iv', 'protocol2');
  const one = PinProtocolOne();
  const two = PinProtocolTwo();

  test('the two fixed key pairs are the ones OpenSSL made, and agree on its secret', () {
    expect(platform.point, vector('point', 'platformKey'));
    expect(peer.point, vector('point', 'keyKey'));
    expect(z, vector('z'));
    expect(p256SharedSecret(peer.d, platform.point), z);
  });

  test('offers the app’s public key as a COSE key', () {
    final agreed = one.encapsulate(peerCose, platformKey: platform);

    expect(agreed.keyAgreement, {1: 2, 3: -25, -1: 1, -2: platform.x, -3: platform.y});
    expect(one.encapsulate(peerCose).keyAgreement[-2], isNot(platform.x), reason: 'a fresh key pair unless a test fixes it');
  });

  group('protocol 1', () {
    final secret = _sha(z);

    test('shares SHA-256 of the ECDH x coordinate', () {
      expect(one.number, 1);
      expect(one.encapsulate(peerCose, platformKey: platform).sharedSecret, secret);
      expect(secret, vector('sharedSecret', 'protocol1'));
    });

    test('encrypts with AES-256-CBC and a zero IV, and decrypts it back', () {
      final expected = _aesCbc(secret, Uint8List(16), plaintext, encrypt: true);

      final ciphertext = one.encrypt(secret, plaintext);

      expect(ciphertext, expected);
      expect(ciphertext, vector('newPinEnc', 'protocol1'));
      expect(ciphertext, hasLength(64));
      expect(one.decrypt(secret, ciphertext), plaintext);
      expect(one.encrypt(secret, vector('pinHash')), vector('pinHashEnc', 'protocol1'));
    });

    test('authenticates with the first 16 bytes of HMAC-SHA-256', () {
      final message = vector('newPinEnc', 'protocol1');

      final tag = one.authenticate(secret, message);

      expect(tag, hasLength(16));
      expect(tag, _hmac(secret, message).sublist(0, 16));
      expect(tag, vector('setPinAuthParam', 'protocol1'));
    });

    test('refuses a ciphertext that is not whole blocks', () {
      expect(() => one.decrypt(secret, Uint8List(63)), throwsA(isA<PinProtocolError>()));
      expect(() => one.encrypt(secret, Uint8List(17)), throwsA(isA<PinProtocolError>()));
    });
  });

  group('protocol 2', () {
    // HKDF-SHA-256 by hand: extract with 32 zero bytes of salt, then one block of expand for each key.
    final prk = _hmac(Uint8List(32), z);
    final hmacKey = _hmac(prk, [...ascii.encode('CTAP2 HMAC key'), 1]);
    final aesKey = _hmac(prk, [...ascii.encode('CTAP2 AES key'), 1]);
    final secret = Uint8List.fromList([...hmacKey, ...aesKey]);

    test('shares an HMAC key and an AES key made by HKDF-SHA-256', () {
      expect(two.number, 2);
      expect(two.encapsulate(peerCose, platformKey: platform).sharedSecret, secret);
      expect(secret, vector('sharedSecret', 'protocol2'));
    });

    test('encrypts with AES-256-CBC under the AES key, the IV in front, and decrypts it back', () {
      final expected = [...iv, ..._aesCbc(aesKey, iv, plaintext, encrypt: true)];

      final ciphertext = two.encrypt(secret, plaintext, iv: iv);

      expect(ciphertext, expected);
      expect(ciphertext, vector('newPinEnc', 'protocol2'));
      expect(ciphertext, hasLength(80));
      expect(two.decrypt(secret, ciphertext), plaintext);
      expect(two.encrypt(secret, vector('pinHash'), iv: iv), vector('pinHashEnc', 'protocol2'));
    });

    test('uses a random IV unless a test fixes it', () {
      final first = two.encrypt(secret, plaintext);
      final second = two.encrypt(secret, plaintext);

      expect(first, isNot(second));
      expect(two.decrypt(secret, first), plaintext);
      expect(two.decrypt(secret, second), plaintext);
    });

    test('authenticates with the whole HMAC-SHA-256, under the HMAC key', () {
      final message = vector('newPinEnc', 'protocol2');

      final tag = two.authenticate(secret, message);

      expect(tag, hasLength(32));
      expect(tag, _hmac(hmacKey, message));
      expect(tag, vector('setPinAuthParam', 'protocol2'));
    });

    test('authenticates with a 32-byte PIN token as it is', () {
      final token = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      expect(two.authenticate(token, [1, 2, 3]), _hmac(token, [1, 2, 3]));
    });

    test('refuses a ciphertext of a tampered length, and a secret of the wrong size', () {
      final ciphertext = two.encrypt(secret, plaintext, iv: iv);

      expect(() => two.decrypt(secret, ciphertext.sublist(0, 79)), throwsA(isA<PinProtocolError>()));
      expect(() => two.decrypt(secret, ciphertext.sublist(0, 15)), throwsA(isA<PinProtocolError>()));
      expect(() => two.encrypt(hmacKey, plaintext), throwsA(isA<PinProtocolError>()));
    });
  });

  test('refuses a peer key that is not a point of the curve', () {
    final notOnCurve = <int, Object?>{1: 2, 3: -25, -1: 1, -2: Uint8List(32)..[31] = 1, -3: Uint8List(32)..[31] = 1};

    expect(() => one.encapsulate(notOnCurve), throwsA(isA<PinProtocolError>()));
    expect(() => two.encapsulate({1: 2, -2: Uint8List(31), -3: peer.y}), throwsA(isA<PinProtocolError>()));
    expect(() => two.encapsulate({1: 2}), throwsA(isA<PinProtocolError>()));
  });

  test('uses the first protocol in the key’s list that it knows', () {
    expect(PinProtocol.choose([2, 1])!.number, 2);
    expect(PinProtocol.choose([1, 2])!.number, 1);
    expect(PinProtocol.choose([1])!.number, 1);
    expect(PinProtocol.choose([3, 2])!.number, 2);
    expect(PinProtocol.choose([3]), isNull);
    expect(PinProtocol.choose([]), isNull);
  });

  // The recorded pinHashEnc, newPinEnc and pinUvAuthParam of a real key
  // are not checked here: task 1.7 of add-security-key-management could
  // not run without a key. The OpenSSL values above stand in for them.
}
