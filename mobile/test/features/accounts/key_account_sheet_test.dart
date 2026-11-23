// The sheet of an account kept on a security key (openspec:
// add-security-key-codes, task 4.5).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/key_account_sheet.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../security_keys/key_codes_harness.dart';
import 'codes_fakes.dart';

const _device = '0102030405060708';

const _alice = KeyAccount(
  id: 'k1',
  device: _device,
  keyName: 'YubiKey 5C NFC',
  name: 'Example:alice@example.org',
  issuer: 'Example',
  label: 'alice@example.org',
  addedAt: 1,
);

const _registrar = KeyAccount(
  id: 'k3',
  device: _device,
  keyName: 'YubiKey 5C NFC',
  name: 'Registrar:root',
  issuer: 'Registrar',
  label: 'root',
  touch: true,
  addedAt: 1,
);

/// The sheet over a page with a button that opens it, on a fake phone
/// with a key that holds the usual four accounts.
class _Sheet {
  _Sheet(this.vault, this.phone, this.oath, this.key);

  final FakeVaultController vault;
  final FakeSecurityKeys phone;
  final FakeOathKey oath;
  final FakeKey key;
}

Future<_Sheet> _open(WidgetTester tester, KeyAccount account, {List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(420, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final vault = FakeVaultController(openVault(keyAccounts: [_alice, _registrar]));
  final phone = FakeSecurityKeys();
  final oath = FakeOathKey(accounts: usualAccounts());
  final key = FakeKey(productName: 'YubiKey 5C NFC', applets: [oath]);
  await pumpAt(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showKeyAccountSheet(context, account: account, allTags: const ['Work']),
            child: const Text('open'),
          ),
        ),
      ),
    ),
    atMs: testNow.millisecondsSinceEpoch + 10000,
    overrides: [fakeVault(vault), phone.asOverride, ...overrides],
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return _Sheet(vault, phone, oath, key);
}

Finder get _sheet => find.byType(KeyAccountSheet);

Finder _inSheet(Finder finder) => find.descendant(of: _sheet, matching: finder);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late FakeClipboard clipboard;

  setUp(() => clipboard = FakeClipboard());

  group('what it shows', () {
    testCodes('names the account, the key that holds it, its kind and whether it needs a touch', (tester) async {
      await _open(tester, _registrar);

      expect(_inSheet(find.text('Registrar')), findsOneWidget);
      expect(_inSheet(find.text('root')), findsOneWidget);
      expect(_inSheet(find.text('YubiKey 5C NFC')), findsOneWidget);
      expect(_inSheet(find.text(t('keyCodes.sheet.kind.totp', {'period': 30}))), findsOneWidget);
      expect(_inSheet(find.text(t('keyCodes.sheet.touch.yes'))), findsOneWidget);
      expect(_inSheet(find.text(t('keyCodes.sheet.secret'))), findsOneWidget);
    });

    testCodes('offers no way to show, copy or export a secret', (tester) async {
      final sheet = await _open(tester, _alice);

      // What the vault account's sheet shows or copies its secret with.
      for (final id in ['accountCard.tooltip.viewQr', 'accountSheet.reveal', 'viewQr.secret.copy', 'export.title']) {
        expect(_inSheet(find.text(t(id))), findsNothing, reason: id);
        expect(_inSheet(find.byTooltip(t(id))), findsNothing, reason: id);
        expect(find.bySemanticsLabel(t(id)), findsNothing, reason: id);
      }
      expect(find.byType(QrImageView), findsNothing);

      // Every button the sheet has: save, delete and close. None of them copies anything.
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));
      expect(clipboard.writes, isEmpty);
      expect(sheet.oath.received, isEmpty);
    });
  });

  group('tags and the note', () {
    testCodes('are saved in the vault, with nothing sent to the key', (tester) async {
      final sheet = await _open(tester, _alice);
      sheet.phone.arrive(sheet.key.device(kinds: nfcKey));

      await _tap(tester, _inSheet(find.text('Work')));
      await tester.enterText(find.widgetWithText(TextField, t('accountSheet.note')), '  Recovery codes in the safe  ');
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      final saved = sheet.vault.keyAccountSaves.single.singleWhere((account) => account.id == 'k1');
      expect(saved.tags, ['Work']);
      expect(saved.note, 'Recovery codes in the safe');
      expect(sheet.vault.keyAccountSaves.single.singleWhere((account) => account.id == 'k3'), _registrar);
      expect(sheet.oath.received, isEmpty);
      expect(sheet.phone.calls.where((call) => call.startsWith('beginNfc')), isEmpty);
    });
  });

  group('delete', () {
    testCodes('asks first, naming the account, and sends nothing when cancelled', (tester) async {
      final sheet = await _open(tester, _alice);
      sheet.phone.arrive(sheet.key.device(kinds: nfcKey));

      await _tap(tester, _inSheet(find.text(t('keyCodes.delete'))));

      expect(find.text(t('keyCodes.delete.title')), findsOneWidget);
      expect(find.text(t('keyCodes.delete.body', {'name': 'Example'})), findsOneWidget);
      await _tap(tester, find.text(t('export.cancel')));

      expect(sheet.oath.received, isEmpty);
      expect(sheet.oath.find('Example:alice@example.org'), isNotNull);
      expect(sheet.vault.keyAccountSaves, isEmpty);
      expect(_sheet, findsOneWidget);
    });

    testCodes('once confirmed, removes it from the key and from the list', (tester) async {
      final sheet = await _open(tester, _alice);
      sheet.phone.arrive(sheet.key.device(kinds: nfcKey));

      await _tap(tester, _inSheet(find.text(t('keyCodes.delete'))));
      await _tap(tester, find.widgetWithText(FilledButton, t('keyCodes.delete')));

      expect(sheet.oath.find('Example:alice@example.org'), isNull);
      expect(sheet.oath.accounts, hasLength(3));
      expect([for (final account in sheet.vault.state.keyAccounts) account.id], ['k3']);
      expect(_sheet, findsNothing, reason: 'the sheet closed');
      expect(find.text(t('keyCodes.deleted', {'name': 'Example'})), findsOneWidget);
    });
  });
}
