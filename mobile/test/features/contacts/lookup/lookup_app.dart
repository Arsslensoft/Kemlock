import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/add_contact_sheet.dart';
import 'package:kemlock/features/contacts/lookup/key_search.dart';
import 'package:kemlock/platform/network.dart';

import '../../../helpers/test_app.dart';
import '../contacts_app.dart';
import 'lookup_kit.dart';

/// [ContactsApp] with the key lookup's services faked ([services]) under the app's own gated client and
/// resolver, and its answers read on this isolate.
class LookupApp extends ContactsApp {
  LookupApp(super.tester);

  final services = FakeKeyServices();

  @override
  List<Override> get overrides => [
    ...super.overrides,
    ...services.overrides,
    keyLookupReaderProvider.overrideWithValue(readKeysForAddress),
  ];

  /// The search sheet's address field.
  Finder get addressField => find.byKey(const ValueKey('lookup-address'));

  /// The search button, to read whether it can be pressed.
  FilledButton get searchButton => tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('contacts.lookup.search')));

  /// Opens "Find a key by email" the way the person does: from "Add someone's key".
  Future<void> openSearch() async {
    unawaited(showAddContactSheet(root));
    await tester.pumpAndSettle();
    await tap(find.text(t('contacts.add.lookup')));
  }

  /// Types [address] into the field.
  Future<void> type(String address) async {
    await tester.enterText(addressField, address);
    await tester.pump();
  }

  /// Types [address] and taps "Search".
  Future<void> search(String address) async {
    await type(address);
    await tap(find.text(t('contacts.lookup.search')));
  }

  /// Turns offline mode on or off, as the switch in Settings does.
  Future<void> setOffline(bool on) async {
    app.container.read(offlineProvider.notifier).set(on);
    await tester.pumpAndSettle();
  }
}
