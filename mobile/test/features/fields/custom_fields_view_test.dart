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
  bool hideSecrets = false,
}) async {
  tester.view
    ..physicalSize = const Size(900, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpOnPage(
    tester,
    SingleChildScrollView(
      child: CustomFieldsView(fields: fields, hideSecrets: hideSecrets),
    ),
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

    await _pump(
      tester,
      readFields([
        {'name': 'Empty', 'value': '', 'kind': 'text'},
      ]),
    );
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
    // Let the toasts go, and the clipboard clear after its 30 s
    await tester.pump(const Duration(seconds: 31));
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

  testWidgets('the admin changing a definition\'s type does not change how a saved value reads', (tester) async {
    const asText = CustomField(name: 'Badge', value: 'B-9', kind: CustomFieldKind.text, adminField: 'd1');
    const asHidden = CustomField(name: 'Pin', value: '4321', kind: CustomFieldKind.hidden, adminField: 'd2');
    await _pump(
      tester,
      [asText, asHidden],
      definitions: const KmCustomFields(
        fields: [
          KmFieldDefinition(id: 'd1', name: 'Badge', kind: CustomFieldKind.boolean),
          KmFieldDefinition(id: 'd2', name: 'Pin', kind: CustomFieldKind.text),
        ],
      ),
    );

    // The text is still the text, not read as a checkbox
    expect(find.text('B-9'), findsOneWidget);
    expect(find.text(t('fields.no')), findsNothing);
    // The hidden value stays masked, whatever the definition says now
    expect(find.text('4321'), findsNothing);
    expect(find.text(_dots), findsOneWidget);
    expect(find.text(t('fields.admin').toUpperCase()), findsNWidgets(2));
  });

  testWidgets('a value shown stays masked when the list changes and its place names another field', (tester) async {
    tester.view
      ..physicalSize = const Size(900, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const other = CustomField(name: 'Alarm code', value: '5678', kind: CustomFieldKind.hidden);
    final fields = ValueNotifier<List<CustomField>>([hidden, other]);
    addTearDown(fields.dispose);
    await pumpOnPage(
      tester,
      SingleChildScrollView(
        child: ValueListenableBuilder<List<CustomField>>(
          valueListenable: fields,
          builder: (context, list, _) => CustomFieldsView(fields: list),
        ),
      ),
      center: false,
      overrides: [kmCustomFieldsProvider.overrideWith((ref) async => KmCustomFields.none)],
    );
    await tester.pump();

    await tester.tap(find.byType(RevealPasswordButton).first);
    await tester.pump();
    expect(find.text('1234'), findsOneWidget);

    // The first field is removed: what was second is first now, and was never shown
    fields.value = [other];
    await tester.pump();

    expect(find.text('5678'), findsNothing);
    expect(find.text(_dots), findsOneWidget);
  });

  testWidgets('a grant that hides passwords hides the hidden fields: masked, with no Show and no Copy', (tester) async {
    await _pump(tester, [text, hidden], hideSecrets: true);

    expect(find.text('E-42'), findsOneWidget);
    expect(find.byKey(const ValueKey('field-copy-0')), findsOneWidget);
    expect(find.text('Locker code'), findsOneWidget);
    expect(find.text(_dots), findsOneWidget);
    expect(find.text('1234'), findsNothing);
    expect(find.byType(RevealPasswordButton), findsNothing);
    expect(find.byKey(const ValueKey('field-copy-1')), findsNothing);
  });
}
