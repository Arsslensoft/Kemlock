import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/tag_input.dart';

import '../../helpers/test_app.dart';

/// Holds the tags as the edit form does, and records each change.
class _Harness extends StatefulWidget {
  const _Harness({this.initial = const [], this.suggestions = const [], required this.changes});

  final List<String> initial;
  final List<String> suggestions;
  final List<List<String>> changes;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<String> tags = widget.initial;
  final key = GlobalKey<TagInputState>();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TagInput(
        key: key,
        value: tags,
        suggestions: widget.suggestions,
        onChanged: (next) {
          widget.changes.add(next);
          setState(() => tags = next);
        },
      ),
      // Somewhere else to tap, to leave the field
      TextButton(onPressed: () => FocusManager.instance.primaryFocus?.unfocus(), child: const Text('elsewhere')),
    ],
  );
}

Future<List<List<String>>> _pump(WidgetTester tester, {List<String> initial = const [], List<String> suggestions = const []}) async {
  final changes = <List<String>>[];
  await pumpOnPage(tester, _Harness(initial: initial, suggestions: suggestions, changes: changes));
  return changes;
}

Finder get _field => find.widgetWithText(TextField, t('tags.label'));

void main() {
  testWidgets('adds a tag on Enter and keeps the field for the next one', (tester) async {
    final changes = await _pump(tester);

    await tester.enterText(_field, '  Work ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(changes.last, ['Work']);
    expect(find.text('Work'), findsOneWidget);
    expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('finishes a tag at a comma', (tester) async {
    final changes = await _pump(tester);

    await tester.enterText(_field, 'Work,Pers');
    await tester.pump();

    expect(changes.last, ['Work']);
    expect(tester.widget<TextField>(_field).controller!.text, 'Pers');
  });

  testWidgets('adds what was typed when the field is left', (tester) async {
    final changes = await _pump(tester);

    await tester.enterText(_field, 'Family');
    await tester.tap(find.text('elsewhere'));
    await tester.pump();

    expect(changes.last, ['Family']);
  });

  testWidgets('skips a tag it has, whatever its case or accents', (tester) async {
    final changes = await _pump(tester, initial: ['Été']);

    await tester.enterText(_field, 'ete');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(changes, isEmpty);
    expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
  });

  testWidgets('cuts a tag at 24 characters', (tester) async {
    final changes = await _pump(tester);

    await tester.enterText(_field, 'A' * 30);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(changes.last, ['A' * maxTagLength]);
  });

  testWidgets('removes a tag with its delete button', (tester) async {
    final changes = await _pump(tester, initial: ['Work', 'Games']);

    await tester.tap(find.bySemanticsLabel('Delete Work'));
    await tester.pump();

    expect(changes.last, ['Games']);
  });

  testWidgets('offers the tags of other accounts it does not have yet, up to eight', (tester) async {
    final changes = await _pump(tester, initial: ['work'], suggestions: ['Work', for (var i = 1; i <= 10; i++) 'Tag $i']);

    expect(find.text('Work'), findsNothing);
    expect(find.text('Tag 8'), findsOneWidget);
    expect(find.text('Tag 9'), findsNothing);

    await tester.tap(find.text('Tag 3'));
    await tester.pump();

    expect(changes.last, ['work', 'Tag 3']);
    expect(find.text('Tag 9'), findsOneWidget);
  });

  testWidgets('adds the tag still being typed when the form asks', (tester) async {
    final changes = await _pump(tester);
    await tester.enterText(_field, 'Bank');

    final state = tester.state<TagInputState>(find.byType(TagInput));
    expect(state.commitDraft(), ['Bank']);
    expect(changes.last, ['Bank']);
  });
}
