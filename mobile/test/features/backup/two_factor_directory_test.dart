import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/two_factor_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object?> data;
  late TwoFactorDirectory directory;

  setUpAll(() async {
    data = jsonDecode(await rootBundle.loadString(TwoFactorDirectory.asset)) as Map<String, Object?>;
    directory = await TwoFactorDirectory.load();
  });

  group('the bundled 2FA directory', () {
    test('carries the MIT licence of the data it was made from', () {
      expect(data['source'], 'https://2fa.directory');
      expect(data['license'], contains('The MIT License'));
      expect((data['entries']! as List<Object?>).length, greaterThan(1000));
      expect(directory.license, data['license']);
      expect(directory.entries, hasLength((data['entries']! as List<Object?>).length));
    });

    test('only links to https pages', () {
      for (final row in (data['entries']! as List<Object?>).cast<List<Object?>>()) {
        for (final url in [row[2], row[3]]) {
          if (url is String && url.isNotEmpty) expect(url, startsWith('https://'));
        }
      }
    });

    for (final name in ['GitHub', 'github.com', 'GitHub, Inc.', 'https://github.com/settings']) {
      test('finds GitHub from "$name", with its help and recovery pages', () {
        final entry = directory.findService(name);
        expect(entry?.name, 'GitHub');
        expect(entry?.domain, 'github.com');
        expect(entry?.docs, startsWith('https://docs.github.com/'));
        expect(entry?.recovery, startsWith('https://docs.github.com/'));
      });
    }

    test('has nothing for a name it does not know', () {
      expect(directory.findService('My Home Router 3000'), isNull);
      expect(directory.findService(''), isNull);
    });

    test('loads once and shares the result', () async {
      expect(await TwoFactorDirectory.load(), same(directory));
    });
  });

  group('TwoFactorDirectory.fromJson', () {
    final small = TwoFactorDirectory.fromJson({
      'source': 'https://2fa.directory',
      'license': 'MIT',
      'entries': [
        [
          'Example',
          'example.com',
          'https://example.com/2fa',
          0,
          ['Example Cloud'],
        ],
        ['Example Shop', 'shop.example.com', 0, ''],
      ],
    });

    test('reads a 0 or an empty string as no link', () {
      expect(small.findService('Example')?.recovery, isNull);
      expect(small.findService('Example Shop')?.docs, isNull);
      expect(small.findService('Example Shop')?.recovery, isNull);
    });

    test('finds a service by its other names', () {
      expect(small.findService('Example Cloud')?.name, 'Example');
    });

    test('files a key under the first service that has it', () {
      // shop.example.com's keys end in "example", which Example already has.
      expect(small.findService('example')?.name, 'Example');
      expect(small.findService('shop.example.com')?.name, 'Example Shop');
    });
  });
}
