import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/keys/keys.dart' show maxKeyInputLength;
import 'package:kemlock/features/contacts/lookup/lookup_http.dart';
import 'package:kemlock/features/contacts/lookup/wkd.dart';
import 'package:kemlock/platform/network.dart';

import 'lookup_kit.dart';

LookupAddress _address(String text) => addressOf(text);

void main() {
  group('the addresses of a key', () {
    test('are those of the draft’s example, with the part before the @ kept in its case', () {
      final address = _address('Joe.Doe@Example.ORG');

      expect(wkdHash(address), 'iy9q119eutrkn8s1mk4r39qejnbu3n5q');
      expect(
        wkdAdvancedUri(address).toString(),
        'https://openpgpkey.example.org/.well-known/openpgpkey/example.org/hu/iy9q119eutrkn8s1mk4r39qejnbu3n5q?l=Joe.Doe',
      );
      expect(wkdDirectUri(address).toString(), 'https://example.org/.well-known/openpgpkey/hu/iy9q119eutrkn8s1mk4r39qejnbu3n5q?l=Joe.Doe');
    });

    test('percent-encode a + and a letter outside ASCII in l', () {
      expect(wkdAdvancedUri(_address('grace+keys@example.org')).query, 'l=grace%2Bkeys');
      expect(wkdDirectUri(_address('zoë@example.org')).query, 'l=zo%C3%AB');
    });

    test('hash the part before the @ with only its ASCII capitals made lower case', () {
      expect(wkdHash(_address('Joe.Doe@example.org')), wkdHash(_address('joe.doe@example.org')));
      expect(wkdHash(_address('ZOË@example.org')), isNot(wkdHash(_address('zoë@example.org'))));
    });
  });

  group('an address', () {
    test('is trimmed, and its domain made lower case', () {
      final address = _address(' Grace@Example.ORG ');

      expect((address.localPart, address.domain, address.address), ('Grace', 'example.org', 'Grace@example.org'));
      expect(wkdAdvancedUri(address).host, 'openpgpkey.example.org');
    });

    test('is refused, with its reason, for anything but one address', () {
      final cases = {
        '': AddressProblem.empty,
        '   ': AddressProblem.empty,
        'Grace Hopper': AddressProblem.noAt,
        'grace@hopper@example.org': AddressProblem.severalAt,
        '@example.org': AddressProblem.emptyLocalPart,
        'grace hopper@example.org': AddressProblem.badLocalPart,
        'grace@localhost': AddressProblem.noDot,
        'grace@exämple.org': AddressProblem.internationalDomain,
        'grace@example_org.org': AddressProblem.badDomain,
        'grace@example..org': AddressProblem.badDomain,
        'grace@example.org.': AddressProblem.badDomain,
        '${'g' * 243}@example.org': AddressProblem.tooLong,
      };
      for (final MapEntry(key: text, value: problem) in cases.entries) {
        final read = readLookupAddress(text);
        expect((read.address, read.problem), (null, problem), reason: text);
      }
    });

    test('of 254 characters is taken', () {
      final text = '${'g' * 242}@example.org';

      expect(text.length, 254);
      expect(readLookupAddress(text).problem, isNull);
    });
  });

  group('the directory search', () {
    late FakeKeyServices services;
    final grace = addressOf('grace@example.org');
    final advanced = wkdAdvancedUri(grace);
    final direct = wkdDirectUri(grace);

    setUp(() => services = FakeKeyServices());

    Future<LookupOutcome> search() => searchWkd(grace, client: services.client, resolve: services.resolve);

    test('asks only the directory host when it resolves and answers', () async {
      services.directory('grace@example.org', [1, 2, 3]);

      final outcome = await search();

      expect(outcome, isA<LookupAnswered>().having((a) => a.bytes, 'bytes', [1, 2, 3]));
      expect(services.requests, [advanced]);
      expect(services.resolved, ['openpgpkey.example.org']);
    });

    test('does not fall back to the direct method when the directory host has no key', () async {
      services
        ..emptyDirectory('grace@example.org')
        ..hosts.add('example.org')
        ..answer(direct, 200, [9]);

      expect(await search(), isA<LookupNoKey>());
      expect(services.requests, [advanced]);
    });

    test('uses the direct method when the directory host does not exist', () async {
      services.directory('grace@example.org', [4, 5], advanced: false);

      final outcome = await search();

      expect(outcome, isA<LookupAnswered>().having((a) => a.bytes, 'bytes', [4, 5]));
      expect(services.resolved, ['openpgpkey.example.org', 'example.org']);
      expect(services.requests, [direct]);
    });

    test('could not reach the domain when neither host resolves, as on a phone with no connection', () async {
      expect(await search(), isA<LookupUnreachable>());
      expect(services.requests, isEmpty);
    });

    test('could not reach the domain when the directory host resolves and the connection fails, and asks no other', () async {
      services
        ..emptyDirectory('grace@example.org')
        ..unreachable.add('openpgpkey.example.org')
        ..directory('grace@example.org', [9], advanced: false);

      expect(await search(), isA<LookupUnreachable>());
      expect(services.requests, [advanced]);
    });

    test('takes a server error for no key', () async {
      services
        ..emptyDirectory('grace@example.org')
        ..answer(advanced, 500);

      expect(await search(), isA<LookupNoKey>());
    });

    test('fetches the key from where the domain redirects it on https, and nothing from an http address', () async {
      void redirectTo(String location) =>
          services.answers['${advanced.host}${advanced.path}'] = (_) async => http.Response('', 301, headers: {'location': location});
      services
        ..emptyDirectory('grace@example.org')
        ..answer(Uri.parse('https://www.example.org/key'), 200, [7]);
      redirectTo('https://www.example.org/key');

      expect(await search(), isA<LookupAnswered>().having((a) => a.bytes, 'bytes', [7]));
      expect(services.requests, [advanced, Uri.parse('https://www.example.org/key')]);

      redirectTo('http://www.example.org/key');
      services.requests.clear();

      expect(await search(), isA<LookupNoKey>());
      expect(services.requests, [advanced]);
    });

    test('takes an answer too large to be a key for no key', () async {
      services.directory('grace@example.org', List.filled(maxKeyInputLength + 1, 0));

      expect(await search(), isA<LookupNoKey>());
    });

    test('is paused, and resolves nothing, while offline mode is on', () async {
      final outcome = await searchWkd(grace, client: services.client, resolve: (_) async => throw OfflineException());

      expect(outcome, isA<LookupPaused>());
      expect(services.requests, isEmpty);
    });
  });
}
