import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/breaches/hibp.dart';
import 'package:kemlock/features/contacts/contact_sheet.dart';
import 'package:kemlock/features/contacts/lookup/key_search.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/contact.dart';

import '../../../flows/flow_kit.dart';
import '../../../helpers/app_harness.dart';
import '../../../helpers/test_app.dart' show t;
import '../../sync/fake_webdav.dart';
import '../contacts_kit.dart';
import 'lookup_kit.dart';

const _dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const _syncPath = '/files/me/Kemlock/$syncFile';

/// Nothing looks a key up on its own (openspec: add-key-lookup, decision 10): a vault whose contacts were found by
/// lookup is unlocked, synced and browsed, contact sheet included, and neither the lookup's client nor its name
/// resolver is ever asked.
void main() {
  testWidgets('unlocking, syncing and opening contacts found by lookup makes no lookup request', (tester) async {
    final services = FakeKeyServices();
    final dav = FakeWebDav();
    final hibp = <http.Request>[];
    final app = TestApp(now: () => contactsNow);
    await tester.runAsync(() async {
      final session = await app.createVault('pw');
      await app.vaultStore.saveContacts([
        contactOf(grace1, source: ContactSource.wkd).copyWith(sourceEmail: 'grace@example.org'),
        contactOf(alan, id: 'c2', name: 'Alan Turing', source: ContactSource.keyserver).copyWith(sourceEmail: 'alan@example.org'),
      ], session);
      await app.vaultStore.saveEncryptedValue(
        'backmycodes_sync',
        const SyncSettings()
            .copyWith(
              personal: SyncTarget(dav: _dav, file: syncFile, key: b64(randomBytes(32))),
            )
            .toJson(),
        session,
      );
    });
    await startApp(
      tester,
      app,
      overrides: [
        ...services.overrides,
        keyLookupReaderProvider.overrideWithValue(readKeysForAddress),
        webDavProvider.overrideWithValue(WebDav(dav.client)),
        hibpClientProvider.overrideWithValue(
          MockClient((request) async {
            hibp.add(request);
            return http.Response('', 503);
          }),
        ),
      ],
    );

    await app.unlock(tester, 'pw');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // The sync ran, and wrote the contacts to the folder
    expect(dav.requests.where((request) => request.url.path == _syncPath), isNotEmpty);
    expect(dav.files[_syncPath], isNotNull);

    await tapOn(tester, tab('nav.vault'));
    await tester.pump(const Duration(minutes: 1));
    await tapOn(tester, find.text('Grace Hopper'));
    expect(find.byType(ContactSheet), findsOneWidget);
    expect(find.text(t('contacts.sheet.lookup')), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    Navigator.of(tester.element(find.byType(ContactSheet))).pop();
    await tester.pumpAndSettle();
    await tapOn(tester, find.text('Alan Turing'));
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();

    expect(services.requests, isEmpty);
    expect(services.resolved, isEmpty);
    expect(hibp, isEmpty);
  });
}
