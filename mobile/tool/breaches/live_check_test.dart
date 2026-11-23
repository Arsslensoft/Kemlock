// Runs the Have I Been Pwned requests the app makes against the real service, with the
// app's own code, and prints what was sent. It is for checking by hand that the service
// still answers as the tests' fakes do, so it is kept out of test/ and the suite never
// runs it:
//
//   flutter test tool/breaches/live_check_test.dart
//
// It sends the SHA-1 prefixes of "password1" and of a random password, and asks for the
// latest breach and the list. Nothing of any vault is involved.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/breaches/breach_list.dart';
import 'package:kemlock/features/breaches/breach_refresh.dart';
import 'package:kemlock/features/breaches/pwned_passwords.dart';

/// Passes requests on and keeps each one's line.
class _Logging extends http.BaseClient {
  final _inner = http.Client();
  final sent = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add('${request.method} ${request.url} ${request.headers}');
    return _inner.send(request);
  }
}

Future<String> _agent() async => 'Kemlock (tool/breaches/live_check_test.dart)';

void main() {
  test('Pwned Passwords knows a leaked password and not a random one, one request each', () async {
    final client = _Logging();
    final pwned = PwnedPasswords(client, userAgent: _agent);
    final random = Random.secure();
    final fresh = String.fromCharCodes([for (var i = 0; i < 20; i++) 33 + random.nextInt(94)]);

    final leaked = await pwned.timesLeaked('password1');
    final clean = await pwned.timesLeaked(fresh);

    // ignore: avoid_print
    print('"password1" appears $leaked times; a random 20-character password $clean times\n${client.sent.join('\n')}');
    expect(leaked, greaterThan(100000));
    expect(clean, 0);
    expect(client.sent, hasLength(2));
    expect(client.sent.first, startsWith('GET https://api.pwnedpasswords.com/range/E38AD '));
  });

  test('the update finds a breach missing from the phone, with two requests, and none the same day after', () async {
    final client = _Logging();
    // The bundled list without its newest breach, as if made before it was listed
    final bundled = BreachList.fromJson(jsonDecode(File(BreachList.asset).readAsStringSync()) as Map<String, Object?>);
    final newest = bundled.entries.reduce((a, b) => a.addedDate.compareTo(b.addedDate) >= 0 ? a : b);
    final older = BreachList.fromJson({
      ...bundled.toJson(),
      'updated': '2000-01-01',
      'entries': [
        for (final breach in bundled.entries)
          if (breach.name != newest.name) breach.toRow(),
      ],
    });
    final refresh = BreachRefresh(client: client, userAgent: _agent, store: KeyValueStore.memory(), now: DateTime.now);

    final stored = await refresh.run(older);
    final again = await refresh.run(refresh.inUse(older));

    // ignore: avoid_print
    print('stored a list of ${refresh.stored()?.entries.length} breaches with ${newest.name}\n${client.sent.join('\n')}');
    expect(stored, isTrue);
    expect(refresh.stored()!.has(newest.name), isTrue);
    expect(again, isFalse);
    expect(
      [for (final line in client.sent) line.split(' ')[1]],
      ['https://haveibeenpwned.com/api/v3/latestbreach', 'https://haveibeenpwned.com/api/v3/breaches'],
    );
  });
}
