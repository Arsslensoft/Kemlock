import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/fields/custom_fields_editor.dart';
import 'package:kemlock/features/fields/custom_fields_provider.dart';
import 'package:kemlock/features/lock/gate_widgets.dart';
import 'package:kemlock/features/sync/kemlock/km_custom_fields.dart';
import 'package:kemlock/features/sync/kemlock/km_kinds.dart';
import 'package:kemlock/models/custom_field.dart';

import '../../helpers/test_app.dart';

/// Holds the fields as an edit sheet does, and records every list the editor gives it.
class _Harness extends StatefulWidget {
  const _Harness({required this.kind, required this.initial, required this.changes});

  final String kind;
  final List<CustomField> initial;
  final List<List<CustomField>> changes;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<CustomField> fields = widget.initial;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: CustomFieldsEditor(
      kind: widget.kind,
      fields: fields,
      onChanged: (next) {
        widget.changes.add(next);
        setState(() => fields = next);
      },
    ),
  );
}

KmFieldDefinition _definition(String id, String name, String kind, [List<String>? kinds]) =>
    KmFieldDefinition(id: id, name: name, kind: kind, kinds: kinds);

Future<List<List<CustomField>>> _pump(
  WidgetTester tester, {
  String kind = KmKind.login,
  List<CustomField> initial = const [],
  KmCustomFields definitions = KmCustomFields.none,
  List<Override> overrides = const [],
}) async {
  tester.view
    ..physicalSize = const Size(900, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final changes = <List<CustomField>>[];
  await pumpOnPage(
    tester,
    _Harness(kind: kind, initial: initial, changes: changes),
    center: false,
    overrides: [kmCustomFieldsProvider.overrideWith((ref) async => definitions), ...overrides],
  );
  // The definitions arrive after the first frame
  await tester.pump();
  return changes;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('fields-add')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

TextField _textField(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(ValueKey(key)));

void main() {
  group('what is already on the item', () {
    // A text field with a key of its own, a linked field and a nameless one the editor can't edit, a checkbox the
    // importer wrote as a boolean, and an admin's field.
    final source = <Object?>[
      {'name': 'Employee ID', 'value': 'E-42', 'kind': 'text', 'extra': 'kept', 'adminField': 'a1'},
      {'name': 'Linked', 'value': 2, 'kind': 3},
      {'name': '', 'value': 'nameless', 'kind': 'text'},
      {'name': 'Recovery', 'value': 'secret', 'type': 1},
      {'name': 'Reviewed', 'value': true, 'kind': 'boolean'},
    ];

    test('every untouched entry writes back exactly as it was read', () {
      expect(writeFields(readFields(source)), source);
    });

    testWidgets('an edit changes one field and leaves every other entry the very same object', (tester) async {
      final fields = readFields(source);
      final changes = await _pump(
        tester,
        initial: fields,
        definitions: KmCustomFields(fields: [_definition('a1', 'Employee ID', CustomFieldKind.text)]),
      );

      // Nothing was edited, so nothing was written
      expect(changes, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('field-value-3')), 'changed');
      await tester.pump();

      final next = changes.last;
      expect(next, hasLength(fields.length));
      for (final i in [0, 1, 2, 4]) {
        expect(identical(next[i], fields[i]), isTrue, reason: 'entry $i is the same object');
      }
      expect(next[3].value, 'changed');
      expect(writeFields(next), [
        source[0],
        source[1],
        source[2],
        {'name': 'Recovery', 'value': 'changed', 'type': 1},
        source[4],
      ]);
    });

    testWidgets('an entry the editor can not edit is not shown, and stays where it was when another is removed', (tester) async {
      final fields = readFields(source);
      final changes = await _pump(tester, initial: fields);

      expect(find.text('Linked'), findsNothing);
      expect(find.text('nameless'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('field-remove-0')));
      await tester.pump();

      final next = changes.last;
      expect(next, hasLength(fields.length - 1));
      expect(identical(next[0], fields[1]), isTrue);
      expect(identical(next[1], fields[2]), isTrue);
      expect(writeFields(next), [source[1], source[2], source[3], source[4]]);
    });

    testWidgets('moving a field swaps it with the next one the person can edit', (tester) async {
      final fields = readFields(source);
      final changes = await _pump(tester, initial: fields);

      await tester.tap(find.byKey(const ValueKey('field-move-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(t('fields.moveDown')));
      await tester.pump();

      final next = changes.last;
      // Employee ID (0) and Recovery (3) trade places; the linked and nameless entries between them stay at 1 and 2
      expect(identical(next[0], fields[3]), isTrue);
      expect(identical(next[3], fields[0]), isTrue);
      expect(identical(next[1], fields[1]), isTrue);
      expect(identical(next[2], fields[2]), isTrue);
      expect(identical(next[4], fields[4]), isTrue);
    });
  });

  group('the admin\'s fields', () {
    final everywhere = _definition('d-all', 'Employee ID', CustomFieldKind.text);
    final loginsAndCards = _definition('d-lc', 'Cost center', CustomFieldKind.hidden, [KmKind.login, KmKind.card]);
    final notesOnly = _definition('d-note', 'Case number', CustomFieldKind.text, [KmKind.note]);
    final definitions = KmCustomFields(fields: [everywhere, loginsAndCards, notesOnly]);

    testWidgets('a login is offered the fields that name logins, or every kind, and nothing else', (tester) async {
      await _pump(tester, kind: KmKind.login, definitions: definitions);
      await _openMenu(tester);

      expect(find.text(t('fields.fromAdmin')), findsOneWidget);
      expect(find.text('Employee ID · ${t('fields.kind.text')}'), findsOneWidget);
      expect(find.text('Cost center · ${t('fields.kind.hidden')}'), findsOneWidget);
      expect(find.text('Case number · ${t('fields.kind.text')}'), findsNothing);
      expect(find.text(t('fields.own')), findsOneWidget);
    });

    testWidgets('a note is offered its own field and the one for every kind', (tester) async {
      await _pump(tester, kind: KmKind.note, definitions: definitions);
      await _openMenu(tester);

      expect(find.text('Employee ID · ${t('fields.kind.text')}'), findsOneWidget);
      expect(find.text('Case number · ${t('fields.kind.text')}'), findsOneWidget);
      expect(find.text('Cost center · ${t('fields.kind.hidden')}'), findsNothing);
    });

    testWidgets('a field picked has the admin\'s name and kind, and the person fills in the value', (tester) async {
      final changes = await _pump(tester, kind: KmKind.login, definitions: definitions);
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('fields-offer-d-lc')));
      await tester.pump();

      // The name is fixed: there is no name field, and the kind can't be picked
      expect(find.byKey(const ValueKey('field-name-0')), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text(t('fields.admin').toUpperCase()), findsOneWidget);
      expect(changes.last.single.adminField, 'd-lc');
      expect(changes.last.single.kind, CustomFieldKind.hidden);

      await tester.enterText(find.byKey(const ValueKey('field-value-0')), 'CC-7');
      await tester.pump();

      expect(writeFields(changes.last), [
        {'name': 'Cost center', 'value': 'CC-7', 'kind': 'hidden', 'adminField': 'd-lc'},
      ]);

      // It is on the item now, so it is no longer offered
      await _openMenu(tester);
      expect(find.byKey(const ValueKey('fields-offer-d-lc')), findsNothing);
      expect(find.byKey(const ValueKey('fields-offer-d-all')), findsOneWidget);
    });

    testWidgets('a field whose definition is gone shows as the person\'s own', (tester) async {
      final held = [
        const CustomField(name: 'Old rule', value: 'x', kind: CustomFieldKind.text, adminField: 'gone'),
        CustomField(name: everywhere.name, value: 'E-1', kind: CustomFieldKind.text, adminField: everywhere.id),
      ];
      await _pump(tester, initial: held, definitions: definitions);

      // The first can be renamed and retyped, the second can not
      expect(find.byKey(const ValueKey('field-name-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('field-kind-0-hidden')), findsOneWidget);
      expect(find.byKey(const ValueKey('field-name-1')), findsNothing);
      expect(find.byKey(const ValueKey('field-kind-1-hidden')), findsNothing);
    });
  });

  group('the person\'s own fields', () {
    testWidgets('can be added, named and written', (tester) async {
      final changes = await _pump(tester);
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('fields-own')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('field-name-0')), '  Locker  ');
      await tester.enterText(find.byKey(const ValueKey('field-value-0')), '1234');
      await tester.pump();

      expect(writeFields(changes.last), [
        {'name': 'Locker', 'value': '1234', 'kind': 'text'},
      ]);
    });

    testWidgets('one with no name is left out, and nothing is required', (tester) async {
      final changes = await _pump(tester);
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('fields-own')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('field-value-0')), 'orphan');
      await tester.pump();

      expect(changes.last, hasLength(1));
      expect(writeFields(changes.last), isNull);
    });

    testWidgets('are not offered when the admin turned them off, but the ones the item holds stay', (tester) async {
      final held = [const CustomField(name: 'Locker', value: '1234', kind: CustomFieldKind.text)];
      await _pump(
        tester,
        initial: held,
        definitions: KmCustomFields(
          fields: [_definition('d-all', 'Employee ID', CustomFieldKind.text)],
          allowOwn: false,
        ),
      );

      expect(find.byKey(const ValueKey('field-name-0')), findsOneWidget);
      expect(find.text(t('fields.adminOnly')), findsOneWidget);

      await _openMenu(tester);

      expect(find.byKey(const ValueKey('fields-offer-d-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('fields-own')), findsNothing);
    });

    testWidgets('with nothing to offer and no own fields allowed, there is no Add a field', (tester) async {
      await _pump(tester, definitions: const KmCustomFields(allowOwn: false));

      expect(find.byKey(const ValueKey('fields-add')), findsNothing);
      expect(find.text(t('fields.adminOnly')), findsOneWidget);
    });

    testWidgets('are offered when no admin fields were ever read', (tester) async {
      await _pump(tester);
      await _openMenu(tester);

      expect(find.text(t('fields.fromAdmin')), findsNothing);
      expect(find.byKey(const ValueKey('fields-own')), findsOneWidget);
    });
  });

  group('the value control follows the kind', () {
    testWidgets('a hidden value is masked until the eye shows it', (tester) async {
      final changes = await _pump(
        tester,
        initial: const [CustomField(name: 'PIN', value: '9876', kind: CustomFieldKind.hidden)],
      );

      expect(_textField(tester, 'field-value-0').obscureText, isTrue);
      expect(find.byType(RevealPasswordButton), findsOneWidget);

      await tester.tap(find.byType(RevealPasswordButton));
      await tester.pump();
      expect(_textField(tester, 'field-value-0').obscureText, isFalse);

      await tester.tap(find.byType(RevealPasswordButton));
      await tester.pump();
      expect(_textField(tester, 'field-value-0').obscureText, isTrue);
      // Showing it changed nothing
      expect(changes, isEmpty);
    });

    testWidgets('a checkbox holds "true" or "false"', (tester) async {
      final changes = await _pump(
        tester,
        initial: const [CustomField(name: 'Reviewed', value: 'false', kind: CustomFieldKind.boolean)],
      );

      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('field-tick-0'))).value, isFalse);

      await tester.tap(find.byKey(const ValueKey('field-tick-0')));
      await tester.pump();

      expect(changes.last.single.value, 'true');
      expect(writeFields(changes.last), [
        {'name': 'Reviewed', 'value': 'true', 'kind': 'boolean'},
      ]);

      await tester.tap(find.byKey(const ValueKey('field-tick-0')));
      await tester.pump();

      expect(changes.last.single.value, 'false');
    });

    testWidgets('a new kind for a field of one\'s own resets what the value could not mean', (tester) async {
      final changes = await _pump(
        tester,
        initial: const [CustomField(name: 'Locker', value: '1234', kind: CustomFieldKind.text)],
      );

      await tester.tap(find.byKey(const ValueKey('field-kind-0-boolean')));
      await tester.pump();
      expect(changes.last.single.kind, CustomFieldKind.boolean);
      expect(changes.last.single.value, 'false');
      expect(find.byKey(const ValueKey('field-tick-0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('field-kind-0-hidden')));
      await tester.pump();
      expect(changes.last.single.kind, CustomFieldKind.hidden);
      expect(changes.last.single.value, '');
      expect(_textField(tester, 'field-value-0').obscureText, isTrue);
    });
  });
}
