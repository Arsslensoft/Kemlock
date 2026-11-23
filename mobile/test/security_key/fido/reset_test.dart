import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/fido/get_info.dart';
import 'package:kemlock/security_key/fido/reset.dart';

import '../../fakes/fake_fido_key.dart';
import 'rig.dart';

FakeFidoKey _usedKey() => FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard)
  ..addPasskey('github.com', 'adalovelace')
  ..addPasskey('google.com', 'ada@example.org')
  ..addFingerprint('Thumb');

void main() {
  testOverEachLink('resets a key in time, after a touch, and leaves it with nothing', (kind) async {
    final fido = _usedKey();
    final rig = await Rig.connect(fido, kind: kind);
    final touches = <bool>[];
    rig.connection.onTouchNeeded = touches.add;
    rig.phone.elapse(const Duration(seconds: 3));

    await resetKey(rig.session);

    expect(touches, [true, false]);
    expect(fido.pin, isNull);
    expect(fido.credentials, isEmpty);
    expect(fido.fingerprints, isEmpty);
    expect(fido.retries, 8);
    final info = await getInfo(rig.session);
    expect(info.pin, KeyPinState.notSet);
    expect(info.remainingDiscoverableCredentials, 100);
  });

  testOverEachLink('is refused when it comes too long after the key got power', (kind) async {
    final fido = _usedKey();
    final rig = await Rig.connect(fido, kind: kind);
    rig.phone.elapse(const Duration(seconds: 11));

    await expectLater(resetKey(rig.session), throwsA(isA<ResetRefused>().having((e) => e.refusal, 'refusal', ResetRefusal.notAllowed)));

    expect(fido.pin, '123456');
    expect(fido.credentials, hasLength(2));

    await rig.reconnect();
    await resetKey(rig.session);
    expect(fido.pin, isNull);
  });

  testOverEachLink('is not done when no touch comes in time', (kind) async {
    final fido = _usedKey()..touches = false;
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(
      resetKey(rig.session),
      throwsA(isA<ResetRefused>().having((e) => e.refusal, 'refusal', ResetRefusal.noTouch).having((e) => e.status, 'status', 0x2f)),
    );

    expect(fido.pin, '123456');
    expect(fido.credentials, hasLength(2));
  });

  test('is refused over a link the key does not reset over', () async {
    final fido = _usedKey()..noResetOver = {SecurityKeyLinkKind.nfc};
    final overNfc = await Rig.connect(fido);

    await expectLater(resetKey(overNfc.session), throwsA(isA<ResetRefused>().having((e) => e.refusal, 'refusal', ResetRefusal.notAllowed)));
    expect(fido.pin, '123456');

    final overUsb = await Rig.connect(fido, kind: SecurityKeyLinkKind.usbHid);
    await resetKey(overUsb.session);
    expect(fido.pin, isNull);
  });

  test('needs no PIN, even when the PIN is locked for good', () async {
    final fido = _usedKey()..retries = 0;
    final rig = await Rig.connect(fido, kind: SecurityKeyLinkKind.usbHid);
    final mark = fido.requests.length;

    await resetKey(rig.session);

    expect(rig.requestsSince(mark), ['7']);
    expect(fido.pin, isNull);
    expect(fido.retries, 8);
  });
}
