import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/key_reader.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../../fakes/fake_security_keys.dart';
import '../../security_key/soft_key.dart';

final _salt = Uint8List.fromList(List.generate(32, (i) => 0x10 + i));
const KeyPrompts _prompts = (nfcMessage: 'Hold your key', nfcFailure: 'No key');

Uint8List _pin(String pin) => Uint8List.fromList(utf8.encode(pin));

/// A fake phone, a software key held to it, and the reader over them.
class _Rig {
  _Rig(this.soft, {SecurityKeyCapabilities phone = FakeSecurityKeys.android, this.kinds = const {SecurityKeyLinkKind.nfc}})
    : phone = FakeSecurityKeys(phone: phone) {
    key = FakeKey(productName: 'Example Key', ctap: soft);
    reader = CtapKeyReader(this.phone, now: this.phone.now);
    present();
  }

  final SoftKey soft;
  final FakeSecurityKeys phone;
  final Set<SecurityKeyLinkKind> kinds;
  late final FakeKey key;
  late final CtapKeyReader reader;
  late FakeDevice device;

  /// The key is held to the phone, or plugged in.
  void present() => phone.arrive(device = key.device(kinds: kinds));

  /// The key is taken away and presented again.
  void presentAgain() {
    phone.remove(device);
    present();
  }

  Future<KeyEnrolment> enrol([String pin = '123456', List<Uint8List> exclude = const [], bool lastTry = false]) =>
      reader.enrol(pin: _pin(pin), salt: _salt, exclude: exclude, prompts: _prompts, lastTryConfirmed: lastTry);

  Future<KeyOutput> read(List<Uint8List> allow, {String pin = '123456', bool lastTry = false}) =>
      reader.read(pin: _pin(pin), salt: _salt, allow: allow, prompts: _prompts, lastTryConfirmed: lastTry);
}

// openspec: add-security-key-unlock, task 3.3
void main() {
  for (final kinds in [
    {SecurityKeyLinkKind.nfc},
    {SecurityKeyLinkKind.usbHid},
  ]) {
    test('enrols a key and reads it again, over ${kinds.first.name}', () async {
      final rig = _Rig(SoftKey(pin: '123456'), kinds: kinds);

      final enrolment = await rig.enrol();
      final output = await rig.read([enrolment.credential]);

      final credential = rig.soft.made.single;
      expect(enrolment.credential, credential.id);
      expect(enrolment.output, Hmac(sha256, credential.withUv).convert(_salt).bytes);
      expect(output.output, enrolment.output);
      expect(output.credential, credential.id);
      expect(enrolment.pinBound, isTrue);
      expect(enrolment.productName, kinds.contains(SecurityKeyLinkKind.nfc) ? isNull : 'Example Key');
      // One credential made, and its secret read twice before it was recorded
      expect(rig.soft.requests.where((request) => request == '1'), hasLength(1));
      expect(rig.soft.requests.where((request) => request == '2'), hasLength(3));
      // A token for each of the four, which a CTAP 2.1 key spends on the first thing it is used
      // for, and the count of tries read once for each time the key was presented
      expect(rig.soft.requests.where((request) => request == '6.9'), hasLength(4));
      expect(rig.soft.requests.where((request) => request == '6.1'), hasLength(2));
      // The search for a key ends with the read
      expect(rig.phone.isWatching, isFalse);
      expect(rig.reader.stage.value, KeyReadStage.idle);
      expect(rig.reader.coveredBySystem, isFalse);
    });
  }

  test('on an iPhone the key is read under the system’s sheet, which counts as the key’s own', () async {
    final rig = _Rig(SoftKey(pin: '123456'), phone: FakeSecurityKeys.iphone);
    final covered = <bool>[];
    rig.soft.onRequest = (_, _) => covered.add(rig.reader.coveredBySystem);

    final enrolment = await rig.enrol();

    expect(enrolment.output, hasLength(32));
    expect(rig.phone.calls, containsAllInOrder(['beginNfc Hold your key', 'endNfc']));
    expect(covered, isNotEmpty);
    expect(covered, everyElement(isTrue));
    expect(rig.reader.coveredBySystem, isFalse);
    expect(rig.phone.nfcSheetUp, isFalse);
  });

  test('a key that leaves halfway through an enrolment records nothing', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    var assertions = 0;
    // The second read never reaches the key
    rig.soft.onRequest = (command, _) {
      if (command == 0x02 && ++assertions == 2) rig.phone.remove(rig.device);
    };

    await expectLater(rig.enrol(), throwsA(isA<SecurityKeyError>()));
    expect(rig.reader.stage.value, KeyReadStage.idle);
  });

  test('a key with no PIN and no fingerprint is not enrolled', () async {
    final rig = _Rig(SoftKey());
    await expectLater(rig.enrol(), throwsA(isA<KeyHasNoPin>()));
    await expectLater(rig.enrol(''), throwsA(isA<KeyHasNoPin>()));
    expect(rig.soft.made, isEmpty);
  });

  test('no PIN typed for a key that has one and no fingerprint reader', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    await expectLater(rig.enrol(''), throwsA(isA<KeyPinNeeded>()));
    expect(rig.soft.made, isEmpty);
  });

  test('a key with a fingerprint on it is read with no PIN typed', () async {
    final soft = SoftKey(fingerprintReader: FakeSupport.standard)..addFingerprint('Index');
    final rig = _Rig(soft);

    final enrolment = await rig.enrol('');
    final output = await rig.read([enrolment.credential], pin: '');

    expect(output.output, enrolment.output);
    expect(output.output, Hmac(sha256, soft.made.single.withUv).convert(_salt).bytes);
  });

  test('a wrong PIN says how many tries the key has left, and sends the PIN once', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    final enrolment = await rig.enrol();

    await expectLater(rig.read([enrolment.credential], pin: '000000'), throwsA(isA<KeyPinWrong>().having((e) => e.retries, 'retries', 7)));
    expect(rig.soft.retries, 7);
    await expectLater(rig.read([enrolment.credential], pin: '111111'), throwsA(isA<KeyPinWrong>().having((e) => e.retries, 'retries', 6)));
    // The right PIN sets the key's count back
    await rig.read([enrolment.credential]);
    expect(rig.soft.retries, 8);
  });

  test('after three wrong PINs the key is refused until it is presented again', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    final enrolment = await rig.enrol();
    await expectLater(rig.read([enrolment.credential], pin: '000000'), throwsA(isA<KeyPinWrong>()));
    await expectLater(rig.read([enrolment.credential], pin: '000000'), throwsA(isA<KeyPinWrong>()));
    await expectLater(rig.read([enrolment.credential], pin: '000000'), throwsA(isA<KeyPinPaused>()));
    // Even the right PIN, and it costs no try
    await expectLater(rig.read([enrolment.credential]), throwsA(isA<KeyPinPaused>()));
    expect(rig.soft.retries, 5);

    rig.presentAgain();
    expect((await rig.read([enrolment.credential])).output, enrolment.output);
  });

  test('at the last try nothing is sent until it is confirmed', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    final enrolment = await rig.enrol();
    rig.soft.retries = 1;
    final before = rig.soft.requests.length;

    await expectLater(rig.read([enrolment.credential]), throwsA(isA<KeyPinLastTry>()));
    expect(rig.soft.retries, 1);
    expect(rig.soft.requests.sublist(before).where((request) => request == '6.9' || request == '6.5'), isEmpty);

    final output = await rig.read([enrolment.credential], lastTry: true);
    expect(output.output, enrolment.output);
  });

  test('a wrong PIN at the last try locks the key’s PIN for good', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    final enrolment = await rig.enrol();
    rig.soft.retries = 1;

    await expectLater(rig.read([enrolment.credential], pin: '000000', lastTry: true), throwsA(isA<KeyPinBlocked>()));
    // From then on nothing is sent at all
    final before = rig.soft.requests.length;
    await expectLater(rig.read([enrolment.credential]), throwsA(isA<KeyPinBlocked>()));
    expect(rig.soft.requests.sublist(before).where((request) => request == '6.9'), isEmpty);
    rig.presentAgain();
    await expectLater(rig.read([enrolment.credential], lastTry: true), throwsA(isA<KeyPinBlocked>()));
  });

  test('a key that is not the vault’s says so', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    await expectLater(rig.read([Uint8List.fromList(List.filled(64, 5))]), throwsA(isA<KeyNotEnrolled>()));
    // Its PIN was right, and its count is whole
    expect(rig.soft.retries, 8);
  });

  test('a key that is enrolled already is refused as a second key', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    final enrolment = await rig.enrol();
    await expectLater(rig.enrol('123456', [enrolment.credential]), throwsA(isA<KeyAlreadyEnrolled>()));
    expect(rig.soft.made, hasLength(1));
  });

  test('a key that cannot give a secret, or gives two different ones, is not enrolled', () async {
    final none = _Rig(SoftKey(pin: '123456')..set(hmacSecret: false));
    await expectLater(none.enrol(), throwsA(isA<KeyCannotGiveSecret>()));
    expect(none.soft.requests.where((request) => request.startsWith('6.')), isEmpty);

    final unsteady = _Rig(SoftKey(pin: '123456')..unsteady = true);
    await expectLater(unsteady.enrol(), throwsA(isA<KeyNotSteady>()));
  });

  test('a CTAP 2.0 key is enrolled as not tied to its PIN', () async {
    final rig = _Rig(SoftKey.ctap20(pin: '123456'));
    final enrolment = await rig.enrol();
    expect(enrolment.pinBound, isFalse);
    expect((await rig.read([enrolment.credential])).output, enrolment.output);

    final protected = _Rig(SoftKey.ctap20(pin: '123456', credProtect: true));
    expect((await protected.enrol()).pinBound, isTrue);
  });

  test('the PIN is cleared when a read ends, whether it worked or not', () async {
    final rig = _Rig(SoftKey(pin: '123456'));
    final pin = _pin('123456');
    final enrolment = await rig.reader.enrol(pin: pin, salt: _salt, exclude: const [], prompts: _prompts);
    expect(pin, everyElement(0));

    final wrong = _pin('000000');
    await expectLater(
      rig.reader.read(pin: wrong, salt: _salt, allow: [enrolment.credential], prompts: _prompts),
      throwsA(isA<KeyPinWrong>()),
    );
    expect(wrong, everyElement(0));

    // What the read gave is the caller's to clear, and the reader holds no copy
    final output = await rig.read([enrolment.credential]);
    final secret = Uint8List.fromList(output.output);
    output.wipe();
    expect(output.output, everyElement(0));
    expect((await rig.read([enrolment.credential])).output, secret);
  });

  test('says when no key can be reached at all', () async {
    final rig = _Rig(SoftKey(pin: '123456'), phone: SecurityKeyCapabilities.none);
    rig.phone.remove(rig.device);
    await expectLater(rig.enrol(), throwsA(isA<SecurityKeyUnavailable>()));
  });

  test('a key that only does the older two-step sign-in cannot open a vault', () async {
    final phone = FakeSecurityKeys();
    final reader = CtapKeyReader(phone, now: phone.now);
    phone.arrive(FakeKey(productName: 'Old key').device(kinds: {SecurityKeyLinkKind.nfc}));
    await expectLater(
      reader.enrol(pin: _pin('123456'), salt: _salt, exclude: const [], prompts: _prompts),
      throwsA(isA<KeyCannotGiveSecret>()),
    );
  });

  group('where a vault can open with a key', () {
    test('an Android phone with NFC or USB', () {
      expect(keyUnlockAvailability(FakeSecurityKeys.android, iPhoneProven: false), KeyUnlockAvailability.available);
      expect(keyUnlockAvailability(const SecurityKeyCapabilities(usb: true), iPhoneProven: false), KeyUnlockAvailability.available);
      expect(keyUnlockAvailability(SecurityKeyCapabilities.none, iPhoneProven: true), KeyUnlockAvailability.noKeyReachable);
    });

    test('an iPhone only once the exchange is proven there, and never an iPad', () {
      expect(keyUnlockAvailability(FakeSecurityKeys.iphone, iPhoneProven: false), KeyUnlockAvailability.notOnIPhoneYet);
      expect(keyUnlockAvailability(FakeSecurityKeys.iphone, iPhoneProven: true), KeyUnlockAvailability.available);
      expect(keyUnlockAvailability(FakeSecurityKeys.ipad, iPhoneProven: true), KeyUnlockAvailability.noKeyReachable);
    });

    test('the iPhone build waits for the prototype', () => expect(iPhoneKeyExchangeProven, isFalse));
  });
}
