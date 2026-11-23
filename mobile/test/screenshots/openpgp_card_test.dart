import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/security_keys/card_pin_forms.dart';
import 'package:kemlock/features/security_keys/openpgp_card_sheet.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';

import '../fakes/fake_openpgp_card.dart';
import '../features/security_keys/key_sheet_harness.dart';
import '../features/security_keys/openpgp_card_harness.dart';
import '../helpers/screenshots.dart';

/// Renders the PGP keys of a security key and the sheets they open
/// (openspec: add-openpgp-card, tasks 5.5, 6.6, 10.5 and 11.5), in dark and
/// light, on a fake phone with a fake card:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/openpgp_card_test.dart
void main() {
  final secret = File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync();

  /// A card holding the GnuPG Ed25519 fixture's signing and decryption
  /// keys, its authentication place empty.
  Future<FakeOpenPgpCard> twoKeys(WidgetTester tester) async {
    final card = FakeOpenPgpCard();
    await tester.runAsync(() => card.loadPgpKey(secret));
    return card;
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<KeySheetRig> open(WidgetTester tester, FakeOpenPgpCard card, {CardVault? vault}) async {
      usePhoneScreen(tester);
      final (rig, _) = await openWithCard(tester, card: card, vault: vault, brightness: brightness, tall: false);
      return rig;
    }

    testScreenshot('openpgp card: the PGP keys row on the Security key sheet, $name', (tester) async {
      await open(tester, await twoKeys(tester));
      await takeScreenshot(tester, 'openpgp_card_row_$name');
    });

    testScreenshot('openpgp card: two keys and an empty place, $name', (tester) async {
      final rig = await open(tester, await twoKeys(tester));
      await openPgpKeys(rig);
      await takeScreenshot(tester, 'openpgp_card_sheet_$name');
    });

    for (final (label, tries) in [('three tries', 3), ('one try left', 1)]) {
      testScreenshot('openpgp card: the PIN sheet with $label, $name', (tester) async {
        final rig = await open(tester, await twoKeys(tester));
        await openPgpKeys(rig);
        final context = tester.element(find.byType(OpenPgpCardSheet));
        unawaited(showCardPinPrompt(context, pin: CardPin.pinToSign, triesLeft: tries));
        await tester.pumpAndSettle();
        await takeScreenshot(tester, 'openpgp_card_pin_${tries}_$name');
      });
    }

    testScreenshot('openpgp card: the Generate sheet, $name', (tester) async {
      final rig = await open(tester, FakeOpenPgpCard());
      await openPgpKeys(rig);
      final button = find.byKey(const ValueKey('openpgp-generate'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('card-generate-name')), 'Ada Lovelace');
      await tester.enterText(find.byKey(const ValueKey('card-generate-email')), 'ada@example.org');
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'openpgp_card_generate_$name');
    });

    testScreenshot('openpgp card: the Move sheet, $name', (tester) async {
      final key = VaultKey(
        id: 'k-move',
        name: 'Ada Lovelace',
        kind: KeyKind.pgp,
        algorithm: 'pgp',
        privateKey: b64(secret),
        publicKey: b64(File('test/fixtures/keys/gnupg/ed25519.public.gpg').readAsBytesSync()),
        origin: KeyOrigin.imported,
        addedAt: 0,
      );
      final rig = await open(tester, FakeOpenPgpCard(), vault: CardVault([key]));
      await openPgpKeys(rig);
      final button = find.byKey(const ValueKey('openpgp-move'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'openpgp_card_move_$name');
    });
  }
}
