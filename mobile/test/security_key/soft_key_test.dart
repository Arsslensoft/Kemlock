import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/pin_protocol.dart';

import 'fido/rig.dart';
import 'soft_key.dart';

const _rpId = 'example.org';
final _salt = Uint8List.fromList(List.generate(32, (i) => i));
final _salt2 = Uint8List.fromList(List.generate(32, (i) => 0xff - i));
final _hash = Uint8List.fromList(List.filled(32, 0xcd));

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

/// The requests are built here by hand from the CTAP text, apart from the
/// app's own `hmac_secret.dart`, with the app's PIN protocols.
extension on Rig {
  SoftKey get soft => fido as SoftKey;

  /// `makeCredential`; returns the status and the answer.
  Future<(int, Map<int, Object?>)> make({
    PinToken? token,
    List<Uint8List> exclude = const [],
    Map<String, Object?>? options,
    int? level,
  }) async {
    final answer = await session.send(0x01, {
      1: _hash,
      2: {'id': _rpId},
      3: {
        'id': Uint8List.fromList([1, 2, 3]),
        'name': 'someone',
      },
      4: [
        {'alg': -7, 'type': 'public-key'},
      ],
      if (exclude.isNotEmpty)
        5: [
          for (final id in exclude) {'id': id, 'type': 'public-key'},
        ],
      6: {'hmac-secret': true, 'credProtect': ?level},
      7: ?options,
      if (token != null) ...{8: token.authenticate(_hash), 9: token.protocol.number},
    });
    return (answer.status, answer.map);
  }

  /// `getAssertion` with `hmac-secret`; returns the status and the outputs, decrypted.
  Future<(int, Uint8List?)> read(List<Uint8List> allow, {PinToken? token, Uint8List? second, Map<String, Object?>? options}) async {
    final protocol = PinProtocol.choose(info.pinUvAuthProtocols)!;
    final peer = cborIntMap((await session.send(0x06, {1: protocol.number, 2: 2})).map[1]);
    final agreed = protocol.encapsulate(peer);
    final saltEnc = protocol.encrypt(agreed.sharedSecret, Uint8List.fromList([..._salt, ...?second]));
    final answer = await session.send(0x02, {
      1: _rpId,
      2: _hash,
      3: [
        for (final id in allow) {'id': id, 'type': 'public-key'},
      ],
      4: {
        'hmac-secret': {1: agreed.keyAgreement, 2: saltEnc, 3: protocol.authenticate(agreed.sharedSecret, saltEnc), 4: protocol.number},
      },
      5: ?options,
      if (token != null) ...{6: token.authenticate(_hash), 7: token.protocol.number},
    });
    if (answer.status != 0) return (answer.status, null);
    final authData = answer.map[2]! as Uint8List;
    final extensions = cborTextMap(cborDecode(authData.sublist(37)));
    return (0, protocol.decrypt(agreed.sharedSecret, extensions['hmac-secret']! as Uint8List));
  }

  Future<PinToken> pinToken([String pin = '123456']) =>
      clientPin.token(pinBytes(pin), permissions: PinPermission.makeCredential | PinPermission.getAssertion, rpId: _rpId);
}

// openspec: add-security-key-unlock, task 3.1
void main() {
  test('says what it supports', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    expect(rig.info.extensions, ['credProtect', 'hmac-secret']);
    expect(rig.info.versions, contains('FIDO_2_1'));

    final old = await Rig.connect(SoftKey.ctap20(pin: '123456'));
    expect(old.info.extensions, ['hmac-secret']);
    expect(old.info.versions, isNot(contains('FIDO_2_1')));
    expect(old.info.pinUvAuthProtocols, [1]);

    final none = await Rig.connect(SoftKey(pin: '123456')..set(hmacSecret: false));
    expect(none.info.extensions, ['credProtect']);
  });

  for (final protocols in [
    [2, 1],
    [1],
  ]) {
    testOverEachLink('the output is HMAC-SHA-256 of the credential’s secret and the salt, under protocol ${protocols.first}', (kind) async {
      final rig = await Rig.connect(
        SoftKey(pin: '123456', pinProtocols: protocols),
        kind: kind,
      );
      final token = await rig.pinToken();
      final (status, answer) = await rig.make(token: token);
      expect(status, 0);
      expect(answer[1], 'none');
      final credential = rig.soft.made.single;

      final (_, one) = await rig.read([credential.id], token: await rig.pinToken());
      expect(one, _hmac(credential.withUv, _salt));

      final (_, two) = await rig.read([credential.id], token: await rig.pinToken(), second: _salt2);
      expect(two, [..._hmac(credential.withUv, _salt), ..._hmac(credential.withUv, _salt2)]);
    });
  }

  test('a CTAP 2.1 key gives another output when its owner was not verified', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    await rig.make(token: token);
    final credential = rig.soft.made.single;

    final (_, verified) = await rig.read([credential.id], token: await rig.pinToken());
    final (status, touched) = await rig.read([credential.id]);

    expect(status, 0);
    expect(touched, _hmac(credential.withoutUv, _salt));
    expect(touched, isNot(verified));
  });

  test('a CTAP 2.0 key gives the same output on a touch alone', () async {
    final rig = await Rig.connect(SoftKey.ctap20(pin: '123456'));
    final token = await rig.pinToken();
    await rig.make(token: token);
    final credential = rig.soft.made.single;

    final (_, verified) = await rig.read([credential.id], token: await rig.pinToken());
    final (_, touched) = await rig.read([credential.id]);

    expect(touched, verified);
  });

  test('a credential at the highest credProtect level does not exist for who was not verified', () async {
    final rig = await Rig.connect(SoftKey.ctap20(pin: '123456', credProtect: true));
    final token = await rig.pinToken();
    final (_, answer) = await rig.make(token: token, level: 3);
    final authData = answer[2]! as Uint8List;
    expect(authData[32] & 0x04, 0x04);
    final credential = rig.soft.made.single;
    expect(credential.credProtect, 3);

    expect((await rig.read([credential.id])).$1, 0x2e);
    expect((await rig.read([credential.id], token: await rig.pinToken())).$2, _hmac(credential.withUv, _salt));
  });

  test('makes nothing without the PIN once it has one, and nothing discoverable unless asked', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    expect((await rig.make()).$1, 0x36);
    expect(rig.soft.made, isEmpty);

    final token = await rig.pinToken();
    await rig.make(token: token);
    expect(rig.soft.credentials, isEmpty);
    await rig.make(token: await rig.pinToken(), options: {'rk': true});
    expect(rig.soft.credentials, hasLength(1));
  });

  test('refuses a credential on its exclude list, and finds none it does not hold', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    await rig.make(token: token);
    final id = rig.soft.made.single.id;

    expect((await rig.make(token: await rig.pinToken(), exclude: [id])).$1, 0x19);
    expect(rig.soft.made, hasLength(1));
    expect((await rig.read([Uint8List.fromList(List.filled(64, 9))], token: await rig.pinToken())).$1, 0x2e);
    // The first of the list that it holds answers
    expect((await rig.read([Uint8List.fromList(List.filled(64, 9)), id], token: await rig.pinToken())).$1, 0);
  });

  test('a token without the permission, or a tag that is not the token’s, is refused', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final narrow = await rig.clientPin.token(pinBytes('123456'), permissions: PinPermission.credentialManagement);
    expect((await rig.make(token: narrow)).$1, 0x40);
    final forged = PinToken(narrow.protocol, Uint8List(32));
    expect((await rig.make(token: forged)).$1, 0x33);
  });

  test('its own fingerprint reader verifies the owner without a PIN', () async {
    final soft = SoftKey(fingerprintReader: FakeSupport.standard)..addFingerprint('Index');
    final rig = await Rig.connect(soft);
    expect(rig.info.options['uv'], isTrue);

    final (status, answer) = await rig.make(options: {'uv': true});
    expect(status, 0);
    expect((answer[2]! as Uint8List)[32] & 0x04, 0x04);
    final (_, output) = await rig.read([soft.made.single.id], options: {'uv': true});
    expect(output, _hmac(soft.made.single.withUv, _salt));

    // A key without a reader refuses the request
    final plain = await Rig.connect(SoftKey());
    expect((await plain.make(options: {'uv': true})).$1, 0x2c);
  });

  test('a CTAP 2.1 key spends a token on the first credential or read it is used for, and a CTAP 2.0 key does not', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    expect((await rig.make(token: token)).$1, 0);
    final id = rig.soft.made.single.id;
    expect((await rig.read([id], token: token)).$1, 0x40);
    final read = await rig.pinToken();
    expect((await rig.read([id], token: read)).$1, 0);
    expect((await rig.read([id], token: read)).$1, 0x40);

    final old = await Rig.connect(SoftKey.ctap20(pin: '123456'));
    final kept = await old.pinToken();
    expect((await old.make(token: kept)).$1, 0);
    expect((await old.read([old.soft.made.single.id], token: kept)).$1, 0);
    expect((await old.read([old.soft.made.single.id], token: kept)).$1, 0);
  });

  test('waits for a touch', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    rig.soft.touches = false;
    expect((await rig.make(token: token)).$1, 0x2f);
    expect(rig.soft.made, isEmpty);
  });

  group('the PIN counter', () {
    test('locks until the key is presented again after three wrong PINs in a row', () async {
      final rig = await Rig.connect(SoftKey(pin: '123456'));
      await expectLater(rig.pinToken('000000'), throwsA(isA<PinWrong>().having((e) => e.retries, 'retries', 7)));
      await expectLater(rig.pinToken('000000'), throwsA(isA<PinWrong>().having((e) => e.retries, 'retries', 6)));
      await expectLater(rig.pinToken('000000'), throwsA(isA<PinLockedUntilReconnected>()));
      // The right PIN is refused too, and costs no try
      await expectLater(rig.pinToken(), throwsA(isA<PinLockedUntilReconnected>()));
      expect(await rig.clientPin.retries(), 5);

      await rig.reconnect();
      await rig.pinToken();
      expect(await rig.clientPin.retries(), 8);
    });

    test('locks for good after eight', () async {
      final rig = await Rig.connect(SoftKey(pin: '123456'));
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 3 && rig.soft.retries > 0; i++) {
          await expectLater(rig.pinToken('000000'), throwsA(isA<PinError>()));
        }
        await rig.reconnect();
      }
      expect(rig.soft.retries, 0);
      await expectLater(rig.pinToken(), throwsA(isA<PinBlocked>()));
      expect(await rig.clientPin.retries(), 0);
    });
  });
}
