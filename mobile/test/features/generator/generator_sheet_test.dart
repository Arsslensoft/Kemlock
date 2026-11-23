import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/generator/generator_sheet.dart';
import 'package:kemlock/features/generator/word_list.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';

void main() {
  final words = parseWordList(File(effWordListAsset).readAsStringSync());

  /// A page with a button that opens the generator; what it gave back is in [results].
  Future<List<String?>> open(WidgetTester tester, KeyValueStore store) async {
    final results = <String?>[];
    await pumpScreen(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) =>
              FilledButton(onPressed: () async => results.add(await showGeneratorSheet(context)), child: const Text('open')),
        ),
      ),
      store: store,
      overrides: [wordListProvider.overrideWith((ref) => words)],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  String shown(WidgetTester tester) => tester
      .widgetList<Semantics>(find.descendant(of: find.byType(GeneratorSheet), matching: find.byType(Semantics)))
      .map((s) => s.properties.label)
      .whereType<String>()
      .firstWhere((label) => label.length >= 8 && !label.contains(' '));

  testWidgets('gives back the password shown when it is used', (tester) async {
    final store = KeyValueStore.memory();
    final results = await open(tester, store);
    final password = shown(tester);
    expect(password, hasLength(20));

    await tester.ensureVisible(find.text(t('generator.use')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('generator.use')));
    await tester.pumpAndSettle();
    expect(results, [password]);
  });

  testWidgets('remembers its choices on the phone', (tester) async {
    final store = KeyValueStore.memory();
    await open(tester, store);
    // The switches in order: capitals, digits, symbols, look-alikes
    final digits = find.descendant(of: find.byType(GeneratorSheet), matching: find.byType(AppSwitch)).at(1);
    await tester.ensureVisible(digits);
    await tester.pumpAndSettle();
    await tester.tap(digits);
    await tester.pumpAndSettle();
    expect(shown(tester), isNot(contains(RegExp('[0-9]'))));

    final stored = jsonDecode(store.getItem(keyGenerator)!) as Map<String, Object?>;
    expect((stored['random']! as Map<String, Object?>)['digits'], isFalse);
  });

  testWidgets('makes a passphrase from the word list', (tester) async {
    final store = KeyValueStore.memory();
    await open(tester, store);
    await tester.tap(find.text(t('generator.kind.passphrase')));
    await tester.pumpAndSettle();

    final phrase = tester
        .widgetList<Semantics>(find.descendant(of: find.byType(GeneratorSheet), matching: find.byType(Semantics)))
        .map((s) => s.properties.label)
        .whereType<String>()
        .firstWhere((label) => label.split('-').length == 5);
    expect(phrase.split('-').every(words.contains), isTrue);
    expect(find.descendant(of: find.byType(SegmentedControl<String>), matching: find.text(t('generator.separator.dash'))), findsOneWidget);
  });
}
