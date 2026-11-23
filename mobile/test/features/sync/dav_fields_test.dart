// The WebDAV folder and login fields the sync and spaces sheets share
// (DavFields.tsx).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/dav_fields.dart';
import 'package:kemlock/features/sync/sync_messages.dart';
import 'package:kemlock/features/sync/webdav.dart';

import '../../helpers/test_app.dart';

/// Holds the account the fields edit, as the sheets do, and lets the test set it from outside.
class _Host extends StatefulWidget {
  const _Host({required this.changes, this.urlHelper, this.enabled = true});

  final List<DavAccount> changes;
  final String? urlHelper;
  final bool enabled;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  DavAccount value = emptyDav;

  void set(DavAccount next) => setState(() => value = next);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: DavFields(
      value: value,
      enabled: widget.enabled,
      urlHelper: widget.urlHelper,
      onChanged: (next) {
        widget.changes.add(next);
        set(next);
      },
    ),
  );
}

Finder _field(String label) => find.widgetWithText(TextField, label);

TextField _textField(WidgetTester tester, String label) => tester.widget<TextField>(_field(label));

void main() {
  testWidgets('asks for the folder address, the username and an app password', (tester) async {
    await pumpOnPage(tester, _Host(changes: []));

    expect(_field(t('sync.field.url')), findsOneWidget);
    expect(_field(t('sync.field.username')), findsOneWidget);
    expect(_field(t('sync.field.password')), findsOneWidget);
    expect(find.text(t('sync.field.urlHelper')), findsOneWidget);
    expect(find.text(t('sync.field.passwordHelper')), findsOneWidget);
    expect(_textField(tester, t('sync.field.url')).decoration?.hintText, startsWith('https://'));
    expect(_textField(tester, t('sync.field.url')).keyboardType, TextInputType.url);
  });

  testWidgets('hides the app password and leaves the address and username uncorrected', (tester) async {
    await pumpOnPage(tester, _Host(changes: []));

    expect(_textField(tester, t('sync.field.password')).obscureText, isTrue);
    for (final label in [t('sync.field.url'), t('sync.field.username')]) {
      expect(_textField(tester, label).obscureText, isFalse);
      expect(_textField(tester, label).autocorrect, isFalse);
      expect(_textField(tester, label).textCapitalization, TextCapitalization.none);
    }
  });

  testWidgets('reports each field as it’s typed', (tester) async {
    final changes = <DavAccount>[];
    await pumpOnPage(tester, _Host(changes: changes));

    await tester.enterText(_field(t('sync.field.url')), 'https://dav.example.com/files/me/');
    await tester.enterText(_field(t('sync.field.username')), 'me');
    await tester.enterText(_field(t('sync.field.password')), 'app-pw');

    expect(changes.last, const DavAccount(url: 'https://dav.example.com/files/me/', username: 'me', password: 'app-pw'));
    expect(changes, hasLength(3));
  });

  testWidgets('says which folder to pick when the sheet asks for another', (tester) async {
    await pumpOnPage(tester, _Host(changes: [], urlHelper: t('spaces.field.urlHelper')));

    expect(find.text(t('spaces.field.urlHelper')), findsOneWidget);
    expect(find.text(t('sync.field.urlHelper')), findsNothing);
  });

  testWidgets('shows an account set from outside', (tester) async {
    await pumpOnPage(tester, _Host(changes: []));

    tester.state<_HostState>(find.byType(_Host)).set(const DavAccount(url: '', username: 'me', password: 'app-pw'));
    await tester.pump();

    expect(_textField(tester, t('sync.field.username')).controller?.text, 'me');
    expect(_textField(tester, t('sync.field.password')).controller?.text, 'app-pw');
    expect(_textField(tester, t('sync.field.url')).controller?.text, isEmpty);
  });

  testWidgets('can be turned off while the sheet works', (tester) async {
    await pumpOnPage(tester, _Host(changes: [], enabled: false));

    for (final label in [t('sync.field.url'), t('sync.field.username'), t('sync.field.password')]) {
      expect(_textField(tester, label).enabled, isFalse);
    }
  });
}
