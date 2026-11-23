import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/get_info.dart';

import '../../fakes/fake_fido_key.dart';
import 'rig.dart';

void main() {
  testOverEachLink('sets a first PIN', (kind) async {
    final fido = FakeFidoKey();
    final rig = await Rig.connect(fido, kind: kind);
    expect(rig.info.pin, KeyPinState.notSet);

    await rig.clientPin.setPin(pinBytes('123456'));

    expect(fido.pin, '123456');
    expect((await rig.token('123456', PinPermission.credentialManagement)).token, hasLength(32));
  });

  testOverEachLink('changes the PIN, after which only the new one works', (kind) async {
    final fido = FakeFidoKey(pin: '123456');
    final rig = await Rig.connect(fido, kind: kind);

    await rig.clientPin.changePin(pinBytes('123456'), pinBytes('nouveau code'));

    expect(fido.pin, 'nouveau code');
    await expectLater(rig.token('123456', PinPermission.credentialManagement), throwsA(isA<PinWrong>()));
    expect((await rig.token('nouveau code', PinPermission.credentialManagement)).token, hasLength(32));
  });

  testOverEachLink('says a PIN is wrong and how many tries are left', (kind) async {
    final fido = FakeFidoKey(pin: '123456')..retries = 6;
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(
      rig.token('000000', PinPermission.credentialManagement),
      throwsA(isA<PinWrong>().having((e) => e.retries, 'retries', 5)),
    );
    await expectLater(
      rig.clientPin.changePin(pinBytes('000000'), pinBytes('654321')),
      throwsA(isA<PinWrong>().having((e) => e.retries, 'retries', 4)),
    );
    expect(fido.pin, '123456');
    expect(await rig.clientPin.retries(), 4);
  });

  testOverEachLink('after a wrong PIN sends nothing more until it is called again', (kind) async {
    final fido = FakeFidoKey(pin: '123456');
    final rig = await Rig.connect(fido, kind: kind);
    final mark = fido.requests.length;

    await expectLater(rig.token('000000', PinPermission.credentialManagement), throwsA(isA<PinWrong>()));

    // Key agreement, the one try, then the count of tries left: the PIN is not sent a second time.
    expect(rig.requestsSince(mark), ['6.2', '6.9', '6.1']);
    final frames = rig.phone.sent.length;
    await pumpEventQueue();
    expect(rig.phone.sent, hasLength(frames));
    expect(fido.retries, 7);
  });

  testOverEachLink('says to present the key again after three wrong PINs in a row', (kind) async {
    final fido = FakeFidoKey(pin: '123456');
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(rig.token('0000', PinPermission.credentialManagement), throwsA(isA<PinWrong>()));
    await expectLater(rig.token('0000', PinPermission.credentialManagement), throwsA(isA<PinWrong>()));
    await expectLater(rig.token('0000', PinPermission.credentialManagement), throwsA(isA<PinLockedUntilReconnected>()));
    await expectLater(rig.token('123456', PinPermission.credentialManagement), throwsA(isA<PinLockedUntilReconnected>()));

    await rig.reconnect();
    expect((await rig.token('123456', PinPermission.credentialManagement)).token, hasLength(32));
  });

  testOverEachLink('says the PIN is locked for good when no tries are left', (kind) async {
    final fido = FakeFidoKey(pin: '123456')..retries = 1;
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(rig.token('0000', PinPermission.credentialManagement), throwsA(isA<PinBlocked>()));
    await rig.reconnect();
    await expectLater(rig.token('123456', PinPermission.credentialManagement), throwsA(isA<PinBlocked>()));
    await expectLater(rig.clientPin.changePin(pinBytes('123456'), pinBytes('654321')), throwsA(isA<PinBlocked>()));
    expect(await rig.clientPin.retries(), 0);
  });

  testOverEachLink('says when the key’s own rules refuse the new PIN, and the old PIN still works', (kind) async {
    final fido = FakeFidoKey(pin: '123456')..refusesPin = (pin) => pin == '111111';
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(rig.clientPin.changePin(pinBytes('123456'), pinBytes('111111')), throwsA(isA<PinRefusedByKey>()));

    expect(fido.pin, '123456');
    expect((await rig.token('123456', PinPermission.credentialManagement)).token, hasLength(32));
  });

  testOverEachLink('refuses a PIN that is too short or too long before any frame is sent', (kind) async {
    final rig = await Rig.connect(FakeFidoKey(), kind: kind);
    final frames = rig.phone.sent.length;

    await expectLater(rig.clientPin.setPin(pinBytes('123')), throwsA(isA<PinTooShort>().having((e) => e.minimum, 'minimum', 4)));
    await expectLater(rig.clientPin.setPin(pinBytes('1' * 64)), throwsA(isA<PinTooLong>()));
    await expectLater(rig.clientPin.setPin(pinBytes('é' * 32)), throwsA(isA<PinTooLong>()), reason: '32 characters, 64 bytes');
    await expectLater(rig.clientPin.changePin(pinBytes('123456'), pinBytes('12')), throwsA(isA<PinTooShort>()));

    expect(rig.phone.sent, hasLength(frames));
    await rig.clientPin.setPin(pinBytes('1' * 63));
    expect(rig.fido.pin, '1' * 63);
  });

  test('holds a new PIN to the minimum the key reports, counted in characters', () async {
    final rig = await Rig.connect(FakeFidoKey(minPinLength: 6));
    final frames = rig.phone.sent.length;

    await expectLater(rig.clientPin.setPin(pinBytes('12345')), throwsA(isA<PinTooShort>().having((e) => e.minimum, 'minimum', 6)));
    await expectLater(rig.clientPin.setPin(pinBytes('ééééé')), throwsA(isA<PinTooShort>()), reason: 'five characters, ten bytes');
    expect(rig.phone.sent, hasLength(frames));

    await rig.clientPin.setPin(pinBytes('éééééé'));
    expect(rig.fido.pin, 'éééééé');
  });

  for (final protocols in [
    [1],
    [2],
    [1, 2],
    [2, 1],
    [7, 1],
  ]) {
    testOverEachLink('sets, changes and uses the PIN on a key that lists protocols $protocols', (kind) async {
      final fido = FakeFidoKey(pinProtocols: protocols)..addPasskey('example.org', 'ada');
      final rig = await Rig.connect(fido, kind: kind);
      final expected = protocols.firstWhere((protocol) => protocol == 1 || protocol == 2);

      expect(rig.clientPin.protocol.number, expected, reason: 'the first the key lists that the app knows');
      await rig.clientPin.setPin(pinBytes('123456'));
      await rig.clientPin.changePin(pinBytes('123456'), pinBytes('654321'));
      final token = await rig.token('654321', PinPermission.credentialManagement);

      expect(token.protocol.number, expected);
      expect(token.authenticate([1]), hasLength(expected == 1 ? 16 : 32));
      expect(fido.pin, '654321');
    });
  }

  test('cannot manage the PIN of a key whose only protocol it does not know', () async {
    final rig = await Rig.connect(FakeFidoKey(pinProtocols: [3]));
    final frames = rig.phone.sent.length;

    expect(rig.clientPin.supported, isFalse);
    await expectLater(rig.clientPin.setPin(pinBytes('123456')), throwsA(isA<PinProtocolUnknown>()));
    await expectLater(rig.token('123456', PinPermission.credentialManagement), throwsA(isA<PinProtocolUnknown>()));
    await expectLater(rig.clientPin.retries(), throwsA(isA<PinProtocolUnknown>()));
    expect(rig.phone.sent, hasLength(frames));
  });

  test('asks a CTAP 2.0 key for the older token, and a newer key for one with only the permission needed', () async {
    final old = await Rig.connect(FakeFidoKey.ctap20(pin: '123456'));
    var mark = old.fido.requests.length;
    await old.token('123456', PinPermission.credentialManagement);
    expect(old.requestsSince(mark), ['6.2', '6.5']);

    final modern = await Rig.connect(FakeFidoKey(pin: '123456'), kind: SecurityKeyLinkKind.usbHid);
    mark = modern.fido.requests.length;
    await modern.token('123456', PinPermission.bioEnrollment);
    expect(modern.requestsSince(mark), ['6.2', '6.9']);
  });

  test('says a key has no PIN when one is asked for', () async {
    final rig = await Rig.connect(FakeFidoKey());

    await expectLater(rig.token('123456', PinPermission.credentialManagement), throwsA(isA<PinNotSet>()));
  });
}
