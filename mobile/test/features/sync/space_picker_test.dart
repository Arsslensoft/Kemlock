// Choosing where an entry lives (SpacePicker.tsx): the vault itself or a
// shared space.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/space_picker.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';

import '../../helpers/test_app.dart';
import 'sync_screen_kit.dart';

const _dav = DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'app-pw');

Space _space(String id, String name) => Space(
  id: id,
  name: name,
  target: SyncTarget(dav: _dav, file: spaceFile(id), key: 'a2V5'),
  joinedAt: 1,
);

final _twoSpaces = SyncSettings(spaces: [_space('fam', 'Family'), _space('team', 'Team')]);

/// Holds the picked space as a sheet would, and records every change.
class _Host extends StatefulWidget {
  const _Host({this.initial, required this.changes});

  final String? initial;
  final List<String?> changes;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String? _value = widget.initial;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('Above'),
      SpacePicker(
        value: _value,
        onChanged: (id) {
          widget.changes.add(id);
          setState(() => _value = id);
        },
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester, {SyncSettings? settings, String? value, List<String?>? changes}) => pumpOnPage(
  tester,
  _Host(initial: value, changes: changes ?? []),
  overrides: [fakeSync(SyncSnapshot(settings: settings ?? noSync))],
);

void main() {
  testWidgets('takes no room when there is no space and the entry is the vault’s own', (tester) async {
    await _pump(tester);

    expect(find.text('Above'), findsOneWidget);
    expect(find.text(t('spaces.picker.label')), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('takes no room while sync is still loading', (tester) async {
    await pumpOnPage(tester, _Host(changes: []), overrides: [fakeSync(const SyncSnapshot())]);

    expect(find.text(t('spaces.picker.label')), findsNothing);
  });

  testWidgets('offers the vault itself and every space, and moves the entry into one', (tester) async {
    final changes = <String?>[];
    await _pump(tester, settings: _twoSpaces, changes: changes);

    expect(find.text(t('spaces.picker.label')), findsOneWidget);
    expect(find.text(t('spaces.picker.mine')), findsOneWidget);

    await tester.tap(find.text(t('spaces.picker.mine')));
    await tester.pumpAndSettle();
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);

    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();

    expect(changes, ['team']);
    expect(find.text('Team'), findsOneWidget);
    expect(find.text(t('spaces.picker.mine')), findsNothing);
  });

  testWidgets('takes an entry back out of its space', (tester) async {
    final changes = <String?>[];
    await _pump(tester, settings: _twoSpaces, value: 'fam', changes: changes);
    expect(find.text('Family'), findsOneWidget);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('spaces.picker.mine')).last);
    await tester.pumpAndSettle();

    expect(changes, [null]);
    expect(find.text(t('spaces.picker.mine')), findsOneWidget);
  });

  testWidgets('shows an entry in a space this vault left, which only goes back home', (tester) async {
    final changes = <String?>[];
    await _pump(tester, value: 'gone', changes: changes);

    // Shown with no space to pick, so the entry can still be taken out
    expect(find.text(t('spaces.picker.label')), findsOneWidget);
    expect(find.text(t('spaces.picker.left')), findsOneWidget);

    await tester.tap(find.text(t('spaces.picker.left')));
    await tester.pumpAndSettle();
    // The space that was left can't be picked again
    await tester.tap(find.text(t('spaces.picker.left')).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);

    await tester.tap(find.text(t('spaces.picker.mine')).last);
    await tester.pumpAndSettle();
    expect(changes, [null]);
    expect(find.text(t('spaces.picker.left')), findsNothing);
  });

  testWidgets('follows the spaces as the vault joins one', (tester) async {
    final container = await pumpOnPage(
      tester,
      _Host(changes: []),
      overrides: [fakeSync(const SyncSnapshot(settings: noSync))],
    );
    expect(find.text(t('spaces.picker.label')), findsNothing);

    (container.read(syncProvider.notifier) as FakeSyncNotifier).setSettings(_twoSpaces);
    await tester.pump();

    expect(find.text(t('spaces.picker.label')), findsOneWidget);
  });

  testWidgets('is named for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, settings: _twoSpaces, value: 'team');

    expect(find.bySemanticsLabel(RegExp(t('spaces.picker.label'))), findsWidgets);
    semantics.dispose();
  });

  testWidgets('keeps a long space name on one line', (tester) async {
    final long = SyncSettings(spaces: [_space('long', 'The extended family across three countries and two time zones')]);
    await _pump(tester, settings: long, value: 'long');

    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(find.textContaining('The extended family'));
    expect(text.maxLines, 1);
  });
}
