// The subkey sheet (openspec: add-pgp-key-editing, design decision 10),
// with a generator the test finishes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_sheet.dart';
import 'package:kemlock/features/keys/key_subkey_sheet.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/test_app.dart';
import 'keys_kit.dart';

const _key = 'gnupg/editing/signing-subkey.secret.asc';

void main() {
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(KeySubkeySheet), matching: finder);
  Finder add() => inSheet(find.text(t('keys.change.subkey.add')));
  crypto.AddPgpSubkey requested(KeysApp keys) => (keys.changes.last.request as crypto.PgpChangeRequest).change as crypto.AddPgpSubkey;

  Future<KeysApp> open(WidgetTester tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    await keys.openChange('keys.change.addSubkey');
    return keys;
  }

  testWidgets('the default type for each use: Curve25519 to encrypt, Ed25519 to sign, never expiring', (tester) async {
    final keys = await open(tester);

    expect(inSheet(find.text(t('keys.change.subkey.curve25519'))), findsOneWidget);
    expect(inSheet(find.text(t('keys.change.expiry.neverBody'))), findsOneWidget);
    await keys.tap(inSheet(find.text(t('keys.change.subkey.sign'))));
    expect(inSheet(find.text(t('keys.change.subkey.ed25519'))), findsOneWidget);

    await keys.tap(add());
    final asked = requested(keys);
    expect((asked.type, asked.use, asked.expires), (crypto.PgpKeyType.ed25519, crypto.PgpSubkeyUse.sign, null));
    await keys.tap(inSheet(find.text(t('keys.generate.cancel'))));
  });

  testWidgets('while it is made the sheet says so, and Cancel adds nothing', (tester) async {
    final keys = await open(tester);
    final before = keys.key('k1');

    await keys.tap(add());
    expect(inSheet(find.text(t('keys.change.subkey.working'))), findsOneWidget);
    expect(add(), findsNothing);

    await keys.tap(inSheet(find.text(t('keys.generate.cancel'))));
    expect(keys.changes.single.cancelled, isTrue);
    expect(inSheet(find.text(t('keys.change.subkey.working'))), findsNothing);
    expect(find.byType(KeySubkeySheet), findsOneWidget);
    expect(keys.key('k1'), before);
  });

  testWidgets('a vault that locks while the subkey is made gets none of it', (tester) async {
    final keys = await open(tester);
    final stored = keys.app.store.getItem('backmycodes_key_data');
    expect(stored, isNotNull);

    await keys.tap(add());
    keys.app.container.read(vaultControllerProvider.notifier).lock();
    await tester.pump();
    // Had it finished anyway, nothing would be saved
    await tester.runAsync(keys.changes.single.finish);
    await keys.settle();

    expect(keys.changes.single.cancelled, isTrue);
    expect(keys.app.container.read(vaultControllerProvider).keys, isEmpty);
    expect(keys.app.store.getItem('backmycodes_key_data'), stored);
  });

  testWidgets("the new subkey's line appears in the key sheet", (tester) async {
    final keys = await open(tester);
    expect(find.byKey(const ValueKey('subkey-2')), findsNothing);

    await keys.tap(add());
    await keys.finishChange();

    expect(find.byType(KeySubkeySheet), findsNothing);
    expect(find.text(t('keys.change.done.subkey')), findsOneWidget);
    expect(crypto.readPgpKeyInfo(unb64(keys.key('k1').publicKey!)).subkeys, hasLength(3));
    expect(find.descendant(of: find.byType(KeySheet), matching: find.byKey(const ValueKey('subkey-2'))), findsOneWidget);
  });

  // openspec: add-post-quantum-pgp, task 9.2
  group('the post-quantum subkeys', () {
    Finder readers() => inSheet(find.byKey(const ValueKey('subkey-readers')));

    /// Picks [message] in the type's menu, which shows the type chosen.
    Future<void> pick(KeysApp keys, String shown, String message) async {
      await keys.tap(inSheet(find.text(t(shown))));
      await keys.tap(find.text(t(message)).last);
    }

    testWidgets('a version 4 key offers both to encrypt, each saying who reads it, and neither to sign', (tester) async {
      final keys = await open(tester);
      expect(readers(), findsNothing);

      await pick(keys, 'keys.change.subkey.curve25519', 'keys.change.subkey.pqStandard');
      expect(inSheet(find.text(t('keys.change.subkey.readers.standard'))), findsOneWidget);
      await keys.tap(add());
      expect((requested(keys).type, requested(keys).use), (crypto.PgpKeyType.pqStandard, crypto.PgpSubkeyUse.encrypt));
      await keys.tap(inSheet(find.text(t('keys.generate.cancel'))));

      await pick(keys, 'keys.change.subkey.pqStandard', 'keys.change.subkey.pqGnupg');
      expect(inSheet(find.text(t('keys.change.subkey.readers.gnupg'))), findsOneWidget);
      await keys.tap(add());
      expect(requested(keys).type, crypto.PgpKeyType.pqGnupg);
      await keys.tap(inSheet(find.text(t('keys.generate.cancel'))));

      // To sign: Ed25519 again, and no post-quantum choice
      await keys.tap(inSheet(find.text(t('keys.change.subkey.sign'))));
      expect(inSheet(find.text(t('keys.change.subkey.ed25519'))), findsOneWidget);
      expect(readers(), findsNothing);
      await keys.tap(inSheet(find.text(t('keys.change.subkey.ed25519'))));
      expect(find.text(t('keys.change.subkey.pqStandard')), findsNothing);
      expect(find.text(t('keys.change.subkey.pqGnupg')), findsNothing);
    });

    testWidgets('a version 6 key offers its own kind alone: ML-KEM-768 to encrypt, ML-DSA-65 to sign', (tester) async {
      final keys = KeysApp(tester);
      await keys.openPgpKey('kemlock/pgp-pq-standard.unprotected.asc');
      await keys.openChange('keys.change.addSubkey');

      expect(inSheet(find.text(t('keys.change.subkey.pqStandard'))), findsOneWidget);
      expect(readers(), findsNothing);
      await keys.tap(inSheet(find.text(t('keys.change.subkey.pqStandard'))));
      expect(find.text(t('keys.change.subkey.curve25519')), findsNothing);
      expect(find.text(t('keys.change.subkey.pqGnupg')), findsNothing);
      await keys.tap(find.text(t('keys.change.subkey.pqStandard')).last);

      await keys.tap(inSheet(find.text(t('keys.change.subkey.sign'))));
      expect(inSheet(find.text(t('keys.change.subkey.mlDsa'))), findsOneWidget);
      await keys.tap(add());
      expect((requested(keys).type, requested(keys).use), (crypto.PgpKeyType.pqStandard, crypto.PgpSubkeyUse.sign));
      await keys.tap(inSheet(find.text(t('keys.generate.cancel'))));
    });

    testWidgets('a Kyber subkey added is listed in the key sheet by its name', (tester) async {
      final keys = await open(tester);
      await pick(keys, 'keys.change.subkey.curve25519', 'keys.change.subkey.pqGnupg');
      await keys.tap(add());
      await keys.finishChange();

      expect(find.text(t('keys.change.done.subkey')), findsOneWidget);
      expect(crypto.readPgpKeyInfo(unb64(keys.key('k1').publicKey!)).subkeys.last.algorithm, 'ky768_cv25519');
      expect(find.descendant(of: find.byType(KeySheet), matching: find.textContaining('Kyber-768 + X25519')), findsOneWidget);
    });
  });
}
