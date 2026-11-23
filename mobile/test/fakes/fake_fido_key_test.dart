import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:pointycastle/export.dart' as pc;

import 'fake_fido_key.dart';
import 'fake_security_keys.dart';

// The fake key is driven here with raw CBOR and a platform side written in
// this file from the CTAP text, so the fake is checked without the app's
// own PIN code.

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

Uint8List _aes(Uint8List key, Uint8List iv, Uint8List input, {required bool encrypt}) {
  final cipher = pc.CBCBlockCipher(pc.AESEngine())..init(encrypt, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

Uint8List _padded(String pin) => Uint8List(64)..setAll(0, utf8.encode(pin));

Uint8List _hash(String pin) => Uint8List.fromList(sha256.convert(utf8.encode(pin)).bytes.sublist(0, 16));

/// The platform's side of one PIN protocol, talking to [fido] in raw CBOR.
class _Platform {
  _Platform(this.fido, this.protocol);

  final FakeFidoKey fido;
  final int protocol;
  final P256KeyPair pair = newP256KeyPair();
  late Uint8List hmacKey;
  late Uint8List aesKey;

  FakeCtapReply send(int command, Map<int, Object?> parameters) => fido.handle(command, cborEncode(parameters), SecurityKeyLinkKind.nfc);

  Map<int, Object?> get cose => {1: 2, 3: -25, -1: 1, -2: pair.x, -3: pair.y};

  /// Asks for the key's public key and works out the shared secret.
  void agree() {
    final reply = send(0x06, {1: protocol, 2: 2});
    expect(reply.status, 0);
    final peer = cborIntMap(cborIntMap(reply.value)[1]);
    expect(peer[1], 2);
    expect(peer[3], -25);
    expect(peer[-1], 1);
    final z = p256SharedSecret(pair.d, Uint8List.fromList([4, ...peer[-2]! as Uint8List, ...peer[-3]! as Uint8List]));
    if (protocol == 1) {
      hmacKey = aesKey = Uint8List.fromList(sha256.convert(z).bytes);
    } else {
      final prk = _hmac(Uint8List(32), z);
      hmacKey = _hmac(prk, [...ascii.encode('CTAP2 HMAC key'), 1]);
      aesKey = _hmac(prk, [...ascii.encode('CTAP2 AES key'), 1]);
    }
  }

  Uint8List enc(Uint8List plaintext) {
    if (protocol == 1) return _aes(aesKey, Uint8List(16), plaintext, encrypt: true);
    final iv = Uint8List.fromList(List.generate(16, (i) => i + 1));
    return Uint8List.fromList([...iv, ..._aes(aesKey, iv, plaintext, encrypt: true)]);
  }

  Uint8List dec(Uint8List ciphertext) => protocol == 1
      ? _aes(aesKey, Uint8List(16), ciphertext, encrypt: false)
      : _aes(aesKey, ciphertext.sublist(0, 16), ciphertext.sublist(16), encrypt: false);

  Uint8List tag(Uint8List key, List<int> message) => protocol == 1 ? _hmac(key, message).sublist(0, 16) : _hmac(key, message);

  int setPin(String pin, {bool badTag = false}) {
    agree();
    final newPinEnc = enc(_padded(pin));
    final auth = tag(hmacKey, newPinEnc);
    if (badTag) auth[0] ^= 1;
    return send(0x06, {1: protocol, 2: 3, 3: cose, 4: auth, 5: newPinEnc}).status;
  }

  int changePin(String current, String next) {
    agree();
    final newPinEnc = enc(_padded(next));
    final pinHashEnc = enc(_hash(current));
    return send(0x06, {
      1: protocol,
      2: 4,
      3: cose,
      4: tag(hmacKey, [...newPinEnc, ...pinHashEnc]),
      5: newPinEnc,
      6: pinHashEnc,
    }).status;
  }

  /// The status of asking for a token, and the token when it was given.
  (int, Uint8List?) token(String pin, {int? permissions}) {
    agree();
    final reply = send(0x06, {1: protocol, 2: permissions == null ? 5 : 9, 3: cose, 6: enc(_hash(pin)), 9: ?permissions});
    final encrypted = cborIntMap(reply.value)[2];
    return (reply.status, encrypted is Uint8List ? dec(encrypted) : null);
  }

  int retries() => cborIntMap(send(0x06, {1: protocol, 2: 1}).value)[3]! as int;
}

void main() {
  var clock = DateTime.utc(2026, 11, 16);
  setUp(() => clock = DateTime.utc(2026, 11, 16));

  FakeFidoKey powered(FakeFidoKey fido) => fido..poweredUp(() => clock);

  Map<int, Object?> info(FakeFidoKey fido) => cborIntMap(fido.handle(0x04, Uint8List(0), SecurityKeyLinkKind.nfc).value);

  test('answers getInfo as it is configured', () {
    final modern = powered(
      FakeFidoKey(pin: '1234', firmwareVersion: 7, minPinLength: 6, forcePinChange: true, fingerprintReader: FakeSupport.standard),
    );
    expect(info(modern)[1], ['U2F_V2', 'FIDO_2_0', 'FIDO_2_1']);
    expect(info(modern)[3], List.filled(16, 0x2f));
    expect(info(modern)[4], {
      'rk': true,
      'up': true,
      'plat': false,
      'clientPin': true,
      'credMgmt': true,
      'bioEnroll': false,
      'pinUvAuthToken': true,
    });
    expect(info(modern)[6], [2, 1]);
    expect(info(modern)[12], true);
    expect(info(modern)[13], 6);
    expect(info(modern)[14], 7);
    expect(info(modern)[20], 100);

    final old = powered(FakeFidoKey.ctap20());
    expect(info(old)[1], ['U2F_V2', 'FIDO_2_0']);
    expect(info(old)[4], {'rk': true, 'up': true, 'plat': false, 'clientPin': false, 'credentialMgmtPreview': true});
    expect(info(old)[6], [1]);
    expect(info(old).containsKey(12), isFalse);
    expect(info(old).containsKey(13), isFalse);
    expect(info(old).containsKey(14), isFalse);

    final bare = powered(FakeFidoKey(clientPin: false, credentialManagement: FakeSupport.none, pinUvAuthToken: false));
    expect(info(bare)[4], {'rk': true, 'up': true, 'plat': false});
    expect(info(bare).containsKey(6), isFalse);
    expect(bare.handle(0x06, cborEncode({1: 1, 2: 1}), SecurityKeyLinkKind.nfc).status, 0x01);
    expect(bare.handle(0x0a, cborEncode({1: 1}), SecurityKeyLinkKind.nfc).status, 0x01);
    expect(bare.handle(0x09, cborEncode({1: 1, 2: 7}), SecurityKeyLinkKind.nfc).status, 0x01);
    expect(bare.handle(0x77, Uint8List(0), SecurityKeyLinkKind.nfc).status, 0x01);
    expect(bare.requests, ['4', '4', '6.1', 'a.1', '9.7', '77']);
  });

  test('refuses a PIN protocol it does not list', () {
    final fido = powered(FakeFidoKey(pinProtocols: [2]));

    expect(fido.handle(0x06, cborEncode({1: 1, 2: 2}), SecurityKeyLinkKind.nfc).status, 0x02);
    expect(fido.handle(0x06, cborEncode({1: 2, 2: 2}), SecurityKeyLinkKind.nfc).status, 0);
  });

  for (final protocol in [1, 2]) {
    group('with PIN protocol $protocol', () {
      test('sets a first PIN under the length rules', () {
        final fido = powered(FakeFidoKey());
        final platform = _Platform(fido, protocol);

        expect(platform.setPin('123'), 0x37, reason: 'three characters');
        expect(fido.pin, isNull);
        expect(platform.setPin('123456', badTag: true), 0x33);
        expect(fido.pin, isNull);
        expect(platform.setPin('päss'), 0, reason: 'four characters, five bytes');
        expect(fido.pin, 'päss');
        expect(info(fido)[4], containsPair('clientPin', true));
        expect(platform.setPin('654321'), 0x33, reason: 'a key with a PIN takes a new one only through change');
        expect(platform.retries(), 8);
      });

      test('holds a new PIN to the minimum it reports and to its own rules', () {
        final fido = powered(FakeFidoKey(minPinLength: 6))..refusesPin = (pin) => pin == '000000';
        final platform = _Platform(fido, protocol);

        expect(platform.setPin('12345'), 0x37);
        expect(platform.setPin('000000'), 0x37);
        expect(platform.setPin('123456'), 0);
        expect(platform.changePin('123456', '000000'), 0x37);
        expect(fido.pin, '123456');
      });

      test('changes the PIN with the right current one, and counts a wrong one', () {
        final fido = powered(FakeFidoKey(pin: '123456'));
        final platform = _Platform(fido, protocol);

        expect(platform.changePin('111111', '654321'), 0x31);
        expect(fido.pin, '123456');
        expect(platform.retries(), 7);
        expect(platform.changePin('123456', '654321'), 0);
        expect(fido.pin, '654321');
        expect(platform.retries(), 8, reason: 'the right PIN gives the tries back');
        expect(_Platform(powered(FakeFidoKey()), protocol).changePin('123456', '654321'), 0x35);
      });

      test('locks after three wrong PINs in a row until it is powered again', () {
        final fido = powered(FakeFidoKey(pin: '123456'));
        final platform = _Platform(fido, protocol);

        expect(platform.token('0000').$1, 0x31);
        expect(platform.token('0000').$1, 0x31);
        expect(platform.token('0000').$1, 0x34);
        expect(platform.token('123456').$1, 0x34, reason: 'even the right PIN is refused');
        expect(platform.retries(), 5);
        expect(cborIntMap(platform.send(0x06, {1: protocol, 2: 1}).value)[4], true);

        fido.poweredUp(() => clock);
        final (status, token) = platform.token('123456');
        expect(status, 0);
        expect(token, hasLength(32));
        expect(platform.retries(), 8);
      });

      test('blocks its PIN for good when the tries run out', () {
        final fido = powered(FakeFidoKey(pin: '123456'))..retries = 2;
        final platform = _Platform(fido, protocol);

        expect(platform.token('0000').$1, 0x31);
        expect(platform.token('0000').$1, 0x32);
        fido.poweredUp(() => clock);
        expect(platform.token('123456').$1, 0x32);
        expect(platform.changePin('123456', '654321'), 0x32);
        expect(platform.retries(), 0);
      });

      test('gives a token limited to the permissions asked for', () {
        final fido = powered(FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard))..addPasskey('example.org', 'ada');
        final platform = _Platform(fido, protocol);
        final (status, token) = platform.token('123456', permissions: 0x04);
        expect(status, 0);

        Map<int, Object?> metadata(Uint8List? auth) => {1: 1, 3: protocol, 4: ?auth};
        final good = platform.tag(token!, [1]);
        expect(platform.send(0x0a, metadata(good)).status, 0);
        expect(cborIntMap(platform.send(0x0a, metadata(good)).value), {1: 1, 2: 99});
        expect(platform.send(0x0a, metadata(platform.tag(token, [2]))).status, 0x33, reason: 'a tag for other bytes');
        expect(platform.send(0x0a, metadata(null)).status, 0x36, reason: 'no tag at all');
        expect(
          platform.send(0x09, {
            1: 1,
            2: 4,
            4: protocol,
            5: platform.tag(token, [1, 4]),
          }).status,
          0x40,
          reason: 'the token is for passkeys, not fingerprints',
        );

        expect(platform.token('123456', permissions: 0).$1, 0x02, reason: 'a token for nothing');
      });

      test('gives the older all-purpose token, and nothing else when it knows no permissions', () {
        final fido = powered(FakeFidoKey.ctap20(pin: '123456', fingerprintReader: FakeSupport.preview))..pinProtocols = [1, 2];
        final platform = _Platform(fido, protocol);

        expect(platform.token('123456', permissions: 0x04).$1, 0x02);
        final (status, token) = platform.token('123456');
        expect(status, 0);
        expect(
          platform.send(0x41, {
            1: 1,
            3: protocol,
            4: platform.tag(token!, [1]),
          }).status,
          0,
        );
        expect(
          platform.send(0x40, {
            1: 1,
            2: 4,
            4: protocol,
            5: platform.tag(token, [1, 4]),
          }).status,
          0x2c,
          reason: 'no fingerprint yet',
        );
        expect(
          platform.send(0x0a, {
            1: 1,
            3: protocol,
            4: platform.tag(token, [1]),
          }).status,
          0x01,
          reason: 'only the preview command',
        );
      });

      test('refuses to hand out a token while its PIN must be changed', () {
        final fido = powered(FakeFidoKey(pin: '123456', forcePinChange: true));
        final platform = _Platform(fido, protocol);

        expect(platform.token('123456', permissions: 0x04).$1, 0x37);
        expect(platform.changePin('123456', '654321'), 0);
        expect(platform.token('654321', permissions: 0x04).$1, 0);
        expect(info(fido).containsKey(12), isFalse);
      });
    });
  }

  test('speaks through a fake key over each kind of link', () async {
    final fido = FakeFidoKey(pin: '123456');
    final key = FakeKey(ctap: fido);
    final phone = FakeSecurityKeys();
    final device = key.device(kinds: {SecurityKeyLinkKind.nfc});
    phone.arrive(device);

    // SELECT, then NFCCTAP_MSG carrying getInfo.
    await phone.transceive(
      device.linkId(SecurityKeyLinkKind.nfc),
      Uint8List.fromList([0, 0xa4, 4, 0, 8, ...fakeFidoAid, 0]),
      timeout: Duration.zero,
    );
    final answer = await phone.transceive(
      device.linkId(SecurityKeyLinkKind.nfc),
      Uint8List.fromList([0x80, 0x10, 0, 0, 0, 0, 1, 4, 0, 0]),
      timeout: Duration.zero,
    );

    expect(answer[0], 0);
    expect(answer.sublist(answer.length - 2), [0x90, 0x00]);
    expect(cborIntMap(cborDecode(answer.sublist(1, answer.length - 2)))[6], [2, 1]);
  });
}
