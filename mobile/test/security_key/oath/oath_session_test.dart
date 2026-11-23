import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/oath/oath_messages.dart';
import 'package:kemlock/security_key/oath/oath_session.dart';

import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_security_keys.dart';

final _secret = ascii.encode('12345678901234567890');

/// A fake key with the OATH application, connected over one link.
class _Rig {
  _Rig(this.oath, {SecurityKeyLinkKind kind = SecurityKeyLinkKind.nfc}) {
    final device = FakeKey(productName: 'Example Key', applets: [oath]).device(kinds: {kind});
    phone.arrive(device);
    connection = SecurityKeyConnection(
      phone,
      SecurityKeyDevice(
        id: device.id,
        links: [
          for (final MapEntry(key: linkKind, value: link) in device.links.entries)
            SecurityKeyLink(id: device.linkId(linkKind), kind: linkKind, extendedLength: link.extendedLength, frameSize: link.frameSize),
        ],
      ),
      now: phone.now,
    );
  }

  final FakeOathKey oath;
  final phone = FakeSecurityKeys();
  late final SecurityKeyConnection connection;

  Future<OathSession> open() => OathSession.open(connection, challenge: () => Uint8List.fromList(const [1, 1, 2, 3, 5, 8, 13, 21]));
}

Matcher _fails(OathFailure failure) => throwsA(isA<OathError>().having((error) => error.failure, 'failure', failure));

OtpAccount _vaultAccount({String algorithm = 'SHA1', int digits = 6, OtpType type = OtpType.totp, int? counter}) => OtpAccount(
  id: 'a',
  type: type,
  issuer: 'Example',
  label: 'alice@example.org',
  secret: base32Encode(_secret),
  algorithm: algorithm,
  digits: digits,
  counter: counter,
  addedAt: 0,
);

void main() {
  for (final kind in [SecurityKeyLinkKind.nfc, SecurityKeyLinkKind.usbCcid, SecurityKeyLinkKind.smartcard]) {
    test('every instruction goes to the key and comes back, over ${kind.name}', () async {
      final rig = _Rig(FakeOathKey(version: [5, 4, 3]), kind: kind);
      final oath = await rig.open();
      expect('${oath.select.version}', '5.4.3');
      expect(oath.select.device, '0102030405060708');
      expect(oath.needsPassword, isFalse);
      expect(await oath.list(), isEmpty);

      final name = utf8.encode('Example:alice@example.org');
      await oath.put(name: name, type: OathType.totp, algorithm: OathAlgorithm.sha1, digits: 6, secret: _secret);
      await oath.put(
        name: utf8.encode('Example:counter'),
        type: OathType.hotp,
        algorithm: OathAlgorithm.sha1,
        digits: 6,
        secret: _secret,
        counter: 3,
      );
      await oath.put(
        name: utf8.encode('Example:touch'),
        type: OathType.totp,
        algorithm: OathAlgorithm.sha256,
        digits: 8,
        secret: _secret,
        touch: true,
      );

      final listed = await oath.list();
      expect([for (final entry in listed) utf8.decode(entry.name)], ['Example:alice@example.org', 'Example:counter', 'Example:touch']);
      expect(listed[1].type, OathType.hotp);
      expect(listed[2].algorithm, OathAlgorithm.sha256);
      expect(rig.oath.find('Example:touch')!.touch, isTrue);

      final all = await oath.calculateAll(oathChallenge(1111111109 ~/ 30));
      expect(all[0].code!.text, codeAt(_vaultAccount(), 1111111109));
      expect(all[1].hotp, isTrue);
      expect(all[1].code, isNull);
      expect(all[2].touch, isTrue);
      expect(all[2].code, isNull);

      expect((await oath.calculate(name, oathChallenge(2))).text, codeAt(_vaultAccount(), 60));
      // The counter started at 3 and moves by one a request.
      expect((await oath.calculate(utf8.encode('Example:counter'))).text, codeAt(_vaultAccount(type: OtpType.hotp, counter: 3), 0));
      expect((await oath.calculate(utf8.encode('Example:counter'))).text, codeAt(_vaultAccount(type: OtpType.hotp, counter: 4), 0));
      expect(
        (await oath.calculate(utf8.encode('Example:touch'), oathChallenge(2))).text,
        codeAt(_vaultAccount(algorithm: 'SHA256', digits: 8), 60),
      );

      await oath.delete(name);
      expect(await oath.list(), hasLength(2));

      final before = oath.select.device;
      await oath.reset();
      expect(rig.oath.accounts, isEmpty);
      expect(oath.select.device, isNot(before), reason: 'the application has a new id after a reset');
      expect(await oath.list(), isEmpty);
    });
  }

  test('a list of 40 accounts arrives whole across continuations, asked for with SEND REMAINING', () async {
    final rig = _Rig(
      FakeOathKey(
        version: [5, 7, 0],
        accounts: [for (var i = 0; i < 40; i++) FakeOathAccount('Example:account-number-$i@example.org', _secret)],
      ),
    );
    final oath = await rig.open();

    final listed = await oath.list();
    expect([for (final entry in listed) utf8.decode(entry.name)], [for (var i = 0; i < 40; i++) 'Example:account-number-$i@example.org']);
    final all = await oath.calculateAll(oathChallenge(1));
    expect(all, hasLength(40));
    expect(all.every((entry) => entry.code!.text == '287082'), isTrue);

    expect(rig.oath.received.where((ins) => ins == OathIns.sendRemaining).length, greaterThan(6));
    expect(rig.phone.sent.any((frame) => frame.bytes.length > 1 && frame.bytes[1] == 0xc0), isFalse, reason: 'never GET RESPONSE');
  });

  test('a list cut short by the key leaving is an error, not a shorter list', () async {
    final rig = _Rig(
      FakeOathKey(
        version: [5, 7, 0],
        accounts: [for (var i = 0; i < 40; i++) FakeOathAccount('Example:account-number-$i@example.org', _secret)],
      ),
    );
    final oath = await rig.open();
    var remaining = 0;
    rig.phone.removeWhen = (frame) => frame[1] == OathIns.sendRemaining && ++remaining == 2;

    await expectLater(oath.list(), throwsA(isA<SecurityKeyRemoved>()));
  });

  test('each status word is its own error', () async {
    final rig = _Rig(
      FakeOathKey(capacity: 1, accounts: [FakeOathAccount('held', _secret), FakeOathAccount('touch', _secret, touch: true)]),
    );
    final oath = await rig.open();

    await expectLater(
      oath.put(name: utf8.encode('one too many'), type: OathType.totp, algorithm: OathAlgorithm.sha1, digits: 6, secret: _secret),
      throwsA(isA<OathError>().having((e) => e.failure, 'failure', OathFailure.full).having((e) => e.sw, 'sw', 0x6a84)),
    );
    await expectLater(oath.delete(utf8.encode('nobody')), _fails(OathFailure.noSuchAccount));
    await expectLater(oath.calculate(utf8.encode('nobody'), oathChallenge(1)), _fails(OathFailure.noSuchAccount));
    // A time-based account asked with no challenge is a command the key cannot read.
    await expectLater(oath.calculate(utf8.encode('held')), _fails(OathFailure.wrongSyntax));
    rig.oath.touchGiven = false;
    await expectLater(oath.calculate(utf8.encode('touch'), oathChallenge(1)), _fails(OathFailure.notTouched));

    // Another tool set a password since: the key now refuses with "authentication required".
    rig.oath.password = 'correct horse';
    final again = await _Rig(rig.oath).open();
    expect(again.needsPassword, isTrue);
    rig.oath.received.clear();
    await expectLater(again.list(), _fails(OathFailure.passwordNeeded));
    expect(rig.oath.received, isEmpty, reason: 'nothing is asked of a key that waits for its password');
  });

  test('a key that answers the selection with something else is not the code application', () async {
    final rig = _Rig(_Impostor());
    await expectLater(rig.open(), _fails(OathFailure.malformed));
    final none = _Rig(FakeOathKey());
    none.oath.accounts.clear();
    final connection = SecurityKeyConnection(none.phone, const SecurityKeyDevice(id: 'gone'));
    await expectLater(OathSession.open(connection), throwsA(isA<SecurityKeyNoApplication>()));
  });

  group('the password', () {
    test('the right one opens the key, proved both ways', () async {
      final rig = _Rig(FakeOathKey(password: 'correct horse', accounts: [FakeOathAccount('Example:alice@example.org', _secret)]));
      final oath = await rig.open();
      expect(oath.needsPassword, isTrue);

      await oath.validate(oathAccessKey('correct horse', oath.select.id));

      expect(oath.needsPassword, isFalse);
      expect(await oath.list(), hasLength(1));
    });

    test('a wrong one is said to be wrong, and no LIST is sent', () async {
      final rig = _Rig(FakeOathKey(password: 'correct horse', accounts: [FakeOathAccount('Example:alice@example.org', _secret)]));
      final oath = await rig.open();

      await expectLater(oath.validate(oathAccessKey('battery staple', oath.select.id)), _fails(OathFailure.wrongPassword));
      await expectLater(oath.list(), _fails(OathFailure.passwordNeeded));

      expect(rig.oath.received, [OathIns.validate]);
    });

    test('a key whose own answer is wrong is not trusted, and is asked nothing more', () async {
      final rig = _Rig(FakeOathKey(password: 'correct horse', accounts: [FakeOathAccount('Example:alice@example.org', _secret)]));
      rig.oath.wrongProof = true;
      final oath = await rig.open();

      await expectLater(oath.validate(oathAccessKey('correct horse', oath.select.id)), _fails(OathFailure.untrustedKey));
      await expectLater(oath.list(), _fails(OathFailure.untrustedKey));
      await expectLater(oath.calculateAll(oathChallenge(1)), _fails(OathFailure.untrustedKey));

      expect(rig.oath.received, [OathIns.validate]);
    });

    test('is set, changed and removed, each proved with the one before', () async {
      final rig = _Rig(FakeOathKey(accounts: [FakeOathAccount('Example:alice@example.org', _secret)]));
      var oath = await rig.open();
      await oath.setCode(oathAccessKey('first', oath.select.id));
      expect(oath.needsPassword, isTrue, reason: 'the key asks for it from now on');
      expect(rig.oath.accessKey, oathAccessKey('first', oath.select.id));

      oath = await rig.open();
      await expectLater(oath.setCode(oathAccessKey('second', oath.select.id)), _fails(OathFailure.passwordNeeded));
      await oath.validate(oathAccessKey('first', oath.select.id));
      await oath.setCode(oathAccessKey('second', oath.select.id));

      oath = await rig.open();
      await expectLater(oath.validate(oathAccessKey('first', oath.select.id)), _fails(OathFailure.wrongPassword));
      oath = await rig.open();
      await oath.validate(oathAccessKey('second', oath.select.id));
      await oath.clearCode();
      expect(oath.needsPassword, isFalse);
      expect(rig.oath.accessKey, isNull);
      expect(await oath.list(), hasLength(1));
    });
  });
}

/// An application under the same identifier that is not Yubico's.
class _Impostor extends FakeOathKey {
  @override
  List<int> get selectAnswer => ascii.encode('SECRETS');
}
