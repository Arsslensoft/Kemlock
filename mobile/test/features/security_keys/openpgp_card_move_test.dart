// Moving a vault PGP key onto the fake OpenPGP card through the Move
// sheet (openspec: add-openpgp-card, tasks 11.2 and 11.3): moved, the
// entry becomes the card key under the same id; copied, it stays as it
// was; a card that does not show the key afterwards, or a wrong
// passphrase, leaves it as it was.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/openpgp/writer.dart' show cardStubSerials;
import 'package:kemlock/features/keys/card_keys.dart';
import 'package:kemlock/features/security_keys/card_pin_forms.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_openpgp_card.dart';
import 'key_sheet_harness.dart';
import 'openpgp_card_harness.dart';

const _primary = '1FCDA135EE42400EC2B77CE677249ABE661CF8DB';
const _subkey = '4BA83174FC8CE762A23BF0A4841A40E3B199EA67';
const _passphrase = 'fixture passphrase';

/// A GnuPG Ed25519 fixture key as the vault keeps it, with a note, a tag,
/// a pin and a space, and its own passphrase when [protected].
VaultKey _vaultKey({bool protected = false}) {
  final base = 'test/fixtures/keys/gnupg/${protected ? 'ed25519-protected' : 'ed25519'}';
  return VaultKey(
    id: 'k-move',
    name: 'Work key',
    kind: KeyKind.pgp,
    algorithm: 'pgp',
    privateKey: b64(File('$base.secret.gpg').readAsBytesSync()),
    publicKey: b64(File('$base.public.gpg').readAsBytesSync()),
    origin: KeyOrigin.imported,
    protected: protected ? true : null,
    note: 'Mail at work',
    tags: const ['work'],
    pinned: true,
    spaceId: 'space-work',
    addedAt: 1000,
    updatedAt: 2000,
  );
}

void main() {
  Future<void> openMove(WidgetTester tester, KeySheetRig rig) async {
    await openPgpKeys(rig);
    final button = find.byKey(const ValueKey('openpgp-move'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> tapMove(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('card-move-button'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await settleReal(tester);
  }

  Future<void> givePins(WidgetTester tester) async {
    await typeCardPin(tester, FakeOpenPgpCard.factoryAdminPin);
    await typeCardPin(tester, FakeOpenPgpCard.factoryPin);
    await settleReal(tester, 20);
  }

  Future<void> answerPassphrase(WidgetTester tester, String passphrase) async {
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), passphrase);
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text(tr('pgp.passphrase.continue'))));
    await settleReal(tester);
  }

  testWidgets('shows which part goes where, and the warning with the export, before anything is sent', (tester) async {
    final card = FakeOpenPgpCard();
    final (rig, _) = await openWithCard(tester, card: card, vault: CardVault([_vaultKey()]));
    card.log.clear();
    await openMove(tester, rig);

    expect(rowValue(tester, 'card-move-place-signature'), contains(tr('securityKeys.openpgp.move.primary', {'algorithm': 'Ed25519'})));
    expect(rowValue(tester, 'card-move-place-decryption'), contains(tr('securityKeys.openpgp.move.subkey', {'algorithm': 'Curve25519'})));
    expect(find.byKey(const ValueKey('card-move-place-authentication')), findsNothing);
    expect(find.byKey(const ValueKey('card-move-warning')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-move-export')), findsOneWidget);
    expect(card.log.where((entry) => entry.startsWith('import')), isEmpty);
    expect(card.pinsSent, isEmpty);
  });

  testWidgets('moved: the entry is the card key under the same id, name, note, tags, pin and space', (tester) async {
    final card = FakeOpenPgpCard();
    final before = _vaultKey();
    final (rig, vault) = await openWithCard(tester, card: card, vault: CardVault([before]));
    await openMove(tester, rig);
    await tapMove(tester);
    await givePins(tester);

    final key = vault.keys.single;
    expect(key.id, before.id);
    expect(key.name, before.name);
    expect(key.note, before.note);
    expect(key.tags, before.tags);
    expect(key.pinned, before.pinned);
    expect(key.spaceId, before.spaceId);
    expect(key.addedAt, before.addedAt);
    expect(key.updatedAt, greaterThan(before.updatedAt!));
    expect(key.publicKey, before.publicKey);
    expect(key.isOnCard, isTrue);
    expect(cardKeyAid(key), cardHex(card.fullAid));
    expect(cardKeyFingerprints(key), unorderedEquals([_primary, _subkey]));
    expect(cardStubSerials(unb64(key.privateKey)).keys, unorderedEquals([_primary, _subkey]));
    expect(cardHex(card.fingerprints[CardPlace.signature]!), _primary);
    expect(cardHex(card.fingerprints[CardPlace.decryption]!), _subkey);
    // The proofs: a signature verified and a session key opened
    expect(card.log, containsAll(['import b6', 'import b8', 'sign', 'decipher']));
  });

  testWidgets('copied: the entry is byte for byte as before, and the card holds the key', (tester) async {
    final card = FakeOpenPgpCard();
    final before = _vaultKey();
    final (rig, vault) = await openWithCard(tester, card: card, vault: CardVault([before]));
    await openMove(tester, rig);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('card-move-keep')), matching: find.byType(AppSwitch)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-move-warning')), findsNothing);
    await tapMove(tester);
    await givePins(tester);

    expect(vault.keys.single.toJson(), before.toJson());
    expect(cardHex(card.fingerprints[CardPlace.signature]!), _primary);
    expect(cardHex(card.fingerprints[CardPlace.decryption]!), _subkey);
  });

  testWidgets('a card that does not show the key afterwards leaves the entry as before and says so', (tester) async {
    final card = FakeOpenPgpCard()..ignoreFingerprints = true;
    final before = _vaultKey();
    final (rig, vault) = await openWithCard(tester, card: card, vault: CardVault([before]));
    await openMove(tester, rig);
    await tapMove(tester);
    await givePins(tester);

    expect(vault.keys.single.toJson(), before.toJson());
    expect(find.text(tr('securityKeys.openpgp.move.incomplete')), findsOneWidget);
  });

  testWidgets('a key with its own passphrase: a wrong one sends nothing, the right one moves it', (tester) async {
    final card = FakeOpenPgpCard();
    final before = _vaultKey(protected: true);
    final (rig, vault) = await openWithCard(tester, card: card, vault: CardVault([before]));
    await openMove(tester, rig);
    card.log.clear();
    await tapMove(tester);
    await answerPassphrase(tester, 'not the passphrase');

    expect(find.text(tr('pgp.error.wrongKeyPassphrase')), findsOneWidget);
    expect(find.byType(CardPinPrompt), findsNothing);
    expect(card.log.where((entry) => entry.startsWith('import')), isEmpty);
    expect(card.pinsSent, isEmpty);
    expect(vault.keys.single.toJson(), before.toJson());

    await answerPassphrase(tester, _passphrase);
    await givePins(tester);

    expect(vault.keys.single.isOnCard, isTrue);
    expect(vault.keys.single.id, before.id);
  });
}
