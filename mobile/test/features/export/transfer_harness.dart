import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/export_key.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_owner_check.dart';
import '../../helpers/screenshots.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';

/// An open vault holding [accounts] and [services], whose imports are
/// recorded instead of saved, as the Vitest files' `onImport` mock did.
class RecordingVault extends VaultController {
  RecordingVault({
    this.accounts = const [],
    this.services = const [],
    this.keys = const [],
    this.notes = const [],
    this.passkeys = const [],
    this.keyAccounts = const [],
    this.contacts = const [],
    this.logins = const [],
    this.cards = const [],
    this.identities = const [],
    this.session,
  });

  final List<OtpAccount> accounts;
  final List<BackupService> services;
  final List<VaultKey> keys;
  final List<SecureNote> notes;
  final List<Passkey> passkeys;
  final List<KeyAccount> keyAccounts;
  final List<Contact> contacts;
  final List<Login> logins;
  final List<PaymentCard> cards;
  final List<Identity> identities;
  final VaultSession? session;

  /// What each import handed the vault, in order.
  final List<({List<OtpAccount> accounts, List<BackupService> backupServices})> imports = [];

  /// The passkeys each import added, which the vault then holds.
  final List<List<Passkey>> passkeyImports = [];

  @override
  VaultState build() => VaultState(
    phase: VaultPhase.unlocked,
    session: session,
    accounts: accounts,
    backupServices: services,
    keys: keys,
    notes: notes,
    passkeys: passkeys,
    keyAccounts: keyAccounts,
    contacts: contacts,
    logins: logins,
    cards: cards,
    identities: identities,
    vault: const VaultInfo(id: 'test'),
  );

  /// The contacts each import added, which the vault then holds.
  final List<List<Contact>> contactImports = [];

  /// The keys and notes each import added, which the vault then holds.
  final List<({List<VaultKey> keys, List<SecureNote> notes})> itemImports = [];

  /// The on-key accounts each import added, which the vault then holds.
  final List<List<KeyAccount>> keyAccountImports = [];

  /// The logins each import added, which the vault then holds.
  final List<List<Login>> loginImports = [];

  @override
  Future<void> imported(
    List<OtpAccount> accounts,
    List<BackupService> services, {
    List<Passkey> passkeys = const [],
    List<VaultKey> keys = const [],
    List<SecureNote> notes = const [],
    List<KeyAccount> keyAccounts = const [],
    List<Contact> contacts = const [],
    List<Login> logins = const [],
    List<PaymentCard> cards = const [],
    List<Identity> identities = const [],
  }) async {
    imports.add((accounts: accounts, backupServices: services));
    loginImports.add(logins);
    passkeyImports.add(passkeys);
    itemImports.add((keys: keys, notes: notes));
    keyAccountImports.add(keyAccounts);
    contactImports.add(contacts);
    state = state.copyWith(
      passkeys: [...state.passkeys, ...passkeys],
      keys: [...state.keys, ...keys],
      notes: [...state.notes, ...notes],
      keyAccounts: [...state.keyAccounts, ...keyAccounts],
      contacts: [...state.contacts, ...contacts],
      logins: [...state.logins, ...logins],
      cards: [...state.cards, ...cards],
      identities: [...state.identities, ...identities],
    );
  }

  /// Changes the open vault as the app would while a sheet is up: more items, fewer, or another vault.
  void change(VaultState Function(VaultState state) edit) => state = edit(state);

  Override get asOverride => vaultControllerProvider.overrideWith(() => this);
}

/// Export passwords through cheap scrypt, so a test needn't wait for an isolate.
final fastExportKey = exportDeriveKeyProvider.overrideWithValue(fastKdf);

/// Pumps a page whose one button runs [open], taps it and settles, so the
/// sheet [open] shows is up. Returns the container. The check that the
/// person is the vault's owner passes unless [ownerCheck] says otherwise.
Future<ProviderContainer> openSheet(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open, {
  RecordingVault? vault,
  FakeFiles? files,
  FakeOwnerCheck? ownerCheck,
  List<Override> overrides = const [],
  Brightness brightness = Brightness.dark,
}) async {
  usePhoneScreen(tester);
  final container = await pumpScreen(
    tester,
    brightness: brightness,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(onPressed: () => unawaited(open(context)), child: const Text('Open')),
        ),
      ),
    ),
    overrides: [
      (vault ?? RecordingVault()).asOverride,
      (files ?? FakeFiles()).asOverride,
      (ownerCheck ?? FakeOwnerCheck()).asOverride,
      fastExportKey,
      ...overrides,
    ],
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return container;
}

/// The text field labelled with the message [id].
Finder fieldLabelled(String id, [Map<String, Object?> args = const {}]) => find.widgetWithText(TextField, t(id, args));

/// Scrolls [finder] into view, taps it and settles.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Pumps until [finder] finds something, letting real time pass for work in
/// another isolate (PBKDF2), for at most [timeout].
Future<void> pumpUntilFound(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) throw TestFailure('Timed out waiting for $finder');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}
