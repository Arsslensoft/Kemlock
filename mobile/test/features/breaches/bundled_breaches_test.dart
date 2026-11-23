import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/service_names.dart';
import 'package:kemlock/features/backup/two_factor_directory.dart';
import 'package:kemlock/features/breaches/breach_list.dart';
import 'package:kemlock/features/breaches/breach_providers.dart';

/// Breaches that share a name with a different service of the 2FA directory, each looked
/// at by hand: `'<directory domain> <breach name>': why it stays`. A pair that isn't here
/// fails the test below, so a refresh of either file can't add one unseen.
const _knownCollisions = {
  'tangerine.ca Tangerine':
      'Tangerine the Canadian bank and Tangerine Telecom of Australia share the name; the alert shows the breached '
      'domain, tangerinetelecom.com.au, so the two can be told apart.',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object?> data;
  late BreachList list;

  setUpAll(() async {
    data = jsonDecode(await rootBundle.loadString(BreachList.asset)) as Map<String, Object?>;
    list = await loadBundledBreaches();
  });

  group('the bundled breach list', () {
    test('carries its source and the notice its licence asks for', () {
      expect(data['source'], 'https://haveibeenpwned.com');
      expect(data['updated'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(list.license, allOf(isNotEmpty, contains('Have I Been Pwned'), contains('Creative Commons Attribution 4.0')));
      expect(list.license, breachLicense);
    });

    test('holds several hundred breaches, every row readable', () {
      expect(list.entries.length, greaterThan(500));
      expect(list.entries, hasLength((data['entries']! as List<Object?>).length));
    });

    test('holds only breaches of a service with a domain', () {
      for (final breach in list.entries) {
        expect(breach.domain, matches(RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$')), reason: breach.name);
      }
    });

    test('leaves out the lists that belong to no one service', () {
      for (final name in ['AntiPublic', 'Collection1', 'ExploitIn', 'AlienStealerLogs', 'CastleRAT']) {
        expect(list.has(name), isFalse, reason: name);
      }
    });

    for (final name in ['Adobe', 'adobe.com', 'Adobe Inc.']) {
      test('finds the Adobe breach of 2013 from "$name"', () {
        final adobe = list.of(name).firstWhere((breach) => breach.name == 'Adobe');
        expect(adobe.breachDate, '2013-10-04');
        expect(adobe.passwords, isTrue);
      });
    }

    test('is the same list on a second load', () async {
      expect(await loadBundledBreaches(), same(list));
    });
  });

  test('no breach is found for a different service of the 2FA directory, but for the pairs looked at', () async {
    final directory = await TwoFactorDirectory.load();
    final collisions = <String>{};
    for (final service in directory.entries) {
      for (final breach in {...list.of(service.name), ...list.of(service.domain)}) {
        // Compared without the suffix, so adobe.com and adobe.co.uk are one service
        if (keysFor(breach.domain).last != keysFor(service.domain).last) collisions.add('${service.domain} ${breach.name}');
      }
    }

    expect(collisions.difference(_knownCollisions.keys.toSet()), isEmpty, reason: 'new collisions: look at each, then list it with why');
    expect(_knownCollisions.keys.toSet().difference(collisions), isEmpty, reason: 'pairs that no longer collide: remove them');
    for (final why in _knownCollisions.values) {
      expect(why, isNotEmpty);
    }
  });
}
