// What the sync sheets say about a folder, a problem and the last sync
// (syncMessages.ts).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_messages.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/i18n/messages.dart';

import '../../helpers/test_app.dart';

DavAccount _at(String url) => DavAccount(url: url, username: 'me', password: 'app-pw');

/// Pumps a page and returns a context under the app's copy in [locale].
Future<BuildContext> _context(WidgetTester tester, {AppLocale locale = AppLocale.en}) async {
  await pumpScreen(tester, const SizedBox(key: Key('here')), locale: locale);
  return tester.element(find.byKey(const Key('here')));
}

void main() {
  group('davHost', () {
    test('is the host of the folder', () {
      expect(davHost(_at('https://dav.example.com/files/me/Kemlock/')), 'dav.example.com');
      expect(davHost(_at('  https://DAV.Example.com/remote.php/dav/  ')), 'dav.example.com');
    });

    test('keeps a port other than https’s own', () {
      expect(davHost(_at('https://nas.local:5006/dav/')), 'nas.local:5006');
      expect(davHost(_at('https://cloud.example.com:443/dav/')), 'cloud.example.com');
    });

    test('is the address as typed when it isn’t a URL', () {
      expect(davHost(_at('nas.local/dav')), 'nas.local/dav');
      expect(davHost(_at('')), '');
    });

    test('starts empty', () {
      expect(emptyDav.toJson(), {'url': '', 'username': '', 'password': ''});
    });
  });

  testWidgets('words every problem with its own message', (tester) async {
    final context = await _context(tester);

    for (final problem in SyncProblem.values) {
      expect(problemText(context, problem), t('sync.problem.${problem.name}'));
      expect(problemText(context, problem), isNot(startsWith('sync.problem.')));
    }
    expect(problemText(context, SyncProblem.network), isNot(t('sync.problem.networkWeb')));
  });

  testWidgets('says a scope hasn’t synced yet', (tester) async {
    final context = await _context(tester);

    expect(statusText(context, null), t('sync.status.never'));
    expect(statusText(context, const ScopeStatus()), t('sync.status.never'));
  });

  testWidgets('says when a scope last synced', (tester) async {
    final context = await _context(tester);
    final at = testNow.millisecondsSinceEpoch;
    final when = DateFormat.yMMMd('en').add_jm().format(DateTime.fromMillisecondsSinceEpoch(at));

    expect(statusText(context, ScopeStatus(lastSyncAt: at)), t('sync.status.synced', {'when': when}));
    expect(syncTime(context, at), contains('2026'));
    expect(syncTime(context, DateTime(2026, 10, 16, 9).millisecondsSinceEpoch), startsWith('Oct 16, 2026'));
  });

  testWidgets('puts a problem before the last sync', (tester) async {
    final context = await _context(tester);

    expect(statusText(context, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch, problem: SyncProblem.auth)), t('sync.problem.auth'));
  });

  testWidgets('writes the date in the app’s language', (tester) async {
    final context = await _context(tester, locale: AppLocale.fr);

    final when = syncTime(context, DateTime(2026, 10, 16, 21, 5).millisecondsSinceEpoch);
    expect(when, startsWith('16 oct. 2026'));
    expect(when, contains('21:05'));
    expect(statusText(context, const ScopeStatus()), testCatalog.of(AppLocale.fr).t('sync.status.never'));
  });
}
