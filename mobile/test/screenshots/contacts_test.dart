import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/contacts/add_contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_keys.dart';
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/contacts/lookup/key_search.dart';
import 'package:kemlock/features/contacts/lookup/key_search_sheet.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/ui/ui.dart';

import '../features/contacts/contacts_kit.dart';
import '../features/contacts/lookup/lookup_kit.dart';
import '../flows/flow_kit.dart' show tab, tapOn;
import '../helpers/app_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart' show t;

/// Renders the screens of other people's keys, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/contacts_test.dart
///
/// "Add this key?" follows `Contact.dc.html` in sections, wording and order. "Find a key by email" has no mockup:
/// it follows the words of add-key-lookup's design decision 8.
void main() {
  /// The Vault tab of an open vault holding [held], with keys read on this isolate.
  Future<TestApp> vaultTab(
    WidgetTester tester,
    Brightness brightness, {
    List<Contact> held = const [],
    List<Override> overrides = const [],
  }) async {
    usePhoneScreen(tester);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final app = TestApp(now: () => contactsNow);
    await tester.runAsync(() async {
      final session = await app.createVault('pw');
      if (held.isNotEmpty) await app.vaultStore.saveContacts(held, session);
    });
    await app.pump(
      tester,
      overrides: [
        publicKeyReaderProvider.overrideWithValue(crypto.readPublicKeys),
        publicKeyMergerProvider.overrideWithValue(crypto.mergePublicKeys),
        ...overrides,
      ],
    );
    await app.unlock(tester, 'pw');
    await tapOn(tester, tab('nav.vault'));
    app.container.read(toastsProvider.notifier).dismiss();
    await tester.pumpAndSettle();
    return app;
  }

  final added = DateTime(2026, 11, 2, 18).millisecondsSinceEpoch;
  final grace = contactOf(grace1, checkedAt: DateTime(2026, 11, 3, 9).millisecondsSinceEpoch, addedAt: added);

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('add this key, $name', (tester) async {
      await vaultTab(tester, brightness);
      final keys = (await tester.runAsync(() => crypto.readPublicKeys(keyText(grace1))))!;

      unawaited(showContactReviewSheet(tester.element(find.byType(AppTabBar)), keys, ContactSource.qr));
      await tester.pumpAndSettle();

      await takeScreenshot(tester, 'contacts_add_this_key_$name');
    });

    testScreenshot('a contact, $name', (tester) async {
      await vaultTab(tester, brightness, held: [grace]);

      await tapOn(tester, find.text('Grace Hopper'));

      await takeScreenshot(tester, 'contacts_sheet_$name');
    });

    testScreenshot('replace this key, $name', (tester) async {
      await vaultTab(tester, brightness, held: [grace]);
      final keys = (await tester.runAsync(() => crypto.readPublicKeys(keyText(graceOther))))!;

      unawaited(showContactReviewSheet(tester.element(find.byType(AppTabBar)), keys, ContactSource.file, replacingId: 'c1'));
      await tester.pumpAndSettle();

      await takeScreenshot(tester, 'contacts_replace_$name');
    });

    // The "Other people's keys" section of Main.dc.html: a checked and an unchecked contact
    testScreenshot('other people’s keys under the Keys filter, $name', (tester) async {
      await vaultTab(
        tester,
        brightness,
        held: [
          grace,
          contactOf(alan, id: 'c2', name: 'Alan Turing', addedAt: added),
        ],
      );

      await tapOn(tester, find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t('vault.filter.keys'))));

      await takeScreenshot(tester, 'contacts_keys_filter_$name');
    });

    // "Find a key by email", which has no mockup: the add sheet's new row, and the search sheet with an address
    // typed, after the domain had no key, and with offline mode on
    testScreenshot('add someone’s key, $name', (tester) async {
      await vaultTab(tester, brightness);

      unawaited(showAddContactSheet(tester.element(find.byType(AppTabBar))));
      await tester.pumpAndSettle();

      await takeScreenshot(tester, 'contacts_add_sheet_$name');
    });

    Future<FakeKeyServices> searchSheet(WidgetTester tester, {bool offline = false}) async {
      final services = FakeKeyServices();
      final app = await vaultTab(
        tester,
        brightness,
        overrides: [...services.overrides, keyLookupReaderProvider.overrideWithValue(readKeysForAddress)],
      );
      if (offline) app.container.read(offlineProvider.notifier).set(true);
      unawaited(showKeySearchSheet(tester.element(find.byType(AppTabBar))));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('lookup-address')), 'grace@example.org');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      return services;
    }

    testScreenshot('find a key by email, an address typed, $name', (tester) async {
      await searchSheet(tester);

      await takeScreenshot(tester, 'contacts_lookup_typed_$name');
    });

    testScreenshot('find a key by email, the domain has none, $name', (tester) async {
      final services = await searchSheet(tester);
      services.emptyDirectory('grace@example.org');

      await tapOn(tester, find.text(t('contacts.lookup.search')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();

      await takeScreenshot(tester, 'contacts_lookup_domain_has_none_$name');
    });

    testScreenshot('find a key by email, offline mode on, $name', (tester) async {
      await searchSheet(tester, offline: true);

      await takeScreenshot(tester, 'contacts_lookup_offline_$name');
    });
  }
}
