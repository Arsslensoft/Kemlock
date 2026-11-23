import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/contacts/lookup/lookup_http.dart';
import 'package:kemlock/features/contacts/lookup/vks.dart';

import 'lookup_kit.dart';

void main() {
  late FakeKeyServices services;

  setUp(() => services = FakeKeyServices());

  Future<LookupOutcome> search(String address) => searchVks(addressOf(address), client: services.client);

  test('asks for the address, percent-encoded, at keys.openpgp.org’s by-email lookup', () async {
    await search('alan@example.org');
    await search('grace+keys@example.org');

    expect(services.requests.map((url) => url.toString()), [
      'https://keys.openpgp.org/vks/v1/by-email/alan%40example.org',
      'https://keys.openpgp.org/vks/v1/by-email/grace%2Bkeys%40example.org',
    ]);
  });

  test('gives the bytes of a 200', () async {
    services.keyServer('alan@example.org', 200, lookupAnswer(vksAlan));

    expect(await search('alan@example.org'), isA<LookupAnswered>().having((a) => a.bytes, 'bytes', lookupAnswer(vksAlan)));
  });

  test('says no key for a 404 and slow down for a 429', () async {
    services.keyServer('slow@example.org', 429);

    expect(await search('alan@example.org'), isA<LookupNoKey>());
    expect(await search('slow@example.org'), isA<LookupSlowDown>());
  });

  test('could not reach the server on a 500 or a failed connection', () async {
    services.keyServer('alan@example.org', 500);
    expect(await search('alan@example.org'), isA<LookupUnreachable>());

    services.unreachable.add(vksHost);
    expect(await search('alan@example.org'), isA<LookupUnreachable>());
  });

  test('follows no redirect', () async {
    final url = vksUri(addressOf('alan@example.org'));
    services
      ..answers['${url.host}${url.path}'] = ((_) async => http.Response('', 302, headers: {'location': 'https://keys.example.org/alan'}))
      ..answer(Uri.parse('https://keys.example.org/alan'), 200, lookupAnswer(vksAlan));

    expect(await search('alan@example.org'), isA<LookupUnreachable>());
    expect(services.requests, [url]);
  });
}
