import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/apdu.dart';
import 'package:kemlock/security_key/oath/oath_messages.dart';
import 'package:kemlock/security_key/oath/oath_session.dart';

import '../hex.dart';

typedef _Json = Map<String, Object?>;

final _fixtures = jsonDecode(File('test/fixtures/security_keys/oath/exchanges.json').readAsStringSync()) as _Json;
final _exchanges = _fixtures['exchanges']! as _Json;
final _values = _fixtures['values']! as _Json;
final _bad = _fixtures['malformed']! as _Json;

_Json _exchange(String name) => _exchanges[name]! as _Json;

String _sent(ApduCommand command) => hex(command.encodeShort());

Matcher _throwsMalformed = throwsA(isA<OathError>().having((error) => error.failure, 'failure', OathFailure.malformed));

OathType _type(Object? name) => OathType.values.byName(name! as String);

void main() {
  test('reads what the application says of itself, with and without a password', () {
    for (final name in ['select', 'selectWithPassword']) {
      final exchange = _exchange(name);
      final expected = exchange['expect']! as _Json;
      expect(_sent(selectByName(oathAid)), exchange['command']);
      final select = parseOathSelect(unhex(exchange['answer']! as String));
      expect('${select.version}', expected['version']);
      expect(select.device, expected['device']);
      expect(select.hasPassword, expected['hasPassword']);
      expect(select.challenge == null ? null : hex(select.challenge!), expected['challenge']);
    }
  });

  test('knows what each firmware takes', () {
    expect(const OathVersion(4, 3, 0).takesSha512, isFalse);
    expect(const OathVersion(4, 3, 1).takesSha512, isTrue);
    expect(const OathVersion(4, 2, 3).takesTouch, isFalse);
    expect(const OathVersion(4, 2, 4).takesTouch, isTrue);
    expect(const OathVersion(5, 6, 9).capacity, 32);
    expect(const OathVersion(5, 7, 0).capacity, 64);
  });

  test('builds LIST and reads every account of its answer', () {
    final exchange = _exchange('list');
    expect(_sent(oathListCommand()), exchange['command']);
    final listed = parseOathList(unhex(exchange['answer']! as String));
    expect([
      for (final entry in listed) {'name': utf8.decode(entry.name), 'type': entry.type.name, 'algorithm': entry.algorithm.label},
    ], exchange['expect']);
    expect(parseOathList(const []), isEmpty, reason: 'a key with no account answers nothing');
  });

  test('builds CALCULATE and reads a truncated and a whole answer down to the digits', () {
    final exchange = _exchange('calculate');
    final command = oathCalculateCommand(utf8.encode(exchange['name']! as String), oathChallenge(exchange['step']! as int));
    expect(_sent(command), exchange['command']);
    for (final name in ['calculate', 'calculateFull', 'calculateHotp']) {
      final expected = _exchange(name)['expect']! as _Json;
      final code = parseOathCalculate(unhex(_exchange(name)['answer']! as String));
      expect(code.digits, expected['digits'], reason: name);
      expect(code.text, expected['code'], reason: name);
    }
    final hotp = _exchange('calculateHotp');
    expect(_sent(oathCalculateCommand(utf8.encode(hotp['name']! as String), const [])), hotp['command']);
  });

  test('pads a short code with zeros and cuts to the digits asked', () {
    expect(const OathCode(6, 1234).text, '001234');
    expect(const OathCode(8, 1094287082).text, '94287082');
    expect(const OathCode(6, 1094287082).text, '287082');
  });

  test('builds CALCULATE ALL and reads codes, touch accounts and counter accounts', () {
    final exchange = _exchange('calculateAll');
    expect(_sent(oathCalculateAllCommand(oathChallenge(exchange['step']! as int))), exchange['command']);
    final all = parseOathCalculateAll(unhex(exchange['answer']! as String));
    expect([
      for (final entry in all)
        {'name': utf8.decode(entry.name), 'code': ?entry.code?.text, if (entry.touch) 'touch': true, if (entry.hotp) 'hotp': true},
    ], exchange['expect']);
  });

  test('builds PUT with the property, the counter, and the secret as the key stores it', () {
    for (final name in ['put', 'putHotpWithTouch', 'putLongSecret', 'putShortSecret']) {
      final exchange = _exchange(name);
      final command = oathPutCommand(
        name: utf8.encode(exchange['name']! as String),
        type: _type(exchange['type']),
        algorithm: OathAlgorithm.named(exchange['algorithm']! as String)!,
        digits: exchange['digits']! as int,
        secret: unhex(exchange['secret']! as String),
        touch: exchange['touch'] == true,
        counter: (exchange['counter'] as int?) ?? 0,
      );
      expect(_sent(command), exchange['command'], reason: name);
    }
  });

  test('builds DELETE, SET CODE, VALIDATE, RESET and SEND REMAINING', () {
    final accessKey = unhex(_values['accessKey']! as String);
    final mine = unhex(_values['ourChallenge']! as String);
    final theirs = unhex(_values['keyChallenge']! as String);
    expect(hex(oathAccessKey(_values['password']! as String, unhex(_values['id']! as String))), _values['accessKey']);

    expect(_sent(oathDeleteCommand(utf8.encode(_exchange('delete')['name']! as String))), _exchange('delete')['command']);
    expect(_sent(oathSetCodeCommand(accessKey, mine, oathProof(accessKey, mine))), _exchange('setCode')['command']);
    expect(_sent(oathClearCodeCommand()), _exchange('clearCode')['command']);
    expect(_sent(oathValidateCommand(oathProof(accessKey, theirs), mine)), _exchange('validate')['command']);
    expect(hex(parseOathValidate(unhex(_exchange('validate')['answer']! as String))), hex(oathProof(accessKey, mine)));
    expect(_sent(oathResetCommand()), _exchange('reset')['command']);
    expect(_sent(ApduCommand(ins: OathIns.sendRemaining, le: apduShortLe)), _exchange('sendRemaining')['command']);
  });

  test('refuses a malformed answer of each kind whole, with a typed error', () {
    final parsers = <String, Object? Function(List<int>)>{
      'select': parseOathSelect,
      'list': parseOathList,
      'calculate': parseOathCalculate,
      'calculateAll': parseOathCalculateAll,
      'validate': parseOathValidate,
    };
    for (final MapEntry(key: kind, value: parse) in parsers.entries) {
      final answers = (_bad[kind]! as List<Object?>).cast<String>();
      expect(answers, isNotEmpty);
      for (final answer in answers) {
        expect(() => parse(unhex(answer)), _throwsMalformed, reason: '$kind "$answer"');
      }
    }
  });

  test('a list cut anywhere is an error or a whole shorter list of whole entries, never a damaged one', () {
    final whole = unhex(_exchange('list')['answer']! as String);
    final names = [for (final entry in parseOathList(whole)) utf8.decode(entry.name)];
    for (var cut = 1; cut < whole.length; cut++) {
      try {
        final part = parseOathList(whole.sublist(0, cut));
        // Only a cut between two entries reads, and then as the entries before it.
        expect([for (final entry in part) utf8.decode(entry.name)], names.sublist(0, part.length), reason: 'cut at $cut');
      } on OathError catch (error) {
        expect(error.failure, OathFailure.malformed);
      }
    }
  });

  test('reads and writes lengths of one, two and three bytes', () {
    for (final length in [0, 1, 127, 128, 255, 256, 1000]) {
      final value = List.filled(length, 7);
      final read = readOathTlvs(oathTlv(0x71, value));
      expect(read.single.tag, 0x71);
      expect(read.single.value, value);
    }
    expect(() => readOathTlvs(const [0x71, 0x83, 0, 0, 1, 7]), _throwsMalformed);
  });
}
