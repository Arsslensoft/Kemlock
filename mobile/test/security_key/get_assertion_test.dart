// authenticatorGetAssertion: the request against the CTAP specification's
// own example, and the fake key's answers over each link.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/ctap.dart';
import 'package:kemlock/security_key/fido/get_assertion.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_security_keys.dart';
import 'fido/rig.dart';
import 'hex.dart';

const _rpId = 'vault.example.org';

final _hash = Uint8List.fromList(sha256.convert(utf8.encode('client data')).bytes);

Map<String, Object?> _spec() =>
    jsonDecode(File('test/fixtures/security_keys/get_assertion/ctap_spec_example.json').readAsStringSync()) as Map<String, Object?>;

/// Answers every request with one fixed CBOR value.
class _Canned extends FakeCtapAuthenticator {
  _Canned(this.answer);

  final Object? answer;

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) => FakeCtapReply(0, answer);
}

void main() {
  test('writes the request of the CTAP specification\'s example, byte for byte', () {
    final spec = _spec();

    final parameters = getAssertionParameters(
      rpId: spec['rpId']! as String,
      clientDataHash: unhex(spec['clientDataHash']! as String),
      allowList: [unhex(spec['credentialId']! as String)],
    );

    expect(hex(cborEncode(parameters)), spec['request']);
  });

  test('reads the answer of the CTAP specification\'s example', () async {
    final spec = _spec();
    final phone = FakeSecurityKeys();
    final device = FakeKey(ctap: _Canned(cborDecode(unhex(spec['response']! as String)))).device(kinds: {SecurityKeyLinkKind.nfc});
    phone.arrive(device);
    final connection = SecurityKeyConnection(
      phone,
      SecurityKeyDevice(
        id: device.id,
        links: [SecurityKeyLink(id: device.linkId(SecurityKeyLinkKind.nfc), kind: SecurityKeyLinkKind.nfc, extendedLength: true)],
      ),
      now: phone.now,
    );

    final assertion = await getAssertion(
      await connection.openFido(),
      rpId: spec['rpId']! as String,
      clientDataHash: unhex(spec['clientDataHash']! as String),
      allowList: [unhex(spec['credentialId']! as String)],
    );

    expect(hex(assertion.credentialId!), spec['credentialId']);
    expect(hex(assertion.authenticatorData), spec['authenticatorData']);
    expect(hex(assertion.signature), spec['signature']);
  });

  testOverEachLink('gets an assertion the credential\'s public key verifies', (kind) async {
    final fido = FakeFidoKey();
    final credential = fido.addSignInCredential(_rpId);
    final rig = await Rig.connect(fido, kind: kind);

    final assertion = await getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id]);

    expect(assertion.credentialId, credential.id);
    expect(assertion.authenticatorData.sublist(0, 32), sha256.convert(utf8.encode(_rpId)).bytes);
    expect(assertion.authenticatorData[32] & 0x01, 0x01, reason: 'user present');
    expect(assertion.authenticatorData[32] & 0x04, 0, reason: 'no PIN was given');
    expect(assertion.authenticatorData.sublist(33), [0, 0, 0, 1]);
    final signed = Uint8List.fromList([...assertion.authenticatorData, ..._hash]);
    expect(es256Verify(credential.keyPair.point, signed, assertion.signature), isTrue);
    // The request asks for a touch and for no verification
    expect(fido.requests.last, '2');
  });

  testOverEachLink('says when the key holds none of the credentials', (kind) async {
    final fido = FakeFidoKey()..addSignInCredential('other.example.org');
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(
      getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [Uint8List.fromList(List.filled(32, 7))]),
      throwsA(isA<AssertionNoCredentials>()),
    );
  });

  testOverEachLink('says when the key wants its PIN, and answers with a token for the site', (kind) async {
    final fido = FakeFidoKey(pin: '123456')..alwaysUv = true;
    final credential = fido.addSignInCredential(_rpId);
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(
      getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id]),
      throwsA(isA<AssertionPinRequired>()),
    );

    final token = await rig.clientPin.token(pinBytes('123456'), permissions: pinPermissionGetAssertion, rpId: _rpId);
    final assertion = await getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id], token: token);

    expect(assertion.authenticatorData[32] & 0x04, 0x04, reason: 'the user was verified');
    final signed = Uint8List.fromList([...assertion.authenticatorData, ..._hash]);
    expect(es256Verify(credential.keyPair.point, signed, assertion.signature), isTrue);
  });

  test('a token for one site signs for no other', () async {
    final fido = FakeFidoKey(pin: '123456')..alwaysUv = true;
    final credential = fido.addSignInCredential(_rpId);
    final rig = await Rig.connect(fido);
    final token = await rig.clientPin.token(pinBytes('123456'), permissions: pinPermissionGetAssertion, rpId: 'other.example.org');

    await expectLater(
      getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id], token: token),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.pinAuthInvalid)),
    );
  });

  test('a token for managing passkeys signs no assertion', () async {
    final fido = FakeFidoKey(pin: '123456')..alwaysUv = true;
    final credential = fido.addSignInCredential(_rpId);
    final rig = await Rig.connect(fido);
    final token = await rig.token('123456', PinPermission.credentialManagement);

    await expectLater(
      getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id], token: token),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.unauthorizedPermission)),
    );
  });

  test('says when nobody touched the key', () async {
    final fido = FakeFidoKey()..touches = false;
    final credential = fido.addSignInCredential(_rpId);
    final rig = await Rig.connect(fido);

    await expectLater(
      getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id]),
      throwsA(isA<AssertionNotTouched>()),
    );
  });

  test('uses the id sent when the key leaves the credential out', () async {
    final fido = FakeFidoKey()..omitsSingleCredential = true;
    final credential = fido.addSignInCredential(_rpId);
    final rig = await Rig.connect(fido);

    final assertion = await getAssertion(rig.session, rpId: _rpId, clientDataHash: _hash, allowList: [credential.id]);

    expect(assertion.credentialId, isNull);
  });

  test('reads how many credentials a key takes in one request, one when it does not say', () async {
    final rig = await Rig.connect(FakeFidoKey()..maxCredentialCountInList = 8);
    expect(maxCredentialsInList(await rig.session.request(CtapCommand.getInfo)), 8);

    final silent = await Rig.connect(FakeFidoKey.ctap20());
    expect(maxCredentialsInList(await silent.session.request(CtapCommand.getInfo)), 1);
    expect(maxCredentialsInList({7: 0}), 1);
  });
}
