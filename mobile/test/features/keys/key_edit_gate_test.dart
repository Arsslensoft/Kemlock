// What a change to a PGP key goes through first (openspec:
// add-pgp-key-editing, design decision 11): biometrics when the vault has
// them, then the key's own passphrase, asked for at each change.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/pgp_error.dart';
import 'package:kemlock/features/keys/key_edit_gate.dart';
import 'package:kemlock/features/keys/key_expiry_sheet.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/old_biometric_entry.dart';
import '../../helpers/test_app.dart';
import 'keys_kit.dart';

const _protected = 'gnupg/editing/protected.secret.asc';
const _unprotected = 'kemlock/pgp-ed25519.unprotected.asc';

void main() {
  /// Opens the expiry sheet of the key in the sheet and taps Save.
  Future<void> saveExpiry(KeysApp keys) async {
    await keys.openChange('keys.change.expiry');
    await keys.tap(find.descendant(of: find.byType(KeyExpirySheet), matching: find.text(t('keys.change.expiry.save'))));
  }

  Finder passphraseDialog() => find.byType(PgpPassphraseDialog);

  testWidgets('refused biometrics stop the change before anything is asked or made', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_protected);
    await writeOldBiometricEntry(keys.app.store, keys.app.vaults, keys.app.container.read(vaultControllerProvider).session!);
    keys.app.biometrics.passes = false;

    await saveExpiry(keys);

    expect(keys.app.biometrics.prompts, [t('keys.change.biometric')]);
    expect(passphraseDialog(), findsNothing);
    expect(keys.changes, isEmpty);
  });

  testWidgets('a key without its own passphrase asks for nothing more, the vault without biometrics for nothing at all', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_unprotected);

    await saveExpiry(keys);

    expect(keys.app.biometrics.prompts, isEmpty);
    expect(passphraseDialog(), findsNothing);
    expect(keys.changes.single.request, isA<crypto.PgpChangeRequest>().having((r) => r.passphrase, 'passphrase', isNull));
  });

  testWidgets('a wrong passphrase says so under the field and keeps the dialog open; the right one goes on', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_protected);

    await saveExpiry(keys);
    expect(passphraseDialog(), findsOneWidget);
    expect(find.text(t('keys.change.passphrase.title', {'name': 'Ada'})), findsWidgets);

    await tester.enterText(find.descendant(of: passphraseDialog(), matching: find.byType(TextField)), 'not it');
    await keys.tap(find.text(t('keys.change.passphrase.continue')));
    expect(find.text(t('keys.change.passphrase.wrong')), findsOneWidget);
    expect(passphraseDialog(), findsOneWidget);
    expect(keys.changes, isEmpty);

    await tester.enterText(find.descendant(of: passphraseDialog(), matching: find.byType(TextField)), 'fixture passphrase');
    await keys.tap(find.text(t('keys.change.passphrase.continue')));
    expect(passphraseDialog(), findsNothing);
    expect((keys.changes.single.request as crypto.PgpChangeRequest).passphrase, 'fixture passphrase');
  });

  testWidgets('a protection Kemlock does not open is named, and nothing is made', (tester) async {
    final keys = KeysApp(tester)..openerThrows = const PgpException(PgpProblem.unsupported, detail: 'CAST5');
    await keys.openPgpKey(_protected);

    await saveExpiry(keys);
    await tester.enterText(find.descendant(of: passphraseDialog(), matching: find.byType(TextField)), 'fixture passphrase');
    await keys.tap(find.text(t('keys.change.passphrase.continue')));

    expect(find.text(t('keys.change.passphrase.unsupported', {'name': 'CAST5'})), findsOneWidget);
    expect(keys.changes, isEmpty);
  });

  testWidgets('a second change asks for the passphrase again', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_protected);

    await saveExpiry(keys);
    await tester.enterText(find.descendant(of: passphraseDialog(), matching: find.byType(TextField)), 'fixture passphrase');
    await keys.tap(find.text(t('keys.change.passphrase.continue')));
    await keys.finishChange();
    expect(keys.key('k1').updatedAt, isNotNull, reason: 'the first change was saved');

    await saveExpiry(keys);
    expect(passphraseDialog(), findsOneWidget);
  });
}
