import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/writer.dart' show generatePgpKey;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/key_widgets.dart' show KeyStandingTag;
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/test_app.dart';
import '../keys/keys_kit.dart';

// openspec: add-post-quantum-pgp, task 8.2: how the Vault tab lists the
// post-quantum PGP keys.

void main() {
  /// The vault with the keys of [files] (under test/fixtures/keys), each
  /// listed by its title, on the Vault tab.
  Future<KeysApp> withKeys(WidgetTester tester, Map<String, Object> keys) async {
    final app = KeysApp(tester);
    await app.start();
    var i = 0;
    for (final MapEntry(key: title, value: source) in keys.entries) {
      final parsed = await tester.runAsync(
        () => crypto.readPrivateKey(source is String ? keyFixture(source).readAsBytesSync() : source as Uint8List),
      );
      await app.app.container
          .read(vaultControllerProvider.notifier)
          .addKey(vaultKeyOf(parsed!, id: 'k${i++}', name: title, origin: KeyOrigin.imported));
    }
    await tester.pump(const Duration(seconds: 10));
    await app.settle();
    // The Keys filter, whose PGP rows show the line under the name
    await app.tap(find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t('vault.filter.keys'))));
    return app;
  }

  Finder row(String title) => find.ancestor(of: find.text(title), matching: find.byType(GroupRow));
  Finder inRow(String title, Finder finder) => find.descendant(of: row(title), matching: finder);

  testWidgets('a standard key shows ML-KEM-768 + X25519 and a v6 tag; a GnuPG one its Kyber and no tag; an Ed25519 one neither', (
    tester,
  ) async {
    await withKeys(tester, {
      'Ada, post-quantum': 'kemlock/pgp-pq-standard.unprotected.asc',
      'Ada, for GnuPG': 'kemlock/pgp-pq-gnupg.unprotected.asc',
      'Ada Lovelace': 'kemlock/pgp-ed25519.unprotected.asc',
    });
    expect(inRow('Ada, post-quantum', find.textContaining('ML-KEM-768 + X25519')), findsOneWidget);
    expect(inRow('Ada, post-quantum', find.byKey(const ValueKey('v6'))), findsOneWidget);
    expect(inRow('Ada, post-quantum', find.text('V6')), findsOneWidget);
    expect(inRow('Ada, for GnuPG', find.textContaining('Kyber-768 + X25519')), findsOneWidget);
    expect(inRow('Ada, for GnuPG', find.byKey(const ValueKey('v6'))), findsNothing);
    expect(inRow('Ada Lovelace', find.textContaining('Ed25519')), findsOneWidget);
    expect(inRow('Ada Lovelace', find.byKey(const ValueKey('v6'))), findsNothing);
  });

  testWidgets('a search for "post-quantum" finds both post-quantum keys and not the Ed25519 one', (tester) async {
    await withKeys(tester, {
      'Ada, post-quantum': 'kemlock/pgp-pq-standard.unprotected.asc',
      'Ada, for GnuPG': 'kemlock/pgp-pq-gnupg.unprotected.asc',
      'Ada Lovelace': 'kemlock/pgp-ed25519.unprotected.asc',
    });
    await tester.enterText(find.descendant(of: find.byType(SearchField), matching: find.byType(TextField)), 'post-quantum');
    await tester.pumpAndSettle();
    expect(row('Ada, post-quantum'), findsOneWidget);
    expect(row('Ada, for GnuPG'), findsOneWidget);
    expect(row('Ada Lovelace'), findsNothing);
  });

  testWidgets('the v6 tag sits beside the tag of a key that expires soon', (tester) async {
    // A standard key made 360 days before the test's clock that expires a
    // year after it was made
    final now = testNow;
    final secret = await tester.runAsync(
      () => generatePgpKey(
        userId: 'Soon <soon@example.org>',
        type: crypto.PgpKeyType.pqStandard,
        created: now.subtract(const Duration(days: 360)),
        expirySeconds: 365 * 24 * 3600,
      ),
    );
    await withKeys(tester, {'Soon': secret!});
    expect(inRow('Soon', find.byKey(const ValueKey('v6'))), findsOneWidget);
    expect(inRow('Soon', find.byType(KeyStandingTag)), findsOneWidget);
  });
}
