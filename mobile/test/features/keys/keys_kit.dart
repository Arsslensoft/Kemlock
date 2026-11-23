import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/edit.dart' show PgpSigner;
import 'package:kemlock/features/contacts/contact_keys.dart';
import 'package:kemlock/features/keys/generate_key_sheet.dart';
import 'package:kemlock/features/keys/import_key_sheet.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/key_edit_gate.dart';
import 'package:kemlock/features/keys/key_expiry_sheet.dart';
import 'package:kemlock/features/keys/key_revoke_sheet.dart';
import 'package:kemlock/features/keys/key_sheet.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

/// A key file from test/fixtures/keys.
File keyFixture(String path) => File('test/fixtures/keys/$path');

/// A generation the test finishes: with a key [makeKey] made, or cancelled.
class FakeKeyGeneration implements crypto.KeyGeneration {
  FakeKeyGeneration(this.request);

  final crypto.KeyRequest request;
  final _done = Completer<crypto.KeyGenerationResult>();
  var cancelled = false;

  @override
  Future<crypto.KeyGenerationResult> get result => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) _done.complete(const crypto.KeyGenerationCancelled());
  }

  /// Makes the key on this isolate and hands it over, or what making it
  /// threw, as the isolate hands that over.
  Future<void> finish() async {
    try {
      final key = await crypto.makeKey(request);
      if (!_done.isCompleted) _done.complete(crypto.KeyGenerated(key));
    } on Object catch (error) {
      if (!_done.isCompleted) _done.completeError(error);
    }
  }
}

/// The app with a vault open, keys read and exported on this isolate, and
/// generations the test finishes.
class KeysApp {
  KeysApp(this.tester);

  final WidgetTester tester;
  final app = TestApp();
  final files = FakeFiles();
  final generations = <FakeKeyGeneration>[];

  /// The changes to PGP keys started, which the test finishes
  /// ([finishChange]) or not (openspec: add-pgp-key-editing).
  final changes = <FakeKeyGeneration>[];

  /// What "On a date…" picks next; null cancels the picker.
  DateTime? nextDate;

  /// What opening a key with its passphrase throws instead of opening it.
  Object? openerThrows;

  List<Override> get overrides => [
    files.asOverride,
    keyReaderProvider.overrideWithValue((input, {passphrase}) => crypto.readPrivateKey(input, passphrase: passphrase)),
    publicKeyReaderProvider.overrideWithValue(crypto.readPublicKeys),
    publicKeyMergerProvider.overrideWithValue(crypto.mergePublicKeys),
    keyExporterProvider.overrideWithValue(
      (key, {passphrase, comment}) => crypto.exportPrivateKey(key, passphrase: passphrase, comment: comment),
    ),
    keyGeneratorProvider.overrideWithValue((request) {
      final generation = FakeKeyGeneration(request);
      generations.add(generation);
      return generation;
    }),
    pgpChangerProvider.overrideWithValue((request) {
      final generation = FakeKeyGeneration(request);
      changes.add(generation);
      return generation;
    }),
    pgpKeyOpenerProvider.overrideWithValue((key, passphrase) async {
      if (openerThrows case final error?) throw error;
      PgpSigner.of(key, passphrase: passphrase);
    }),
    revocationMakerProvider.overrideWithValue(crypto.revocationCertificate),
    expiryDatePickerProvider.overrideWithValue((context, initial) async => nextDate),
  ];

  Future<void> start() async {
    await startApp(tester, app, overrides: overrides);
    await createVault(tester);
    await tapOn(tester, tab('nav.vault'));
  }

  List<VaultKey> get keys => app.container.read(vaultControllerProvider).keys;

  Future<void> openAdd(String rowId) async {
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    await tapOn(tester, find.text(t(rowId)));
  }

  /// Starts the app with the PGP key of test/fixtures/keys/[path] in the
  /// vault as [name], under the id `k1`, and opens its sheet.
  Future<void> openPgpKey(String path, {String name = 'Ada'}) async {
    await start();
    final parsed = await tester.runAsync(() => crypto.readPrivateKey(keyFixture(path).readAsStringSync()));
    await app.container
        .read(vaultControllerProvider.notifier)
        .addKey(vaultKeyOf(parsed!, id: 'k1', name: name, origin: KeyOrigin.imported));
    // The add's toast would sit over the sheet until it times out
    await tester.pump(const Duration(seconds: 10));
    await settle();
    await tap(find.text(name));
  }

  /// Lets real async work (key derivations, Ed25519) finish.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
  }

  /// Pastes [text] into the import sheet and reads it.
  Future<void> paste(String text) async {
    await tester.enterText(find.widgetWithText(TextField, t('keys.import.paste')), text);
    await tester.pump();
    await tapOn(tester, find.text(t('keys.import.read')));
    await settle();
  }

  Future<void> tap(Finder finder) async {
    await tapOn(tester, finder);
    await settle();
  }

  /// Makes the latest change to a key on this isolate and lets the sheet save it.
  Future<void> finishChange() async {
    await tester.runAsync(() => changes.last.finish());
    await settle();
  }

  /// Taps the row [id] of the key sheet's "Change this key" section.
  Future<void> openChange(String id) async {
    final row = find.descendant(of: find.byKey(const ValueKey('key-change')), matching: find.text(t(id)));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.descendant(of: find.byType(KeySheet), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    await tap(row);
  }

  /// The vault's key [id].
  VaultKey key(String id) => keys.firstWhere((key) => key.id == id);

  Finder dialogButton(String id) => find.descendant(of: find.byType(Dialog), matching: find.text(t(id)));
}
