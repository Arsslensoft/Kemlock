// Writes and checks test/fixtures/autofill/codes.json: the time-based
// accounts of test/fixtures/otp/codes.json as the autofill copy holds them,
// with the codes the TypeScript app made for them. The Swift and Kotlin
// tests make codes from that copy, so all three are held to the same codes.
//
// After changing the copy's format, write it again with
//   UPDATE_AUTOFILL_FIXTURE=true flutter test test/features/autofill/autofill_fixture_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/autofill/autofill_copy.dart';
import 'package:kemlock/models/otp_account.dart';

typedef Json = Map<String, Object?>;

const _path = 'test/fixtures/autofill/codes.json';

/// The fixture as the copy builder makes it today.
Json build() {
  final source = jsonDecode(File('test/fixtures/otp/codes.json').readAsStringSync()) as Json;
  final entries = <AutofillEntry>[];
  final codes = <Json>[];
  for (final (i, item) in (source['codes']! as List<Object?>).cast<Json>().indexed) {
    final account = OtpAccount.fromJson({...item['account']! as Json, 'id': 'c$i', 'issuer': 'ACME', 'label': 'alice', 'addedAt': 0});
    final entry = autofillEntry(account);
    if (entry == null) continue;
    // A code [offset] windows away is the code of a time that many periods away
    final nowSec = (item['nowSec']! as int) + (item['offset']! as int) * account.period;
    if (nowSec < 0) continue;
    entries.add(entry);
    codes.add({'account': entry.id, 'nowSec': nowSec, 'code': item['code']});
  }
  return {
    'about':
        'The time-based accounts of test/fixtures/otp/codes.json, which the TypeScript app made, as the autofill copy '
        'holds them, with the codes that app made for them. Written by test/features/autofill/autofill_fixture_test.dart; '
        'the Swift and Kotlin autofill tests read it.',
    'copy': autofillCopy('fixture', entries),
    'codes': codes,
  };
}

void main() {
  final fixture = build();
  final text = '${const JsonEncoder.withIndent('  ').convert(fixture)}\n';

  if (Platform.environment['UPDATE_AUTOFILL_FIXTURE'] == 'true') {
    File(_path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  test('$_path is what the copy builder makes', () {
    expect(File(_path).readAsStringSync(), text, reason: 'Write it again with UPDATE_AUTOFILL_FIXTURE=true.');
  });

  test('holds TOTP and Steam accounts with codes of every algorithm and length', () {
    final accounts = ((fixture['copy']! as Json)['accounts']! as List<Object?>).cast<Json>();
    expect({for (final a in accounts) a['kind']}, {'totp', 'steam'});
    expect({for (final a in accounts) a['algorithm']}, containsAll(['SHA1', 'SHA224', 'SHA256', 'SHA512']));
    expect({for (final a in accounts) a['digits']}, containsAll([1, 5, 6, 7, 8, 9, 10]));
    expect((fixture['codes']! as List<Object?>).length, greaterThan(80));
  });

  test('its codes are the ones the app makes from the same accounts', () {
    final source = jsonDecode(File('test/fixtures/otp/codes.json').readAsStringSync()) as Json;
    final items = (source['codes']! as List<Object?>).cast<Json>();
    for (final code in (fixture['codes']! as List<Object?>).cast<Json>()) {
      final i = int.parse((code['account']! as String).substring(1));
      final account = OtpAccount.fromJson({...items[i]['account']! as Json, 'id': 'c$i', 'issuer': 'ACME', 'label': 'alice', 'addedAt': 0});
      expect(codeAt(account, code['nowSec']! as int), code['code'], reason: jsonEncode(code));
    }
  });
}
