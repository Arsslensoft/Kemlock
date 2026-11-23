import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/pgp/pgp_people.dart';
import 'package:kemlock/features/security_keys/card_pin_forms.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart';

/// The vault the card sheets see: its keys, as the real controller keeps
/// them, without storage.
class CardVault extends VaultController {
  CardVault([this.initial = const []]);

  final List<VaultKey> initial;

  /// The keys refused because the vault held them already.
  final List<VaultKey> refused = [];

  @override
  VaultState build() => VaultState(
    phase: VaultPhase.unlocked,
    keys: initial,
    vault: const VaultInfo(id: 'main'),
  );

  List<VaultKey> get keys => state.keys;

  @override
  Future<bool> addKey(VaultKey key) async {
    if (heldKey(key) != null) {
      refused.add(key);
      return false;
    }
    state = state.copyWith(keys: [...state.keys, key]);
    return true;
  }

  @override
  Future<bool> updateKey(VaultKey key) async {
    state = state.copyWith(keys: [for (final k in state.keys) k.id == key.id ? key : k]);
    return true;
  }
}

/// A key with [card] and a FIDO side, as a YubiKey has both.
FakeKey cardKey(FakeOpenPgpCard card, {bool fido = false}) => FakeKey(productName: 'Example Key', applets: [card], fido: fido);

/// The Security key sheet open, with [vault]'s keys, and [card] held to the phone over [kinds] once it is.
Future<(KeySheetRig, CardVault)> openWithCard(
  WidgetTester tester, {
  FakeOpenPgpCard? card,
  CardVault? vault,
  Set<SecurityKeyLinkKind> kinds = nfc,
  SecurityKeyCapabilities capabilities = FakeSecurityKeys.android,
  Brightness brightness = Brightness.dark,
  bool tall = true,
  List<Override> overrides = const [],
}) async {
  final cards = vault ?? CardVault();
  final rig = await openKeySheet(
    tester,
    capabilities: capabilities,
    brightness: brightness,
    tall: tall,
    overrides: [
      vaultControllerProvider.overrideWith(() => cards),
      pgpPublicKeyReaderProvider.overrideWithValue(pgp.readPgpPublicKey),
      ...overrides,
    ],
  );
  if (card != null) await rig.present(cardKey(card), kinds);
  return (rig, cards);
}

/// Opens the PGP keys sheet from its row.
Future<void> openPgpKeys(KeySheetRig rig) async {
  final row = find.byKey(const ValueKey('openpgp-row'));
  await rig.tester.ensureVisible(row);
  await rig.tester.pumpAndSettle();
  await rig.tester.tap(row);
  await rig.tester.pumpAndSettle();
}

/// The words of the row named by its key [key], or of its value.
String? rowValue(WidgetTester tester, String key) {
  final row = find.byKey(ValueKey(key));
  final texts = find.descendant(of: row, matching: find.byType(Text));
  return [for (final element in texts.evaluate()) (element.widget as Text).data ?? ''].join(' | ');
}

/// What a test reads in the sheet under [t].
String tr(String id, [Map<String, Object?> args = const {}]) => t(id, args);

/// Whether [finder] is a [GroupRow] someone can tap.
bool tappable(WidgetTester tester, Finder finder) => tester.widget<GroupRow>(finder).onTap != null;

/// Lets real async work (the key reading, the crypto) finish, then settles.
Future<void> settleReal(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }
}

/// Types [pin] into the card's PIN prompt on top and goes on.
Future<void> typeCardPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.descendant(of: find.byType(CardPinPrompt).last, matching: find.byType(TextField)), pin);
  await tester.pump();
  await tester.tap(find.descendant(of: find.byType(CardPinPrompt).last, matching: find.text(t('securityKeys.pin.continue'))));
  await settleReal(tester);
}
