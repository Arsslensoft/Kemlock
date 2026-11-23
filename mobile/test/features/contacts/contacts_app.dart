import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/contacts/contact_keys.dart';
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/keys/import_key_sheet.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/key_sheet.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/files.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_scanner.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import 'contacts_kit.dart';

/// The app with a vault open on the Vault tab, at the contact tests' clock,
/// with a fake camera and file picker, and keys read and merged on this
/// isolate.
class ContactsApp {
  ContactsApp(this.tester) : app = TestApp(now: () => contactsNow);

  final WidgetTester tester;
  final TestApp app;
  final files = FakeFiles();
  final scanner = FakeScanner();

  List<Override> get overrides => [
    files.asOverride,
    scanner.asOverride,
    publicKeyReaderProvider.overrideWithValue(crypto.readPublicKeys),
    publicKeyMergerProvider.overrideWithValue(crypto.mergePublicKeys),
    keyReaderProvider.overrideWithValue((input, {passphrase}) => crypto.readPrivateKey(input, passphrase: passphrase)),
    keyExporterProvider.overrideWithValue(
      (key, {passphrase, comment}) => crypto.exportPrivateKey(key, passphrase: passphrase, comment: comment),
    ),
  ];

  Future<void> start() async {
    useTallPhone(tester);
    await app.pump(tester, overrides: overrides);
    await createVault(tester);
    await tapOn(tester, tab('nav.vault'));
  }

  List<Contact> get contacts => app.state.contacts;

  /// The page under every sheet, to open a sheet from as the app does.
  BuildContext get root => tester.element(find.byType(AppTabBar));

  /// Lets real async work (Ed25519 and RSA verification) finish.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tap(Finder finder) async {
    await tapOn(tester, finder);
    await settle();
  }

  /// Reads the keys of the fixture [path] as the add sheet would.
  Future<List<crypto.PgpPublicKey>> read(String path) async => (await tester.runAsync(() => crypto.readPublicKeys(keyText(path))))!;

  /// Opens the review of the keys in the fixtures [paths], as come from [source].
  Future<void> review(List<String> paths, {String source = ContactSource.qr, String? replacingId}) async {
    final keys = [for (final path in paths) ...await read(path)];
    unawaited(showContactReviewSheet(root, keys, source, replacingId: replacingId));
    await settle();
  }

  /// Puts [contact] in the vault as it is, check and dates included.
  Future<void> hold(Contact contact) async {
    await tester.runAsync(() async {
      final session = app.state.session!;
      await app.vaultStore.saveContacts([...app.state.contacts, contact], session);
      await app.controller.open(session);
    });
    await tester.pumpAndSettle();
  }

  /// Puts the secret key of the fixture [path] in the vault as one of the person's own keys.
  Future<VaultKey> holdOwnKey(String path, {String name = 'My key'}) async {
    final parsed = (await tester.runAsync(() => crypto.readPrivateKey(keyText(path))))!;
    final key = vaultKeyOf(parsed, id: 'own-1', name: name, origin: KeyOrigin.imported);
    await tester.runAsync(() => app.controller.addKey(key));
    await tester.pumpAndSettle();
    return key;
  }

  /// Gives the file picker the fixture [path] for its next pick.
  void pick(String path) {
    final file = keyFixtureFile(path);
    files.nextPick = PickedFile(name: file.uri.pathSegments.last, bytes: file.readAsBytesSync());
  }

  /// Dismisses the toast on screen, so the next one can be read.
  Future<void> clearToast() async {
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
  }
}
