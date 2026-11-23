import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/ctap.dart';
import 'package:kemlock/security_key/hmac_secret.dart';

import 'fido/rig.dart';
import 'hex.dart';
import 'soft_key.dart';

final _salt = Uint8List.fromList(List.generate(32, (i) => 0x40 + i));
final _salt2 = Uint8List.fromList(List.generate(32, (i) => 0x80 + i));

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

extension on Rig {
  SoftKey get soft => fido as SoftKey;

  HmacSecret get hmacSecret => HmacSecret(session, info);

  Future<PinToken> pinToken([String pin = '123456']) =>
      clientPin.token(pinBytes(pin), permissions: PinPermission.makeCredential | PinPermission.getAssertion, rpId: vaultUnlockRpId);
}

// openspec: add-security-key-unlock, task 3.2
void main() {
  for (final protocols in [
    [2, 1],
    [1],
  ]) {
    group('under PIN protocol ${protocols.first}', () {
      testOverEachLink('enrol then read gives the same output twice', (kind) async {
        final rig = await Rig.connect(
          SoftKey(pin: '123456', pinProtocols: protocols),
          kind: kind,
        );
        final token = await rig.pinToken();
        expect(token.protocol.number, protocols.first);

        final made = await rig.hmacSecret.makeCredential(token: token);
        final first = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt);
        final second = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt);

        expect(first.output, hasLength(32));
        expect(second.output, first.output);
        expect(first.credential, made.id);
        expect(first.second, isNull);
        // It is the key's secret for a verified owner, and not what a touch alone gives
        final credential = rig.soft.made.single;
        expect(first.output, _hmac(credential.withUv, _salt));
        expect(first.output, isNot(_hmac(credential.withoutUv, _salt)));
      });

      test('reads two salts at once', () async {
        final rig = await Rig.connect(SoftKey(pin: '123456', pinProtocols: protocols));
        final token = await rig.pinToken();
        final made = await rig.hmacSecret.makeCredential(token: token);

        final reading = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt, secondSalt: _salt2);

        final credential = rig.soft.made.single;
        expect(reading.output, _hmac(credential.withUv, _salt));
        expect(reading.second, _hmac(credential.withUv, _salt2));
      });

      test('the exclude list refuses a second enrolment', () async {
        final rig = await Rig.connect(SoftKey(pin: '123456', pinProtocols: protocols));
        final token = await rig.pinToken();
        final made = await rig.hmacSecret.makeCredential(token: token);

        await expectLater(
          rig.hmacSecret.makeCredential(token: await rig.pinToken(), exclude: [made.id]),
          throwsA(isA<CredentialAlreadyOnKey>()),
        );
        expect(rig.soft.made, hasLength(1));
        // Another vault's credentials do not stand in the way
        final other = await rig.hmacSecret.makeCredential(token: await rig.pinToken(), exclude: [Uint8List.fromList(List.filled(64, 1))]);
        expect(other.id, isNot(made.id));
      });

      test('a credential the key does not hold is reported as such', () async {
        final rig = await Rig.connect(SoftKey(pin: '123456', pinProtocols: protocols));
        final token = await rig.pinToken();
        await rig.hmacSecret.makeCredential(token: token);

        await expectLater(
          rig.hmacSecret.read(token: await rig.pinToken(), allow: [Uint8List.fromList(List.filled(64, 7))], salt: _salt),
          throwsA(isA<NoCredentialOnKey>()),
        );
        await expectLater(
          rig.hmacSecret.read(token: await rig.pinToken(), allow: const [], salt: _salt),
          throwsA(isA<NoCredentialOnKey>()),
        );
      });
    });
  }

  test('the credential is the one of decision 4, and never discoverable', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    final spare = Uint8List.fromList(List.filled(48, 3));
    final passkeysBefore = rig.info.remainingDiscoverableCredentials;

    final made = await rig.hmacSecret.makeCredential(token: token, exclude: [spare]);
    await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt);

    final request = rig.soft.makeRequests.single;
    expect(request[2], {'id': 'kemlock:vault-unlock', 'name': 'Kemlock'});
    final user = cborTextMap(request[3]);
    expect(user['name'], 'Kemlock');
    expect(user['id'], hasLength(16));
    expect(user.keys, unorderedEquals(['id', 'name']));
    expect(request[4], [
      {'alg': -7, 'type': 'public-key'},
    ]);
    expect(request[5], [
      {'id': spare, 'type': 'public-key'},
    ]);
    expect(request[6], {'hmac-secret': true, 'credProtect': 3});
    // No options at all: "rk" is false unless asked for
    expect(request.containsKey(7), isFalse);
    expect(made.credProtect, 3);
    // It takes no passkey place and is in no list
    expect(rig.soft.credentials, isEmpty);
    await rig.reconnect();
    expect(rig.info.remainingDiscoverableCredentials, passkeysBefore);
    expect(rig.soft.assertRequests.single[1], 'kemlock:vault-unlock');
  });

  test('neither salt nor output crosses the link in the clear', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    final made = await rig.hmacSecret.makeCredential(token: token);
    final reading = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt);

    final sent = hex(cborEncode(rig.soft.assertRequests.single));
    expect(sent, isNot(contains(hex(_salt))));
    expect(sent, isNot(contains(hex(reading.output))));
    final input = cborIntMap(cborTextMap(rig.soft.assertRequests.single[4])['hmac-secret']);
    expect(input[4], 2);
    expect(input[2], hasLength(48)); // An IV and the salt
  });

  test('protocol 1 leaves its number out of the extension, as a CTAP 2.0 key expects', () async {
    final rig = await Rig.connect(SoftKey.ctap20(pin: '123456'));
    final token = await rig.pinToken();
    final made = await rig.hmacSecret.makeCredential(token: token);
    final reading = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt);

    expect(reading.output, _hmac(rig.soft.made.single.withUv, _salt));
    final input = cborIntMap(cborTextMap(rig.soft.assertRequests.single[4])['hmac-secret']);
    expect(input.containsKey(4), isFalse);
    expect(rig.soft.makeRequests.single[6], {'hmac-secret': true});
  });

  test('picks the credential the key holds among several, and takes a lone one left unnamed', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    final made = await rig.hmacSecret.makeCredential(token: token);
    final other = Uint8List.fromList(List.filled(64, 9));

    final among = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [other, made.id], salt: _salt);
    expect(among.credential, made.id);

    rig.soft.omitsLoneCredential = true;
    final lone = await rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt);
    expect(lone.credential, made.id);
    expect(lone.output, among.output);
  });

  test('a key that cannot give a secret is refused before anything is made', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456')..set(hmacSecret: false));
    final token = await rig.pinToken();
    expect(rig.hmacSecret.supported, isFalse);

    await expectLater(rig.hmacSecret.makeCredential(token: token), throwsA(isA<KeyLacksHmacSecret>()));
    expect(rig.soft.makeRequests, isEmpty);
  });

  test('an answer without the "owner verified" flag is not used', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    final made = await rig.hmacSecret.makeCredential(token: token);
    rig.soft.forgetsUvFlag = true;

    await expectLater(
      rig.hmacSecret.read(token: await rig.pinToken(), allow: [made.id], salt: _salt),
      throwsA(isA<KeyDidNotVerifyOwner>()),
    );
  });

  test('without a token it asks for the key’s own fingerprint reader, and a key without one refuses', () async {
    final soft = SoftKey(fingerprintReader: FakeSupport.standard)..addFingerprint('Index');
    final rig = await Rig.connect(soft);

    final made = await rig.hmacSecret.makeCredential();
    final reading = await rig.hmacSecret.read(allow: [made.id], salt: _salt);

    expect(soft.makeRequests.single[7], {'uv': true});
    expect(soft.makeRequests.single.containsKey(8), isFalse);
    expect(reading.output, _hmac(soft.made.single.withUv, _salt));

    final plain = await Rig.connect(SoftKey());
    await expectLater(
      plain.hmacSecret.makeCredential(),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.invalidOption)),
    );
  });

  test('a wrong tag is the key’s refusal, not a secret', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    final made = await rig.hmacSecret.makeCredential(token: token);
    final forged = PinToken(token.protocol, Uint8List(32));

    await expectLater(
      rig.hmacSecret.read(token: forged, allow: [made.id], salt: _salt),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.pinAuthInvalid)),
    );
  });

  test('a salt that is not 32 bytes is refused before anything is sent', () async {
    final rig = await Rig.connect(SoftKey(pin: '123456'));
    final token = await rig.pinToken();
    await expectLater(rig.hmacSecret.read(token: token, allow: [Uint8List(64)], salt: Uint8List(16)), throwsArgumentError);
    expect(rig.soft.assertRequests, isEmpty);
  });

  group('whether a key ties its secret to its owner', () {
    test('a CTAP 2.1 key does', () async {
      final rig = await Rig.connect(SoftKey(pin: '123456', credProtect: false));
      final made = await rig.hmacSecret.makeCredential(token: await rig.pinToken());
      expect(made.credProtect, isNull);
      expect(tiesSecretToOwner(rig.info, made), isTrue);
    });

    test('a CTAP 2.0 key does not', () async {
      final rig = await Rig.connect(SoftKey.ctap20(pin: '123456'));
      final made = await rig.hmacSecret.makeCredential(token: await rig.pinToken());
      expect(tiesSecretToOwner(rig.info, made), isFalse);
    });

    test('a CTAP 2.0 key that took the highest credProtect level does', () async {
      final rig = await Rig.connect(SoftKey.ctap20(pin: '123456', credProtect: true));
      final made = await rig.hmacSecret.makeCredential(token: await rig.pinToken());
      expect(made.credProtect, 3);
      expect(tiesSecretToOwner(rig.info, made), isTrue);
    });
  });
}
