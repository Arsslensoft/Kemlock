import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/card_keys.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/autofill.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../fakes/fake_autofill.dart';
import '../features/backup/backup_test_kit.dart' show realDirectory;
import '../features/contacts/contacts_kit.dart';
import '../features/keys/expiry_kit.dart';
import '../flows/flow_kit.dart' show tab, tapOn;
import '../helpers/app_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// The Vault tab and its sheets, and AutoFill's passkeys, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/vault_test.dart
void main() {
  final png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

  /// The vault with one of each kind in it, an expired and a revoked PGP key
  /// and two of other people's keys
  /// among them; at [now], which the key expiring in 2095 is tagged against.
  Future<TestApp> vault(WidgetTester tester, Brightness brightness, {DateTime? now}) async {
    usePhoneScreen(tester);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final app = TestApp(
      now: now == null ? null : () => now,
      autofill: FakeAutofill(current: const AutofillStatus(supported: true, enabled: true, biometrics: true))
        ..passkeys = const PasskeyStatus(supported: true, enabled: true),
    );
    await tester.runAsync(() => app.createVault('pw'));
    await app.pump(tester, overrides: [realDirectory]);
    await app.unlock(tester, 'pw');
    final controller = app.controller;
    final key = await tester.runAsync(() => crypto.readPrivateKey(File('test/fixtures/keys/openssh/ed25519').readAsBytesSync()));
    // The "Ada, post-quantum" row of Main.dc.html (add-post-quantum-pgp)
    final postQuantum = await tester.runAsync(
      () => crypto.readPrivateKey(File('test/fixtures/keys/kemlock/pgp-pq-standard.unprotected.asc').readAsStringSync()),
    );
    await tester.runAsync(() async {
      await controller.addKey(vaultKeyOf(key!, id: 'k1', name: 'laptop', origin: KeyOrigin.generated));
      await controller.addKey(await expiryFixtureKey('future', title: 'Ada Lovelace'));
      await controller.addKey(await expiryFixtureKey('expired', title: 'Travel key'));
      await controller.addKey(await expiryFixtureKey('revoked', title: 'Old work key'));
      await controller.addKey(vaultKeyOf(postQuantum!, id: 'k-pq', name: 'Ada, post-quantum', origin: KeyOrigin.generated));
      // A key whose private half is on a security key (openspec: add-openpgp-card)
      await controller.addKey(
        VaultKey(
          id: 'k-card',
          name: 'Signing key',
          kind: KeyKind.pgp,
          algorithm: 'pgp',
          privateKey: b64(File('test/fixtures/keys/gnupg/card/stub-ed25519.gpg').readAsBytesSync()),
          publicKey: b64(File('test/fixtures/keys/gnupg/ed25519.public.gpg').readAsBytesSync()),
          origin: KeyOrigin.imported,
          protected: true,
          addedAt: 0,
          card: cardObject('D276000124010304FFFF123456780000', {
            CardPlace.signature: '1FCDA135EE42400EC2B77CE677249ABE661CF8DB',
            CardPlace.decryption: '4BA83174FC8CE762A23BF0A4841A40E3B199EA67',
          }),
        ),
      );
      // Other people's keys: one checked on 3 November, one never checked
      await controller.addContact(contactOf(grace1, checkedAt: DateTime(2026, 11, 3, 9).millisecondsSinceEpoch));
      await controller.addContact(contactOf(alan, id: 'c2', name: 'Alan Turing'));
      final fileKey = randomBytes(32);
      await app.attachments.write(app.state.vault.id, 'pic', png, fileKey);
      await controller.addNote(
        SecureNote(
          id: 'n1',
          title: 'Passport',
          text: 'In the drawer, left side.\nExpires March 2031.',
          pinned: true,
          addedAt: 0,
          attachments: [
            NoteAttachment(id: 'pic', name: 'passport.png', size: png.length, type: 'image/png', key: b64(fileKey), addedAt: 0),
            NoteAttachment(id: 'pdf', name: 'visa.pdf', size: 482113, type: 'application/pdf', key: b64(randomBytes(32)), addedAt: 0),
          ],
        ),
      );
      await controller.addNote(const SecureNote(id: 'n2', title: 'Wi-Fi at home', text: 'kemlock-guest / correct horse', addedAt: 0));
      await controller.addPasskeys(const [
        Passkey(
          id: 'p1',
          credentialId: 'AAECAwQFBgcICQoLDA0ODw',
          rpId: 'github.com',
          rpName: 'GitHub',
          userHandle: 'dXNlcg',
          userName: 'octocat@example.com',
          privateKey: 'AA==',
          addedAt: 1763200000000,
        ),
      ]);
    });
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tapOn(tester, tab('nav.vault'));
    return app;
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('vault: the Vault tab, $name', (tester) async {
      await vault(tester, brightness);
      await takeScreenshot(tester, 'vault_tab_$name');
    });

    testScreenshot('vault: the Keys filter a week before a key expires, $name', (tester) async {
      await vault(tester, brightness, now: futureExpiry.subtract(const Duration(days: 7)));
      await tapOn(tester, find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t('vault.filter.keys'))));
      await takeScreenshot(tester, 'vault_keys_$name');
    });

    testScreenshot('vault: an expired PGP key, $name', (tester) async {
      await vault(tester, brightness);
      await tapOn(tester, find.text('Travel key'));
      await takeScreenshot(tester, 'vault_key_expired_$name');
    });

    testScreenshot('vault: a PGP key on a security key, $name', (tester) async {
      await vault(tester, brightness);
      await tapOn(tester, find.text('Signing key'));
      await takeScreenshot(tester, 'vault_key_card_$name');
    });

    testScreenshot('vault: add to vault, $name', (tester) async {
      await vault(tester, brightness);
      await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
      await takeScreenshot(tester, 'vault_add_$name');
    });

    testScreenshot('vault: a note with files, $name', (tester) async {
      final app = await vault(tester, brightness);
      app.container.read(routerProvider).go('/vault/notes/n1');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await takeScreenshot(tester, 'vault_note_$name');
    });

    testScreenshot('vault: a key, $name', (tester) async {
      await vault(tester, brightness);
      await tapOn(tester, find.text('laptop'));
      await takeScreenshot(tester, 'vault_key_$name');
    });

    testScreenshot('vault: generate a key, $name', (tester) async {
      await vault(tester, brightness);
      await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
      await tapOn(tester, find.text(t('vault.add.generateKey')));
      await takeScreenshot(tester, 'vault_generate_$name');
    });

    testScreenshot('vault: a passkey, $name', (tester) async {
      await vault(tester, brightness);
      await tapOn(tester, find.text('GitHub'));
      await takeScreenshot(tester, 'vault_passkey_$name');
    });

    testScreenshot('vault: AutoFill with passkeys, $name', (tester) async {
      final app = await vault(tester, brightness);
      app.container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();
      await tapOn(tester, find.widgetWithText(GroupRow, t('settings.autofill')));
      await tester.runAsync(() => app.controller.passkeyInbox(create: true));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final toggle = find.descendant(of: find.widgetWithText(GroupRow, t('autofill.passkeys')), matching: find.byType(Switch));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'vault_autofill_passkeys_$name');
    });
  }
}
