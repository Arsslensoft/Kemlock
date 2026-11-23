import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:kemlock/security_key/fido/ctap.dart';
import 'package:kemlock/security_key/fido/get_info.dart';

import '../../fakes/fake_fido_key.dart';
import '../hex.dart';
import 'rig.dart';

final _aaguid = Uint8List.fromList(List.generate(16, (i) => i));

AuthenticatorInfo _parse(Object? answer) => AuthenticatorInfo.parse(cborIntMap(cborDecode(cborEncode(answer))));

void main() {
  test('reads the answer of a CTAP 2.1 key, written out byte by byte', () {
    final bytes = unhex(
      'a7'
      // 1: versions
      '01 83 66 5532465f5632 68 4649444f5f325f30 68 4649444f5f325f31'
      // 3: aaguid
      '03 50 000102030405060708090a0b0c0d0e0f'
      // 4: options, in canonical order
      '04 a7'
      '  62 726b f5'
      '  62 7570 f5'
      '  64 706c6174 f4'
      '  68 637265644d676d74 f5'
      '  69 62696f456e726f6c6c f4'
      '  69 636c69656e7450696e f5'
      '  6e 70696e557641757468546f6b656e f5'
      // 6: pinUvAuthProtocols, 12: forcePINChange, 13: minPINLength, 14: firmwareVersion
      '06 82 02 01'
      '0c f5'
      '0d 06'
      '0e 1a 00050402',
    );

    final info = AuthenticatorInfo.parse(cborIntMap(cborDecode(bytes)));

    expect(info.versions, ['U2F_V2', 'FIDO_2_0', 'FIDO_2_1']);
    expect(info.fido2, isTrue);
    expect(info.aaguid, _aaguid);
    expect(info.options, {
      'rk': true,
      'up': true,
      'plat': false,
      'credMgmt': true,
      'bioEnroll': false,
      'clientPin': true,
      'pinUvAuthToken': true,
    });
    expect(info.pin, KeyPinState.set);
    expect(info.pinUvAuthProtocols, [2, 1]);
    expect(info.pinUvAuthToken, isTrue);
    expect(info.forcePinChange, isTrue);
    expect(info.minPinLength, 6);
    expect(info.firmwareVersion, 0x050402);
    expect(info.credentialManagementCommand, CtapCommand.credentialManagement);
    expect(info.bioEnrollmentCommand, CtapCommand.bioEnrollment, reason: 'a reader with no fingerprint yet is still a reader');
  });

  test('reads a CTAP 2.0 key that has only the preview options', () {
    final info = _parse({
      1: ['U2F_V2', 'FIDO_2_0'],
      3: _aaguid,
      4: {'rk': true, 'up': true, 'clientPin': false, 'credentialMgmtPreview': true, 'userVerificationMgmtPreview': false},
      5: 1200,
      6: [1],
    });

    expect(info.fido2, isTrue);
    expect(info.pin, KeyPinState.notSet);
    expect(info.pinUvAuthProtocols, [1]);
    expect(info.pinUvAuthToken, isFalse);
    expect(info.forcePinChange, isFalse);
    expect(info.minPinLength, 4, reason: 'four when the key reports none');
    expect(info.firmwareVersion, isNull);
    expect(info.credentialManagementCommand, CtapCommand.credentialManagementPreview);
    expect(info.bioEnrollmentCommand, CtapCommand.bioEnrollmentPreview);
  });

  test('prefers the standard commands when a key reports both', () {
    final info = _parse({
      1: ['FIDO_2_0', 'FIDO_2_1_PRE'],
      3: _aaguid,
      4: {'credMgmt': true, 'credentialMgmtPreview': true, 'bioEnroll': true, 'userVerificationMgmtPreview': true},
    });

    expect(info.fido2, isTrue);
    expect(info.credentialManagementCommand, CtapCommand.credentialManagement);
    expect(info.bioEnrollmentCommand, CtapCommand.bioEnrollment);
  });

  test('reads a key with no PIN, no passkey list and no reader', () {
    final info = _parse({
      1: ['FIDO_2_0'],
      3: _aaguid,
      4: {'rk': true, 'credMgmt': false},
    });

    expect(info.pin, KeyPinState.unsupported);
    expect(info.credentialManagementCommand, isNull);
    expect(info.bioEnrollmentCommand, isNull);
    expect(info.pinUvAuthProtocols, isEmpty);
  });

  test('reads a U2F-only answer as no FIDO2', () {
    final info = _parse({
      1: ['U2F_V2'],
      3: _aaguid,
    });

    expect(info.fido2, isFalse);
    expect(info.options, isEmpty);
  });

  test('ignores members and options it does not know, and members of the wrong kind', () {
    final info = _parse({
      1: ['FIDO_2_0', 'FIDO_3_0', 7],
      2: ['hmac-secret', 'someFutureExtension'],
      3: _aaguid,
      4: {'clientPin': true, 'futureOption': true, 'notABoolean': 'yes'},
      6: [3, 'two', 1],
      12: 'true',
      13: 'six',
      14: 'new',
      21: [1, 2, 3],
      99: {'a': 1},
    });

    expect(info.versions, ['FIDO_2_0', 'FIDO_3_0']);
    expect(info.options, {'clientPin': true, 'futureOption': true});
    expect(info.pinUvAuthProtocols, [3, 1]);
    expect(info.forcePinChange, isFalse);
    expect(info.minPinLength, 4);
    expect(info.firmwareVersion, isNull);
  });

  test('tells two models apart by their AAGUID', () {
    final one = _parse({
      1: ['FIDO_2_0'],
      3: _aaguid,
    });
    final same = _parse({
      1: ['FIDO_2_1'],
      3: _aaguid,
    });
    final other = _parse({
      1: ['FIDO_2_0'],
      3: Uint8List(16),
    });

    expect(one.sameModelAs(same), isTrue);
    expect(one.sameModelAs(other), isFalse);
  });

  testOverEachLink('asks a key what it is', (kind) async {
    final fido = FakeFidoKey(pin: '123456', firmwareVersion: 328706, minPinLength: 6, fingerprintReader: FakeSupport.standard)
      ..extraOptions = {'somethingNew': true}
      ..extraInfo = {42: 'later'};
    final rig = await Rig.connect(fido, kind: kind);

    expect(rig.info.versions, ['U2F_V2', 'FIDO_2_0', 'FIDO_2_1']);
    expect(rig.info.aaguid, fido.aaguid);
    expect(rig.info.pin, KeyPinState.set);
    expect(rig.info.minPinLength, 6);
    expect(rig.info.firmwareVersion, 328706);
    expect(rig.info.remainingDiscoverableCredentials, 100);
    expect(rig.info.credentialManagementCommand, CtapCommand.credentialManagement);
    expect(rig.info.bioEnrollmentCommand, CtapCommand.bioEnrollment);
    expect(fido.requests, ['4']);
  });

  test('a refusal of getInfo is an error', () async {
    final rig = await Rig.connect(FakeFidoKey());

    await expectLater(rig.session.request(0x55), throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.invalidCommand)));
  });

  // No getInfo recorded from a real key is checked here: task 1.7 of
  // add-security-key-management could not run without a key.
}
