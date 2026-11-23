import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../fakes/fake_oath_key.dart';
import '../hex.dart';

List<int> _tlv(int tag, List<int> value) => [tag, value.length, ...value];

Uint8List _step(int counter) => Uint8List(8)..buffer.asByteData().setUint64(0, counter);

/// CALCULATE, truncated, sent straight to the application.
(List<int>, int) _calculate(FakeOathKey key, String name, [List<int> challenge = const []]) =>
    key.command(0, 0xa2, 0, 1, Uint8List.fromList([..._tlv(0x71, utf8.encode(name)), ..._tlv(0x74, challenge)]));

/// The digits of a truncated answer, `76 05 digits value`.
String _code(List<int> answer) {
  expect(answer.sublist(0, 2), [0x76, 5]);
  final value = answer[3] << 24 | answer[4] << 16 | answer[5] << 8 | answer[6];
  var modulus = 1;
  for (var i = 0; i < answer[2]; i++) {
    modulus *= 10;
  }
  return '${value % modulus}'.padLeft(answer[2], '0');
}

OtpAccount _account(List<int> secret, {String algorithm = 'SHA1', int digits = 6, OtpType type = OtpType.totp, int? counter}) => OtpAccount(
  id: 'a',
  type: type,
  issuer: 'Example',
  label: 'alice@example.org',
  secret: base32Encode(secret),
  algorithm: algorithm,
  digits: digits,
  counter: counter,
  addedAt: 0,
);

void main() {
  // The secrets of RFC 6238 appendix B, one per hash.
  final secrets = {
    'SHA1': ascii.encode('12345678901234567890'),
    'SHA256': ascii.encode('12345678901234567890123456789012'),
    'SHA512': ascii.encode('1234567890123456789012345678901234567890123456789012345678901234'),
  };

  test('its time-based codes for the RFC 6238 secrets are the ones codeAt gives', () {
    const times = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000];
    for (final MapEntry(key: algorithm, value: secret) in secrets.entries) {
      final key = FakeOathKey(accounts: [FakeOathAccount('Example:alice@example.org', secret, algorithm: algorithm, digits: 8)]);
      key.selectAnswer;
      for (final time in times) {
        final (answer, sw) = _calculate(key, 'Example:alice@example.org', _step(time ~/ 30));
        expect(sw, 0x9000);
        expect(_code(answer), codeAt(_account(secret, algorithm: algorithm, digits: 8), time), reason: '$algorithm at $time');
      }
    }
    // And the first of them is the RFC's own.
    final key = FakeOathKey(accounts: [FakeOathAccount('a', secrets['SHA1']!, digits: 8)])..selectAnswer;
    expect(_code(_calculate(key, 'a', _step(1)).$1), '94287082');
  });

  test('its counter-based codes for the RFC 4226 secret are the ones codeAt gives, one counter each', () {
    final secret = secrets['SHA1']!;
    final key = FakeOathKey(accounts: [FakeOathAccount('Example:counter', secret, hotp: true)])..selectAnswer;
    const rfc = ['755224', '287082', '359152', '969429', '338314'];
    for (var count = 0; count < rfc.length; count++) {
      final (answer, sw) = _calculate(key, 'Example:counter');
      expect(sw, 0x9000);
      expect(_code(answer), rfc[count]);
      expect(_code(answer), codeAt(_account(secret, type: OtpType.hotp, counter: count), 0));
    }
    expect(key.find('Example:counter')!.counter, rfc.length);
  });

  test('answers SELECT with its version and id, and a challenge once it has a password', () {
    final key = FakeOathKey(version: [5, 7, 1], id: [9, 8, 7, 6, 5, 4, 3, 2]);
    expect(
      hex(key.selectAnswer),
      '7903050701'
      '71080908070605040302',
    );
    expect(key.capacity, 64);

    key.password = 'correct horse';
    final answer = key.selectAnswer;
    expect(
      hex(answer.sublist(0, 15)),
      '7903050701'
      '71080908070605040302',
    );
    expect(answer.sublist(15, 17), [0x74, 8]);
    expect(answer.sublist(25), [0x7b, 1, 1]);
    expect(key.selectAnswer.sublist(17, 25), isNot(answer.sublist(17, 25)), reason: 'each SELECT has its own challenge');
  });

  test('hands a long answer out in parts, 61xx and SEND REMAINING', () {
    final key = FakeOathKey(
      version: [5, 7, 0],
      accounts: [for (var i = 0; i < 40; i++) FakeOathAccount('Example:account-number-$i@example.org', secrets['SHA1']!)],
    )..selectAnswer;
    final whole = <int>[];
    var (part, sw) = key.command(0, 0xa1, 0, 0, Uint8List(0));
    whole.addAll(part);
    var rounds = 0;
    while (sw >> 8 == 0x61) {
      expect(part, hasLength(255));
      (part, sw) = key.command(0, 0xa5, 0, 0, Uint8List(0));
      whole.addAll(part);
      rounds++;
    }
    expect(sw, 0x9000);
    expect(rounds, greaterThan(3));
    expect(utf8.decode(whole, allowMalformed: true), contains('Example:account-number-39@example.org'));
  });

  test('says 6a84 when full, 6982 when locked, 6984 for a name it does not have and 6a80 for nonsense', () {
    final secret = secrets['SHA1']!;
    List<int> put(String name) => [
      ..._tlv(0x71, utf8.encode(name)),
      ..._tlv(0x73, [0x21, 6, ...secret]),
    ];
    final key = FakeOathKey(capacity: 2)..selectAnswer;
    expect(key.command(0, 0x01, 0, 0, Uint8List.fromList(put('a'))).$2, 0x9000);
    expect(key.command(0, 0x01, 0, 0, Uint8List.fromList(put('b'))).$2, 0x9000);
    expect(key.command(0, 0x01, 0, 0, Uint8List.fromList(put('c'))).$2, 0x6a84);
    expect(key.command(0, 0x01, 0, 0, Uint8List.fromList(put('a'))).$2, 0x9000, reason: 'a name it has is replaced');

    expect(key.command(0, 0x02, 0, 0, Uint8List.fromList(_tlv(0x71, utf8.encode('nobody')))).$2, 0x6984);
    expect(_calculate(key, 'nobody', _step(1)).$2, 0x6984);
    expect(key.command(0, 0x01, 0, 0, Uint8List.fromList([0x71, 9, 1])).$2, 0x6a80);
    expect(key.command(0, 0x04, 0, 0, Uint8List(0)).$2, 0x6a80, reason: 'RESET without DE AD');

    key.password = 'correct horse';
    key.selectAnswer;
    expect(key.command(0, 0xa1, 0, 0, Uint8List(0)).$2, 0x6982);
    expect(_calculate(key, 'a', _step(1)).$2, 0x6982);
  });

  test('opens for the proof of its password and proves itself in return', () {
    final key = FakeOathKey(password: 'correct horse', accounts: [FakeOathAccount('a', secrets['SHA1']!)]);
    final challenge = key.selectAnswer.sublist(17, 25);
    final mine = [1, 1, 2, 3, 5, 8, 13, 21];
    List<int> validate(List<int> accessKey) => [..._tlv(0x75, Hmac(sha1, accessKey).convert(challenge).bytes), ..._tlv(0x74, mine)];

    expect(key.command(0, 0xa3, 0, 0, Uint8List.fromList(validate(List.filled(16, 7)))).$2, 0x6a80);
    expect(key.command(0, 0xa1, 0, 0, Uint8List(0)).$2, 0x6982);

    final (answer, sw) = key.command(0, 0xa3, 0, 0, Uint8List.fromList(validate(key.accessKey!)));
    expect(sw, 0x9000);
    expect(answer, [0x75, 20, ...Hmac(sha1, key.accessKey!).convert(mine).bytes]);
    expect(key.command(0, 0xa1, 0, 0, Uint8List(0)).$2, 0x9000);
  });

  test('keeps a touch account and a counter account out of CALCULATE ALL, and waits for the touch', () {
    final secret = secrets['SHA1']!;
    final key = FakeOathKey(
      accounts: [
        FakeOathAccount('Example:alice@example.org', secret),
        FakeOathAccount('Example:touch', secret, touch: true),
        FakeOathAccount('Example:counter', secret, hotp: true),
      ],
    )..selectAnswer;
    final (answer, sw) = key.command(0, 0xa4, 0, 1, Uint8List.fromList(_tlv(0x74, _step(1))));
    expect(sw, 0x9000);
    expect(
      hex(answer),
      '${hex(_tlv(0x71, utf8.encode('Example:alice@example.org')))}76050641397eea'
      '${hex(_tlv(0x71, utf8.encode('Example:touch')))}7c0106'
      '${hex(_tlv(0x71, utf8.encode('Example:counter')))}770106',
    );
    expect(key.find('Example:counter')!.counter, 0, reason: 'CALCULATE ALL does not move a counter');

    key.touchGiven = false;
    expect(_calculate(key, 'Example:touch', _step(1)).$2, 0x6982);
    key.touchGiven = true;
    expect(_code(_calculate(key, 'Example:touch', _step(1)).$1), '287082');
  });

  test('RESET empties it, drops the password and gives it a new id', () {
    final key = FakeOathKey(password: 'correct horse', accounts: [FakeOathAccount('a', secrets['SHA1']!)]);
    final before = [...key.id];
    key.selectAnswer;
    expect(key.command(0, 0x04, 0xde, 0xad, Uint8List(0)).$2, 0x9000);
    expect(key.accounts, isEmpty);
    expect(key.accessKey, isNull);
    expect(key.id, isNot(before));
    expect(key.selectAnswer, hasLength(15));
  });
}
