import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/fields/custom_fields_provider.dart';
import 'package:kemlock/features/fields/custom_fields_view.dart';
import 'package:kemlock/features/lock/gate_widgets.dart';
import 'package:kemlock/features/sync/kemlock/km_custom_fields.dart';
import 'package:kemlock/models/custom_field.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_clipboard.dart';
import '../../helpers/test_app.dart';

const _dots = '••••••••••';

Future<void> _pump(
  WidgetTester tester,
  List<CustomField> fields, {
  KmCustomFields definitions = KmCustomFields.none,
  FakeSensitiveClipboard? clipboard,
}) async {
  tester.view
    ..physicalSize = const Size(900, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpOnPage(
    tester,
    SingleChildScrollView(child: CustomFieldsView(fields: fields)),
    center: false,
    overrides: [kmCustomFieldsProvider.overrideWith((ref) async => definitions), ?clipboard?.asOverride],
  );
  // The definitions arrive after the first frame
  await tester.pump();
}

void main() {
  const text = CustomField(name: 'Employee ID', value: 'E-42', kind: CustomFieldKind.text);
  const hidden = CustomField(name: 'Locker code', value: '1234', kind: CustomFieldKind.hidden);
  const ticked = CustomField(name: 'Reviewed', value: 'true', kind: CustomFieldKind.boolean);
  const unticked = CustomField(name: 'Approved', value: 'false', kind: CustomFieldKind.boolean);

  testWidgets('shows each field\'s name and value', (tester) async {
    await _pump(tester, [text]);

    expect(find.text(t('fields.title').toUpperCase()), findsOneWidget);
    expect(find.text('Employee ID'), findsOneWidget);
    expect(find.text('E-42'), findsOneWidget);
  });

  testWidgets('a hidden value is masked until the eye shows it', (tester) async {
    await _pump(tester, [hidden]);

    expect(find.text('Locker code'), findsOneWidget);
    expect(find.text(_dots), findsOneWidget);
    expect(find.text('1234'), findsNothing);

    await tester.tap(find.byType(RevealPasswordButton));
    await tester.pump();
    expect(find.text('1234'), findsOneWidget);
    expect(find.text(_dots), findsNothing);

    await tester.tap(find.byType(RevealPasswordButton));
    await tester.pump();
    expect(find.text('1234'), findsNothing);
    expect(find.text(_dots), findsOneWidget);
  });

  testWidgets('a checkbox reads yes or no, and a ticked one is never left out', (tester) async {
    await _pump(tester, [ticked, unticked]);

    expect(find.text(t('fields.yes')), findsOneWidget);
    expect(find.text(t('fields.no')), findsOneWidget);
  });

  testWidgets('an empty value says nothing, and an entry nobody can edit is not shown', (tester) async {
    final fields = readFields([
      {'name': 'Empty', 'value': '', 'kind': 'text'},
      {'name': 'Linked', 'value': 2, 'kind': 3},
      {'name': '', 'value': 'nameless', 'kind': 'text'},
      {'name': 'Kept', 'value': 'here', 'kind': 'text'},
    ]);
    await _pump(tester, fields);

    expect(find.text('Empty'), findsNothing);
    expect(find.text('Linked'), findsNothing);
    expect(find.text('nameless'), findsNothing);
    expect(find.text('Kept'), findsOneWidget);
  });

  testWidgets('with nothing to show, it takes no room', (tester) async {
    await _pump(tester, const []);
    expect(find.byType(Group), findsNothing);
    expect(find.text(t('fields.title').toUpperCase()), findsNothing);

    await _pump(tester, readFields([{'name': 'Empty', 'value': '', 'kind': 'text'}]));
    expect(find.byType(Group), findsNothing);
  });

  testWidgets('every value copies through the sensitive clipboard', (tester) async {
    final clipboard = FakeSensitiveClipboard();
    await _pump(tester, [text, hidden, ticked], clipboard: clipboard);

    await tester.tap(find.byKey(const ValueKey('field-copy-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('field-copy-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('field-copy-2')));
    await tester.pump();

    // A hidden value copies whole, masked or not
    expect([for (final copy in clipboard.copies) copy.text], ['E-42', '1234', t('fields.yes')]);
    // Let the toasts go
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('an admin\'s field carries the Admin tag and the name the admin has for it now', (tester) async {
    const held = CustomField(name: 'Cost centre', value: 'CC-7', kind: CustomFieldKind.text, adminField: 'd1');
    await _pump(
      tester,
      [held, text],
      definitions: const KmCustomFields(
        fields: [KmFieldDefinition(id: 'd1', name: 'Cost center', kind: CustomFieldKind.text)],
      ),
    );

    expect(find.text('Cost center'), findsOneWidget);
    expect(find.text('Cost centre'), findsNothing);
    expect(find.text('CC-7'), findsOneWidget);
    expect(find.text(t('fields.admin').toUpperCase()), findsOneWidget);
  });

  testWidgets('a field whose definition is gone shows as it was saved, without the tag', (tester) async {
    const held = CustomField(name: 'Old rule', value: 'x', kind: CustomFieldKind.text, adminField: 'gone');
    await _pump(tester, [held]);

    expect(find.text('Old rule'), findsOneWidget);
    expect(find.text(t('fields.admin').toUpperCase()), findsNothing);
  });
}
