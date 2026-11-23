import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/contacts/add_contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/contacts/lookup/key_search_sheet.dart';
import 'package:kemlock/features/contacts/lookup/vks.dart';
import 'package:kemlock/features/contacts/lookup/wkd.dart';
import 'package:kemlock/features/settings/offline_alert.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/ui/ui.dart';

import '../../../helpers/test_app.dart';
import 'lookup_app.dart';
import 'lookup_kit.dart';

/// "Find a key by email" (openspec: add-key-lookup, decision 8), from the add sheet to the review, against a fake
/// resolver and a MockClient under the app's gated client.
void main() {
  Future<LookupApp> open(WidgetTester tester) async {
    final lookup = LookupApp(tester);
    await lookup.start();
    await lookup.openSearch();
    return lookup;
  }

  String sourceRow(WidgetTester tester) => tester
      .widget<Text>(find.descendant(of: find.widgetWithText(GroupRow, t('contacts.review.source')), matching: find.byType(Text)).last)
      .data!;

  testWidgets('the add sheet offers it, and the sheet opens with an empty field and nothing sent', (tester) async {
    final lookup = LookupApp(tester);
    await lookup.start();
    unawaited(showAddContactSheet(lookup.root));
    await tester.pumpAndSettle();

    expect(find.text(t('contacts.add.lookup.body')), findsOneWidget);
    await lookup.tap(find.text(t('contacts.add.lookup')));

    expect(find.byType(AddContactSheet), findsNothing);
    expect(find.text(t('contacts.lookup.title')), findsOneWidget);
    expect(tester.widget<TextField>(lookup.addressField).controller!.text, isEmpty);
    expect(find.text(t('contacts.lookup.info')), findsOneWidget);
    expect(lookup.searchButton.onPressed, isNull);
    expect(lookup.services.requests, isEmpty);
  });

  testWidgets('the info names the typed address’s domain before anything is sent', (tester) async {
    final lookup = await open(tester);

    await lookup.type(' Grace@Example.ORG ');

    expect(find.text(t('contacts.lookup.info.domain', {'domain': 'example.org'})), findsOneWidget);
    expect(lookup.searchButton.onPressed, isNotNull);
    expect(lookup.services.resolved, isEmpty);
    expect(lookup.services.requests, isEmpty);
  });

  testWidgets('a name without an @ cannot be searched, and says to enter one address', (tester) async {
    final lookup = await open(tester);

    await lookup.type('Grace Hopper');
    expect(lookup.searchButton.onPressed, isNull);
    expect(find.text(t('contacts.lookup.invalid')), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text(t('contacts.lookup.invalid')), findsOneWidget);
    expect(lookup.services.resolved, isEmpty);
    expect(lookup.services.requests, isEmpty);
  });

  testWidgets('a domain outside ASCII says it cannot be looked up yet', (tester) async {
    final lookup = await open(tester);

    await lookup.type('grace@exämple.org');

    expect(find.text(t('contacts.lookup.international')), findsOneWidget);
    expect(lookup.searchButton.onPressed, isNull);
  });

  testWidgets('a key at the domain closes the sheet and opens "Add this key?", from its key directory', (tester) async {
    final lookup = await open(tester);
    lookup.services.directory('grace@example.org', lookupAnswer(wkdGrace));

    await lookup.search(' Grace@Example.ORG ');

    expect(find.byType(KeySearchSheet), findsNothing);
    expect(find.byType(ContactReviewSheet), findsOneWidget);
    expect(sourceRow(tester), t('contacts.source.wkd', {'domain': 'example.org'}));
    // The search runs for grace@example.org at example.org; l carries the part before the @ as typed (decision 1)
    final asked = lookup.services.requests.single;
    expect(
      (asked.host, asked.path),
      (wkdAdvancedUri(addressOf('grace@example.org')).host, wkdAdvancedUri(addressOf('grace@example.org')).path),
    );
    expect(asked.queryParameters, {'l': 'Grace'});
    expect(lookup.services.keyServerRequests, isEmpty);
  });

  testWidgets('a key added from the domain keeps its source and address, and no check', (tester) async {
    final lookup = await open(tester);
    lookup.services.directory('grace@example.org', lookupAnswer(wkdGrace));
    await lookup.search('grace@example.org');

    await lookup.tap(find.text(t('contacts.review.unchecked')));

    final contact = lookup.contacts.single;
    expect((contact.source, contact.sourceEmail), (ContactSource.wkd, 'grace@example.org'));
    expect((contact.checkedAt, contact.checkedFingerprint), (null, null));
  });

  testWidgets('closing the review adds nothing', (tester) async {
    final lookup = await open(tester);
    lookup.services.directory('grace@example.org', lookupAnswer(wkdGrace));
    await lookup.search('grace@example.org');

    Navigator.of(tester.element(find.byType(ContactReviewSheet))).pop();
    await tester.pumpAndSettle();

    expect(lookup.contacts, isEmpty);
  });

  testWidgets('no key at the domain offers keys.openpgp.org with its caption, and sends it nothing until asked', (tester) async {
    final lookup = await open(tester);
    lookup.services
      ..emptyDirectory('alan@example.org')
      ..keyServer('alan@example.org', 200, lookupAnswer(vksAlan));

    await lookup.search('alan@example.org');

    expect(find.text(t('contacts.lookup.domainHasNone', {'domain': 'example.org'})), findsOneWidget);
    expect(find.text(t('contacts.lookup.askServer.caption')), findsOneWidget);
    expect(lookup.services.keyServerRequests, isEmpty);

    await lookup.tap(find.text(t('contacts.lookup.askServer')));

    expect(lookup.services.keyServerRequests, [vksUri(addressOf('alan@example.org'))]);
    expect(find.byType(ContactReviewSheet), findsOneWidget);
    expect(sourceRow(tester), t('contacts.source.keyserver'));

    await lookup.tap(find.text(t('contacts.review.unchecked')));
    final contact = lookup.contacts.single;
    expect((contact.source, contact.sourceEmail, contact.checkedAt), (ContactSource.keyserver, 'alan@example.org', null));
  });

  testWidgets('says when no key was found anywhere', (tester) async {
    final lookup = await open(tester);
    lookup.services.emptyDirectory('alan@example.org');
    await lookup.search('alan@example.org');

    await lookup.tap(find.text(t('contacts.lookup.askServer')));

    expect(find.byKey(const ValueKey('lookup-nowhere')), findsOneWidget);
    expect(find.text(t('contacts.lookup.nowhere')), findsOneWidget);
  });

  testWidgets('a domain that could not be reached says so, and "Try again" asks only it again', (tester) async {
    final lookup = await open(tester);

    await lookup.search('grace@example.org');

    expect(find.text(t('contacts.lookup.unreachable', {'host': 'example.org'})), findsOneWidget);
    expect(find.text(t('contacts.lookup.askServer')), findsNothing);

    lookup.services.directory('grace@example.org', lookupAnswer(wkdGrace));
    lookup.services.resolved.clear();
    await lookup.tap(find.text(t('contacts.lookup.retry')));

    expect(lookup.services.resolved, ['openpgpkey.example.org']);
    expect(lookup.services.keyServerRequests, isEmpty);
    expect(find.byType(ContactReviewSheet), findsOneWidget);
  });

  testWidgets('a key server that could not be reached or asks to slow down says so, and "Try again" asks only it', (tester) async {
    final lookup = await open(tester);
    lookup.services
      ..emptyDirectory('alan@example.org')
      ..keyServer('alan@example.org', 503);
    await lookup.search('alan@example.org');
    await lookup.tap(find.text(t('contacts.lookup.askServer')));

    expect(find.text(t('contacts.lookup.unreachable', {'host': vksHost})), findsOneWidget);

    lookup.services
      ..keyServer('alan@example.org', 429)
      ..requests.clear()
      ..resolved.clear();
    await lookup.tap(find.text(t('contacts.lookup.retry')));

    expect(find.text(t('contacts.lookup.slowDown')), findsOneWidget);
    expect(lookup.services.requests, [vksUri(addressOf('alan@example.org'))]);
    expect(lookup.services.resolved, isEmpty);
  });

  testWidgets('a changed address is a new search, and the key server offer goes with the old one', (tester) async {
    final lookup = await open(tester);
    lookup.services
      ..emptyDirectory('alan@example.org')
      ..emptyDirectory('grace@example.org');
    await lookup.search('alan@example.org');
    expect(find.text(t('contacts.lookup.askServer')), findsOneWidget);

    await lookup.type('grace@example.org');

    expect(find.text(t('contacts.lookup.askServer')), findsNothing);
    expect(find.text(t('contacts.lookup.search')), findsOneWidget);
    await lookup.tap(find.text(t('contacts.lookup.search')));
    expect(find.text(t('contacts.lookup.askServer')), findsOneWidget);
    expect(lookup.services.keyServerRequests, isEmpty);
  });

  testWidgets('closing the sheet while searching adds nothing', (tester) async {
    final lookup = await open(tester);
    final answer = Completer<http.Response>();
    final url = wkdAdvancedUri(addressOf('grace@example.org'));
    lookup.services
      ..hosts.add(url.host)
      ..answers['${url.host}${url.path}'] = (_) => answer.future;
    await lookup.search('grace@example.org');
    expect(find.text(t('contacts.lookup.asking', {'host': 'example.org'})), findsOneWidget);

    Navigator.of(tester.element(find.byType(KeySearchSheet))).pop();
    await tester.pumpAndSettle();
    answer.complete(http.Response.bytes(lookupAnswer(wkdGrace), 200));
    await lookup.settle();

    expect(find.byType(KeySearchSheet), findsNothing);
    expect(find.byType(ContactReviewSheet), findsNothing);
    expect(lookup.contacts, isEmpty);
  });

  testWidgets('with offline mode on, the sheet says so, cannot search, and the add sheet reads paused', (tester) async {
    final lookup = LookupApp(tester);
    await lookup.start();
    await lookup.setOffline(true);
    unawaited(showAddContactSheet(lookup.root));
    await tester.pumpAndSettle();

    expect(find.text(t('contacts.add.lookup.paused')), findsOneWidget);
    await lookup.tap(find.text(t('contacts.add.lookup')));
    await lookup.type('grace@example.org');

    expect(find.widgetWithText(OfflineAlert, t('contacts.lookup.offline')), findsOneWidget);
    expect(find.text(t('contacts.lookup.info.domain', {'domain': 'example.org'})), findsNothing);
    expect(lookup.searchButton.onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await lookup.settle();
    expect(lookup.services.resolved, isEmpty);
    expect(lookup.services.requests, isEmpty);
  });

  testWidgets('reopened, the sheet shows an empty field and no earlier search', (tester) async {
    final lookup = await open(tester);
    lookup.services.emptyDirectory('alan@example.org');
    await lookup.search('alan@example.org');
    Navigator.of(tester.element(find.byType(KeySearchSheet))).pop();
    await tester.pumpAndSettle();

    await lookup.openSearch();

    expect(tester.widget<TextField>(lookup.addressField).controller!.text, isEmpty);
    expect(find.text(t('contacts.lookup.domainHasNone', {'domain': 'example.org'})), findsNothing);
    expect(find.text(t('contacts.lookup.info')), findsOneWidget);
  });
}
