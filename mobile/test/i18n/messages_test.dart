import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/i18n/icu.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';

/// Every message id the app's code names: `context.t('x.y')`,
/// `messages.t('x.y')`, `id: 'x.y'`, `titleId: 'x.y'`, `bodyId: ...`.
final _messageId = RegExp(r'''\b(?:t\(|(?:id|[a-z]+Id)\s*:)\s*['"]([a-zA-Z]+(?:\.[a-zA-Z0-9]+)+)['"]''');

final _sources = [
  for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
    if (file.path.endsWith('.dart')) file.readAsStringSync(),
];

final _referencedIds = {for (final source in _sources) ..._messageId.allMatches(source).map((match) => match[1]!)};

/// The ids of the space screens that the scanner above misses, because a helper takes them (`_title(context, 'space.keys.title')`):
/// every literal shaped like a message id of the space, spaces and accept namespaces.
final _spaceLiteral = RegExp(r'''['"]((?:space|spaces|accept)\.[a-zA-Z0-9]+(?:\.[a-zA-Z0-9]+)*)['"]''');

final _spaceIds = {for (final source in _sources) ..._spaceLiteral.allMatches(source).map((match) => match[1]!)};

/// Fails the test on a missing or malformed message instead of showing the raw id.
Never _throwOnError(MessageError error) => throw error;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessageCatalog catalog;

  setUpAll(() async => catalog = await MessageCatalog.load(onError: _throwOnError));

  group('translations', () {
    test('recognises every way the code names a message (guards the scanner itself)', () {
      const sample = '''
        Text(context.t('a.call'))
        messages.t("b.call", {'count': 2})
        (titleId: 'c.data', bodyId: "d.data")
        Notice(id: 'e.named')
        context.t(
          'f.wrapped',
        )''';

      expect(_messageId.allMatches(sample).map((match) => match[1]), ['a.call', 'b.call', 'c.data', 'd.data', 'e.named', 'f.wrapped']);
      // The screens come later; until then, at least make sure it reads the code.
      expect(_sources, isNotEmpty);
    });

    for (final locale in AppLocale.values) {
      test('${locale.name} defines every message id the code uses', () {
        final messages = catalog.of(locale);
        expect([
          for (final id in _referencedIds)
            if (messages.pattern(id) == null) id,
        ], isEmpty);
      });
    }

    for (final locale in AppLocale.values) {
      test('${locale.name} defines the space ids that a helper takes, and the ones the scanner reads', () {
        final messages = catalog.of(locale);
        expect(_spaceIds, isNotEmpty);
        expect([
          for (final id in _spaceIds)
            if (messages.pattern(id) == null) id,
        ], isEmpty);
      });
    }

    test('every locale has the same keys as English', () {
      final english = catalog.of(AppLocale.en).ids.toList()..sort();
      for (final locale in AppLocale.values) {
        expect(catalog.of(locale).ids.toList()..sort(), english, reason: locale.name);
      }
    });

    for (final locale in AppLocale.values) {
      test('${locale.name} messages are non-empty valid ICU', () {
        final messages = catalog.of(locale);
        for (final id in messages.ids) {
          final pattern = messages.pattern(id)!;
          expect(pattern.trim(), isNot(''), reason: id);
          expect(() => IcuMessage.parse(pattern), returnsNormally, reason: id);
        }
      });
    }

    test('translations use the same placeholders as English', () {
      final english = catalog.of(AppLocale.en);
      for (final id in english.ids) {
        final expected = IcuMessage.parse(english.pattern(id)!).argumentNames;
        for (final locale in AppLocale.values) {
          expect(IcuMessage.parse(catalog.of(locale).pattern(id)!).argumentNames, expected, reason: '${locale.name}: $id');
        }
      }
    });

    for (final locale in AppLocale.values) {
      test('every ${locale.name} message formats with its arguments', () {
        final messages = catalog.of(locale);
        for (final id in messages.ids) {
          final args = {for (final name in IcuMessage.parse(messages.pattern(id)!).argumentNames) name: 2};
          expect(() => messages.t(id, args), returnsNormally, reason: id);
        }
      });
    }

    test('ships the messages react-intl shows, both files byte for byte', () async {
      // tool/fixtures/i18n_messages.mjs refuses to run unless the copies match src/i18n.
      for (final locale in AppLocale.values) {
        final asset = await rootBundle.load('assets/i18n/${locale.name}.json');
        final file = File('assets/i18n/${locale.name}.json').readAsBytesSync();
        expect(asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes), file);
      }
      expect(catalog.of(AppLocale.fr).t('addBackup.save', {'count': 1000}), 'Enregistrer 1 000 codes');
    });
  });

  group('plurals come out as in react-intl', () {
    final fixture = jsonDecode(File('test/fixtures/i18n/plurals.json').readAsStringSync()) as Map<String, Object?>;

    for (final locale in AppLocale.values) {
      final byId = fixture[locale.name]! as Map<String, Object?>;

      test('${locale.name}: every message with a plural is in the fixture', () {
        final withPlural = [
          for (final id in catalog.of(locale).ids)
            if (catalog.of(locale).pattern(id)!.contains(RegExp(r',\s*plural\s*,'))) id,
        ];
        expect(byId.keys, unorderedEquals(withPlural));
      });

      test('${locale.name}: each message at every count', () {
        final messages = catalog.of(locale);
        var cases = 0;
        for (final MapEntry(key: id, value: examples) in byId.entries) {
          for (final example in examples! as List<Object?>) {
            final [values as Map<String, Object?>, text as String] = example! as List<Object?>;
            expect(messages.t(id, values), text, reason: '$id with $values');
            cases++;
          }
        }
        expect(cases, greaterThan(500));
      });
    }
  });

  group('falls back as react-intl does', () {
    final fixture = jsonDecode(File('test/fixtures/i18n/syntax.json').readAsStringSync()) as Map<String, Object?>;

    for (final entry in fixture['fallbacks']! as List<Object?>) {
      final example = entry! as Map<String, Object?>;
      final locale = AppLocale.fromCode(example['locale'] as String?)!;
      final id = example['id']! as String;

      test('${locale.name}: ${example['messages']} → $id', () {
        final errors = <MessageError>[];
        final messages = Messages(locale, (example['messages']! as Map<String, Object?>).cast<String, String>(), onError: errors.add);

        expect(messages.t(id, (example['values'] as Map<String, Object?>?) ?? const {}), example['text']);
        // Only a message that formats goes unreported.
        expect(errors.length, example['text'] == id || example['text'] == messages.pattern(id) ? 1 : 0);
      });
    }

    test('reports the id and locale of the message at fault', () {
      final errors = <MessageError>[];
      final messages = Messages(AppLocale.fr, const {'a.b': 'Bonjour {name}'}, onError: errors.add);

      expect(messages.t('a.b'), 'Bonjour {name}');
      expect(messages.t('nope'), 'nope');
      expect(
        [for (final error in errors) (error.id, error.locale, error.cause.runtimeType)],
        [('a.b', AppLocale.fr, IcuFormatError), ('nope', AppLocale.fr, Null)],
      );
    });

    test("doesn't fall back to English for a message French lacks", () {
      final catalog = MessageCatalog({
        AppLocale.en: const {'only.en': 'Hello'},
        AppLocale.fr: const {},
      }, onError: (_) {});

      expect(catalog.of(AppLocale.fr).t('only.en'), 'only.en');
    });
  });

  group('the language', () {
    ProviderContainer containerWith(KeyValueStore store) {
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store), messageCatalogProvider.overrideWithValue(catalog)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('is English until another is picked', () {
      final container = containerWith(KeyValueStore.memory());

      expect(container.read(localeProvider), AppLocale.en);
      expect(container.read(messagesProvider).locale, AppLocale.en);
    });

    test('reads the language stored as backmycodes_locale, and English for one the app lacks', () {
      expect(containerWith(KeyValueStore.memory({'backmycodes_locale': 'fr'})).read(localeProvider), AppLocale.fr);
      expect(containerWith(KeyValueStore.memory({'backmycodes_locale': 'de'})).read(localeProvider), AppLocale.en);
    });

    test('stores the language picked, and the copy follows', () {
      final store = KeyValueStore.memory();
      final container = containerWith(store);
      final seen = <AppLocale>[];
      container.listen(localeProvider, (_, next) => seen.add(next), fireImmediately: true);

      container.read(localeProvider.notifier).setLocale(AppLocale.fr);

      expect(store.getItem('backmycodes_locale'), 'fr');
      expect(container.read(localeProvider), AppLocale.fr);
      expect(seen, [AppLocale.en, AppLocale.fr]);
      expect(container.read(messagesProvider).t('settings.autoLock.option', {'minutes': 0}), '0 minute');
    });

    test('belongs to the device, not to a vault', () async {
      final store = KeyValueStore.memory({'backmycodes_locale': 'fr'});
      final container = containerWith(store);
      container.read(vaultRegistryProvider).active = 'work';
      await pumpEventQueue();

      expect(container.read(localeProvider), AppLocale.fr);
      container.read(localeProvider.notifier).setLocale(AppLocale.en);
      expect(store.storedKeys(), [keyLocale]);
    });

    test('lists the languages by their own names', () {
      expect([for (final locale in AppLocale.values) (locale.name, locale.label)], [('en', 'English'), ('fr', 'Français')]);
      expect(supportedLocales, const [Locale('en'), Locale('fr')]);
    });
  });

  group('widgets', () {
    Widget app(AppLocale locale) => MaterialApp(
      locale: locale.locale,
      supportedLocales: supportedLocales,
      localizationsDelegates: localizationsDelegates(catalog),
      home: Builder(
        builder: (context) => Column(
          children: [
            Text(context.t('settings.autoLock.option', {'minutes': 15})),
            Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ],
        ),
      ),
    );

    testWidgets('read the copy from their context, in the language picked', (tester) async {
      await tester.pumpWidget(app(AppLocale.en));
      expect(find.text('15 minutes'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.pumpWidget(app(AppLocale.fr));
      await tester.pump();
      expect(find.text('Annuler'), findsOneWidget);
      expect(tester.element(find.byType(Column)).messages.locale, AppLocale.fr);
    });

    testWidgets('say what is missing when the app has no copy', (tester) async {
      await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: SizedBox()));

      expect(() => tester.element(find.byType(SizedBox)).t('a.b'), throwsFlutterError);
    });
  });
}
