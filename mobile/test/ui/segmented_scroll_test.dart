import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

// A segmented control of many options on a phone's width: each takes what its label needs, the row scrolls, and every option can be picked
void main() {
  Future<List<VaultFilter>> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(390, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picked = <VaultFilter>[];
    await pumpOnPage(
      tester,
      Builder(
        builder: (context) => SegmentedControl<VaultFilter>(
          options: [for (final filter in VaultFilter.values) SegmentOption(value: filter, label: context.t(filter.labelId))],
          value: VaultFilter.all,
          onChanged: picked.add,
          semanticLabel: 'Filter',
          size: SegmentSize.small,
          scrollable: true,
        ),
      ),
      center: false,
    );
    return picked;
  }

  testWidgets('the options that do not fit scroll, none truncated, and a far one can be picked', (tester) async {
    final picked = await pump(tester);

    expect(tester.takeException(), isNull);
    // The row is wider than the screen, so it scrolls
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    for (final filter in VaultFilter.values) {
      expect(find.text(t(filter.labelId)), findsOneWidget, reason: filter.name);
    }

    await tester.ensureVisible(find.text(t(VaultFilter.values.last.labelId)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t(VaultFilter.values.last.labelId)));

    expect(picked, [VaultFilter.values.last]);
  });
}
