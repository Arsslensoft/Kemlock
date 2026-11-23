import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' show readPrivateKey;
import 'package:kemlock/crypto/keys/pkcs8.dart';
import 'package:kemlock/crypto/keys/sshsig.dart';
import 'package:kemlock/features/keys/generate_key_sheet.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/sign_sheet.dart';
import 'package:kemlock/features/keys/verify_sheet.dart';
import 'package:kemlock/features/lock/unlock_method_sheet.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../fakes/fake_files.dart';
import '../fakes/fake_security_keys.dart';
import '../features/keys/ssh_kit.dart' show sshFixtureKey, sshsigFile;
import '../features/lock/key_phone.dart';
import '../features/lock/lock_phone.dart' show SheetOpener;
import '../flows/flow_kit.dart' show tab, tapOn;
import '../helpers/app_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';
import '../vault/rotation_helpers.dart' show newKit;

/// Renders the bottom sheet and the dialogs over a page, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/sheets_test.dart
void main() {
  /// The Keys filter of a vault holding [keys], with SSH signatures made and
  /// checked on this isolate.
  Future<FakeFiles> keysFilter(WidgetTester tester, Brightness brightness, {List<String> keys = const ['ed25519']}) async {
    usePhoneScreen(tester);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final app = TestApp();
    final files = FakeFiles();
    await tester.runAsync(() => app.createVault('pw'));
    await app.pump(
      tester,
      overrides: [
        files.asOverride,
        sshSignerProvider.overrideWithValue((pkcs8, namespace, message) async => sshsigSign(await readPkcs8(pkcs8), namespace, message)),
        sshCheckerProvider.overrideWithValue(sshCheck),
      ],
    );
    await app.unlock(tester, 'pw');
    await tester.runAsync(() async {
      for (final key in keys) {
        await app.controller.addKey(await sshFixtureKey(key, title: key == 'ed25519' ? 'laptop' : key));
      }
      // A vault with no key still needs something in it to show its filters
      if (keys.isEmpty) {
        await app.controller.addKey(
          const VaultKey(
            id: 'x',
            name: 'age key',
            kind: KeyKind.other,
            algorithm: '1.3.101.110',
            privateKey: 'AA==',
            origin: KeyOrigin.imported,
            addedAt: 0,
          ),
        );
      }
    });
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t('vault.filter.keys'))));
    // The toast of the added key would sit over the sheet
    app.container.read(toastsProvider.notifier).dismiss();
    await tester.pumpAndSettle();
    return files;
  }

  Future<void> act(WidgetTester tester, Finder finder) async {
    await tapOn(tester, finder);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pumpAndSettle();
  }

  /// The Keys filter of a vault holding GnuPG's key with a signing subkey
  /// (openspec: add-pgp-key-editing), its sheet open at its "Change this
  /// key" section.
  Future<void> pgpKeySheet(WidgetTester tester, Brightness brightness) async {
    usePhoneScreen(tester);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final app = TestApp();
    await tester.runAsync(() => app.createVault('pw'));
    await app.pump(tester);
    await app.unlock(tester, 'pw');
    final parsed = await tester.runAsync(
      () => readPrivateKey(File('test/fixtures/keys/gnupg/editing/signing-subkey.secret.asc').readAsStringSync()),
    );
    // Added outside runAsync, so that its toast times out in the pumps below
    await app.controller.addKey(vaultKeyOf(parsed!, id: 'k1', name: 'Fixture Signing', origin: KeyOrigin.imported));
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t('vault.filter.keys'))));
    app.container.read(toastsProvider.notifier).dismiss();
    await tester.pumpAndSettle();
    await act(tester, find.text('Fixture Signing').first);
    await tester.ensureVisible(find.byKey(const ValueKey('key-change')));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('sheets: the "Change this key" section of a PGP key, $name', (tester) async {
      await pgpKeySheet(tester, brightness);
      await takeScreenshot(tester, 'sheets_pgp_change_$name');
    });

    for (final (shot, row) in [
      ('expiry', 'keys.change.expiry'),
      ('user_id', 'keys.change.addUserId'),
      ('subkey', 'keys.change.addSubkey'),
      ('revoke', 'keys.change.revoke'),
    ]) {
      testScreenshot('sheets: change a PGP key, $shot, $name', (tester) async {
        await pgpKeySheet(tester, brightness);
        await act(tester, find.descendant(of: find.byKey(const ValueKey('key-change')), matching: find.text(t(row))));
        await takeScreenshot(tester, 'sheets_pgp_${shot}_$name');
      });
    }

    testScreenshot('sheets: sign with an SSH key, $name', (tester) async {
      await keysFilter(tester, brightness);
      await act(tester, find.text('laptop'));
      await act(tester, find.text(t('keys.sign.action')));
      await takeScreenshot(tester, 'sheets_ssh_sign_$name');
    });

    testScreenshot('sheets: a file signed with an SSH key, $name', (tester) async {
      final files = await keysFilter(tester, brightness);
      await act(tester, find.text('laptop'));
      await act(tester, find.text(t('keys.sign.action')));
      files.nextPick = FakeFiles.text('release-notes.txt', 'hello');
      await act(tester, find.text(t('keys.sign.chooseFile')));
      await act(tester, find.byKey(const ValueKey('sign-submit')));
      await tester.ensureVisible(find.byKey(const ValueKey('signature')));
      await takeScreenshot(tester, 'sheets_ssh_signed_$name');
    });

    for (final (shot, message) in [('good_unknown', 'hello'), ('bad', 'hellp')]) {
      testScreenshot('sheets: verify an SSH signature, $shot, $name', (tester) async {
        final files = await keysFilter(tester, brightness, keys: const []);
        await act(tester, find.text(t('keys.verify.entry')));
        await tester.enterText(
          find.widgetWithText(TextField, t('keys.verify.signature')),
          sshsigFile('ed25519-file-hello.txt.sig').readAsStringSync(),
        );
        files.nextPick = FakeFiles.text('release-notes.txt', message);
        await act(tester, find.byKey(const ValueKey('verify-file')));
        await act(tester, find.byKey(const ValueKey('verify-submit')));
        await tester.ensureVisible(find.byKey(const ValueKey('verify-result')));
        await takeScreenshot(tester, 'sheets_ssh_verify_${shot}_$name');
      });
    }

    // openspec: add-post-quantum-pgp, task 7.4: Generate.dc.html
    testScreenshot('sheets: generate a PGP key, $name', (tester) async {
      await keysFilter(tester, brightness);
      await act(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
      await act(tester, find.text(t('vault.add.generateKey')));
      await act(tester, find.text(t('keys.generate.kind.pgp')));
      await tester.enterText(find.widgetWithText(TextField, t('keys.generate.pgp.name')), 'Ada Lovelace');
      await tester.enterText(find.widgetWithText(TextField, t('keys.generate.pgp.email')), 'ada@example.org');
      FocusManager.instance.primaryFocus?.unfocus();
      // The toast of the added key goes, and the sheet shows from its top, as the mockup does
      ToastHost.of(tester.element(find.byType(GenerateKeySheet))).hide();
      await tester.pumpAndSettle();
      await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, 2000));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'sheets_generate_pgp_$name');
    });

    // openspec: add-post-quantum-pgp, task 8.5: the sheet of each new key type
    for (final (shot, path, title) in [
      ('standard', 'kemlock/pgp-pq-standard.unprotected.asc', 'Ada, post-quantum'),
      ('gnupg', 'kemlock/pgp-pq-gnupg.unprotected.asc', 'Ada, for GnuPG'),
    ]) {
      testScreenshot('sheets: a post-quantum PGP key, $shot, $name', (tester) async {
        await keysFilter(tester, brightness);
        final container = ProviderScope.containerOf(tester.element(find.byType(SegmentedControl<VaultFilter>)));
        await tester.runAsync(() async {
          final parsed = await readPrivateKey(File('test/fixtures/keys/$path').readAsStringSync());
          await container
              .read(vaultControllerProvider.notifier)
              .addKey(vaultKeyOf(parsed, id: 'pq', name: title, origin: KeyOrigin.generated));
        });
        await tester.pump(const Duration(seconds: 10));
        // The toast of the added key, shown from a real timer, would sit over the sheet
        ToastHost.of(tester.element(find.byType(SegmentedControl<VaultFilter>))).hide();
        await tester.pumpAndSettle();
        await act(tester, find.text(title));
        await takeScreenshot(tester, 'sheets_pgp_pq_${shot}_$name');
      });
    }

    testScreenshot('sheets: bottom sheet, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpScreen(tester, brightness: brightness, const _Page());
      final context = tester.element(find.byType(_Page));
      unawaited(showAppBottomSheet<void>(context, label: 'GitHub', builder: (context) => const _SheetBody()));
      await takeScreenshot(tester, 'sheets_bottom_sheet_$name');
    });

    testScreenshot('sheets: confirm dialog, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpScreen(tester, brightness: brightness, const _Page());
      final context = tester.element(find.byType(_Page));
      unawaited(
        showConfirmDialog(
          context,
          icon: const Icon(Icons.delete_outline_rounded),
          title: 'Delete GitHub?',
          body: const Text('Its codes stop being generated on this phone. Make sure you can still sign in another way.'),
          confirmLabel: 'Delete',
          cancelLabel: 'Cancel',
        ),
      );
      await takeScreenshot(tester, 'sheets_confirm_danger_$name');
    });

    testScreenshot('sheets: plain dialog, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpScreen(tester, brightness: brightness, const _Page());
      final context = tester.element(find.byType(_Page));
      unawaited(
        showConfirmDialog(
          context,
          title: 'Lock the vault?',
          body: const Text('You will need your password to see your codes again.'),
          confirmLabel: 'Lock',
          cancelLabel: 'Cancel',
          danger: false,
        ),
      );
      await takeScreenshot(tester, 'sheets_confirm_plain_$name');
    });

    // openspec: add-security-key-unlock, task 6.11
    /// "How this vault opens" over a page, for a vault with a kit and [keys]
    /// keys enrolled, as what a key gave; no key is needed.
    Future<void> unlockMethod(WidgetTester tester, {int keys = 0}) async {
      usePhoneScreen(tester);
      // An iPhone once the exchange is proven there, as the mockup draws it
      final phone = KeyPhone(reach: FakeSecurityKeys.iphone, iPhoneProven: true).phone;
      final session = await phone.createVault(tester, 'secret');
      await tester.runAsync(() async {
        final store = phone.vaultStore;
        await store.setRecoveryKey(session, newKit());
        var proof = await store.proveOwner(password: 'secret');
        for (final keyName in ['YubiKey 5C NFC', 'Spare key'].take(keys)) {
          proof = await store.enrolKey(
            session,
            proof,
            salt: store.keyChallenge().salt,
            credential: randomBytes(64),
            output: randomBytes(32),
            name: keyName,
            pinBound: true,
          );
        }
      });
      await phone.pump(tester, const SheetOpener(showUnlockMethodSheet), brightness: brightness, reducedMotion: false);
      await phone.controller.open(session);
      await tester.tap(find.text('Open'));
      await settleForScreenshot(tester);
    }

    testScreenshot('sheets: how this vault opens, password and security key chosen, $name', (tester) async {
      await unlockMethod(tester);
      await tester.tap(find.text(t('unlockMethod.mode.both')));
      await takeScreenshot(tester, 'sheets_unlock_method_$name');
    });

    testScreenshot('sheets: how this vault opens, with two keys, $name', (tester) async {
      await unlockMethod(tester, keys: 2);
      await tester.drag(find.byType(UnlockMethodSheet), const Offset(0, -400));
      await takeScreenshot(tester, 'sheets_unlock_method_keys_$name');
    });
  }
}

/// A page with something on it, to see the scrim and the blur over.
class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => ScreenshotBoard(
    title: 'Codes',
    children: [
      for (final (issuer, code) in [('GitHub', '492018'), ('Google', '730155'), ('Proton', '118342'), ('Bitwarden', '904611')])
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: GroupCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(child: Text(issuer, style: AppType.h6)),
                  CodeDigits(code: code, style: const TextStyle(fontSize: 22)),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'GitHub',
          textAlign: TextAlign.center,
          style: AppType.h4.copyWith(color: context.palette.text),
        ),
        Text(
          'octocat@github.com',
          textAlign: TextAlign.center,
          style: AppType.body2.copyWith(color: context.palette.textSecondary),
        ),
        const SizedBox(height: 24),
        const Center(
          child: CodeDigits(code: '492018', style: TextStyle(fontSize: 52)),
        ),
        const SizedBox(height: 24),
        FilledButton(style: largeButtonStyle, onPressed: () {}, child: const Text('Copy code')),
      ],
    ),
  );
}
