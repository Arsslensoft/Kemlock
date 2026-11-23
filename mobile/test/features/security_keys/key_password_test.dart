// The password of a key's code application: asked for, proved,
// remembered on this phone only, and set, changed and removed (openspec:
// add-security-key-codes, tasks 5.1 and 5.2).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/features/security_keys/key_codes_flow.dart';
import 'package:kemlock/features/security_keys/key_codes_sheet.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/qr_transfer.dart';
import 'package:kemlock/vault/vault_export.dart';

import '../../fakes/fake_oath_key.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import 'key_codes_harness.dart';

const _device = '0102030405060708';
// SELECT is answered by the fake key itself, and not counted; 0xa4 is CALCULATE ALL.
const _calculateAll = 0xa4;
const _validate = 0xa3;
const _list = 0xa1;

int _count(FakeOathKey oath, int ins) => oath.received.where((received) => received == ins).length;

/// A real vault on a fake phone, a key with a password, and a screen with
/// "read" on it that reads the key as the Codes tab does.
Future<CodesRig> _open(WidgetTester tester, {String? password = 'correct horse'}) async {
  useReducedMotion(tester);
  final rig = (await tester.runAsync(
    () => CodesRig.open(
      oath: FakeOathKey(password: password, accounts: usualAccounts()),
    ),
  ))!;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: rig.container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        localizationsDelegates: localizationsDelegates(testCatalog),
        supportedLocales: supportedLocales,
        builder: (context, child) => ToastHost(child: child!),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: TextButton(onPressed: () => readKeyCodes(context, ref), child: const Text('read')),
            ),
          ),
        ),
      ),
    ),
  );
  rig.present();
  return rig;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Types [password] in the password dialog, ticks "Remember on this phone"
/// when [remember], and continues.
Future<void> _typePassword(WidgetTester tester, String password, {bool remember = false}) async {
  await tester.enterText(find.byType(TextField), password);
  await tester.pump();
  if (remember) await _tap(tester, find.text(t('keyCodes.password.remember')));
  await _tap(tester, find.text(t('keyCodes.password.continue')));
}

Future<Uint8List?> _remembered(WidgetTester tester, CodesRig rig) => tester.runAsync<Uint8List?>(() => rig.vault.keyAccess(_device));

/// Takes the screen away, so no timer of the fake phone outlives the test.
Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  group('reading a key that has a password', () {
    testWidgets('an unknown password is asked for after the first exchange and proved on the second', (tester) async {
      final rig = await _open(tester);

      await _tap(tester, find.text('read'));

      expect(find.text(t('keyCodes.password.title')), findsWidgets);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse, reason: 'not remembered unless asked');
      expect(
        (_count(rig.oath, _validate), _count(rig.oath, _list), _count(rig.oath, _calculateAll)),
        (0, 0, 0),
        reason: 'nothing after the selection',
      );

      await _typePassword(tester, 'correct horse');

      expect((_count(rig.oath, _validate), _count(rig.oath, _list), _count(rig.oath, _calculateAll)), (1, 1, 2));
      expect(rig.vaultState.keyAccounts, hasLength(4));
      expect(await _remembered(tester, rig), isNull);
      await _leave(tester);
    });

    testWidgets('a wrong password is said plainly, and nothing is listed', (tester) async {
      final rig = await _open(tester);

      await _tap(tester, find.text('read'));
      await _typePassword(tester, 'battery staple');

      expect(find.text(t('keyCodes.password.wrong')), findsOneWidget);
      expect(_count(rig.oath, _list), 0);
      expect(rig.vaultState.keyAccounts, isEmpty);
      await _tap(tester, find.text(t('export.cancel')));
      await _leave(tester);
    });

    testWidgets('a remembered password reads in one exchange', (tester) async {
      final rig = await _open(tester);
      await _tap(tester, find.text('read'));
      await _typePassword(tester, 'correct horse', remember: true);
      expect(await _remembered(tester, rig), keyAccessFor('correct horse', _device));
      rig.oath.received.clear();

      await _tap(tester, find.text('read'));

      expect(find.text(t('keyCodes.password.title')), findsNothing);
      expect((_count(rig.oath, _validate), _count(rig.oath, _list), _count(rig.oath, _calculateAll)), (1, 1, 2));
      await _leave(tester);
    });

    testWidgets('a remembered value the key refuses is dropped, and the password is asked for', (tester) async {
      final rig = await _open(tester);
      await _tap(tester, find.text('read'));
      await _typePassword(tester, 'correct horse', remember: true);
      // Changed with another tool.
      rig.oath.password = 'new password';

      await _tap(tester, find.text('read'));

      expect(find.text(t('keyCodes.password.refused')), findsOneWidget);
      expect(await _remembered(tester, rig), isNull);
      await _typePassword(tester, 'new password');
      expect(rig.vaultState.keyAccounts, hasLength(4));
      await _leave(tester);
    });

    testWidgets('what proves the password is in no export, sync document or QR transfer of the vault', (tester) async {
      final rig = await _open(tester);
      await tester.runAsync(() => rig.vault.addAccount(rfcVaultAccount()));
      await _tap(tester, find.text('read'));
      await _typePassword(tester, 'correct horse', remember: true);
      final access = (await _remembered(tester, rig))!;
      final state = rig.vaultState;
      expect(state.keyAccounts, hasLength(4));

      final shown = [
        b64(access),
        base64Url.encode(access),
        base64Url.encode(access).replaceAll('=', ''),
        [for (final byte in access) byte.toRadixString(16).padLeft(2, '0')].join(),
        latin1.decode(access),
      ];
      void expectNone(String what, String text) {
        for (final form in shown) {
          expect(text.contains(form), isFalse, reason: '$what holds it as "$form"');
        }
        expect(text.contains('correct horse'), isFalse, reason: '$what holds the password');
      }

      final files = await tester.runAsync(() async {
        final encrypted = await exportVault(
          state.accounts,
          state.backupServices,
          'export password',
          keys: state.keys,
          notes: state.notes,
          passkeys: state.passkeys,
          keyAccounts: state.keyAccounts,
          deriveKey: fastKdf,
        );
        final opened = await importVault(encrypted, 'export password', deriveKey: fastKdf);
        final syncKey = Uint8List.fromList(List.filled(32, 7));
        final merged = mergeScope(scopeLists(state.lists, null), const [], null).doc;
        final synced = await decryptSyncFile(await encryptSyncFile(merged, syncKey), syncKey);
        final qr = await importVaultQrPlaintext(exportVaultQrPlaintext(state.accounts, state.backupServices));
        return (
          encrypted: jsonEncode({
            'accounts': [for (final a in opened.accounts) a.toJson()],
            'keyAccounts': [for (final a in opened.keyAccounts) a.toJson()],
          }),
          plain: exportVaultPlaintext(state.accounts, state.backupServices, keyAccounts: state.keyAccounts),
          sync: jsonEncode(synced.toJson()),
          qr: jsonEncode([for (final a in qr.accounts) a.toJson()]),
        );
      });

      expect(files!.encrypted, contains('Example:alice@example.org'), reason: 'the names are there');
      expect(files.sync, contains('Example:alice@example.org'));
      expectNone('the encrypted export, decrypted', files.encrypted);
      expectNone('the plain export', files.plain);
      expectNone('the sync document, decrypted', files.sync);
      expectNone('the QR transfer', files.qr);
      await _leave(tester);
    });
  });

  group('setting, changing and removing the password', () {
    test('set makes the next read ask for it', () async {
      final rig = await CodesRig.open(oath: FakeOathKey(accounts: usualAccounts()));
      rig.present();

      expect((await rig.codes.setPassword('new password')).outcome, KeyCodesOutcome.done);

      expect((await rig.codes.read()).outcome, KeyCodesOutcome.passwordNeeded);
      expect((await rig.codes.read(accessKey: keyAccessFor('new password', _device))).outcome, KeyCodesOutcome.done);
    });

    test('change proves the current one first, and then the old one fails', () async {
      final rig = await CodesRig.open(
        oath: FakeOathKey(password: 'old password', accounts: usualAccounts()),
      );
      rig.present();

      expect((await rig.codes.setPassword('new password')).outcome, KeyCodesOutcome.passwordNeeded, reason: 'the current one first');
      expect(rig.oath.received.where((ins) => ins == 0x03), isEmpty, reason: 'no SET CODE was sent');
      final changed = await rig.codes.setPassword('new password', accessKey: keyAccessFor('old password', _device));
      expect(changed.outcome, KeyCodesOutcome.done);

      expect((await rig.codes.read(accessKey: keyAccessFor('old password', _device))).outcome, KeyCodesOutcome.wrongPassword);
      expect((await rig.codes.read(accessKey: keyAccessFor('new password', _device))).outcome, KeyCodesOutcome.done);
    });

    test('remove makes the next read ask for none', () async {
      final rig = await CodesRig.open(
        oath: FakeOathKey(password: 'old password', accounts: usualAccounts()),
      );
      rig.present();

      expect((await rig.codes.setPassword(null, accessKey: keyAccessFor('old password', _device))).outcome, KeyCodesOutcome.done);

      expect((await rig.codes.read()).outcome, KeyCodesOutcome.done);
      expect(rig.oath.accessKey, isNull);
    });

    test('each drops the remembered value', () async {
      for (final next in ['newer password', 'another one', null]) {
        final rig = await CodesRig.open(
          oath: FakeOathKey(password: 'old password', accounts: usualAccounts()),
        );
        rig.present();
        await rig.codes.read(accessKey: keyAccessFor('old password', _device), remember: true);
        expect(await rig.vault.keyAccess(_device), isNotNull);

        expect((await rig.codes.setPassword(next)).outcome, KeyCodesOutcome.done, reason: 'proved with the remembered value');

        expect(await rig.vault.keyAccess(_device), isNull, reason: '$next');
      }
    });

    testWidgets('the new password must be typed twice, the same', (tester) async {
      String? typed = 'not yet';
      await pumpScreen(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => typed = await showAppDialog<String>(context, builder: (_) => const KeyNewPasswordDialog()),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('open'));
      FilledButton save() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('keyCodes.password.save')));

      expect(save().onPressed, isNull);
      await tester.enterText(find.widgetWithText(TextField, t('keyCodes.password.new')), 'correct horse');
      await tester.enterText(find.widgetWithText(TextField, t('keyCodes.password.repeat')), 'correct house');
      await tester.pump();
      expect(find.text(t('keyCodes.password.mismatch')), findsOneWidget);
      expect(save().onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextField, t('keyCodes.password.repeat')), 'correct horse');
      await tester.pump();
      expect(find.text(t('keyCodes.password.mismatch')), findsNothing);
      await _tap(tester, find.text(t('keyCodes.password.save')));

      expect(typed, 'correct horse');
    });
  });
}
