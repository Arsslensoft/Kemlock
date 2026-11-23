// The "Codes" row of the Security key sheet and the "Codes on this key"
// sheet it opens (openspec: add-security-key-codes, task 7.1).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/features/security_keys/key_codes_sheet.dart';
import 'package:kemlock/features/security_keys/security_key_controller.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../accounts/codes_fakes.dart';
import 'key_codes_harness.dart';

const _device = '0102030405060708';

/// The Security key sheet over Settings, on a fake phone, with a test vault.
class _Rig {
  _Rig(this.tester, this.phone, this.vault, this.oath);

  final WidgetTester tester;
  final FakeSecurityKeys phone;
  final FakeVaultController vault;
  final FakeOathKey oath;

  /// The key is plugged in, with its code application when [codes].
  Future<FakeDevice> plugIn({bool codes = true}) async {
    final key = FakeKey(productName: 'YubiKey 5C NFC', ctap: FakeFidoKey(), applets: codes ? [oath] : []);
    final device = key.device(kinds: usbKey);
    phone.arrive(device);
    await tester.pumpAndSettle();
    return device;
  }

  GroupRow get codesRow => tester.widget<GroupRow>(find.widgetWithText(GroupRow, t('keyCodes.row')));

  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Opens "Codes on this key" from the row.
  Future<void> openCodes() => tap(find.widgetWithText(GroupRow, t('keyCodes.row')));

  Finder get codesSheet => find.byType(KeyCodesSheet);
}

Future<_Rig> _open(
  WidgetTester tester, {
  FakeOathKey? oath,
  List<KeyAccount> remembered = const [],
  SecurityKeyCapabilities capabilities = FakeSecurityKeys.android,
}) async {
  tester.view.physicalSize = const Size(420, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  useReducedMotion(tester);
  final phone = FakeSecurityKeys(phone: capabilities);
  final vault = FakeVaultController(openVault(keyAccounts: remembered));
  final container = ProviderContainer(
    overrides: [
      messageCatalogProvider.overrideWithValue(testCatalog),
      keyValueStoreProvider.overrideWithValue(KeyValueStore.memory()),
      clockProvider.overrideWithValue(phone.now),
      phone.asOverride,
      keySheetVaultOpenProvider.overrideWith((ref) => true),
      fakeVault(vault),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        localizationsDelegates: localizationsDelegates(testCatalog),
        supportedLocales: supportedLocales,
        builder: (context, child) => ToastHost(child: child!),
        home: const Scaffold(body: Center(child: Text('Settings'))),
      ),
    ),
  );
  await tester.pump();
  unawaited(showSecurityKeySheet(tester.element(find.byType(Scaffold).first)));
  await tester.pumpAndSettle();
  return _Rig(tester, phone, vault, oath ?? FakeOathKey(accounts: usualAccounts()));
}

/// Takes the screen away, so no timer of the fake phone outlives the test.
Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  group('the Codes row', () {
    testWidgets('sits in “Also on this key”, and counts the key’s accounts once read', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn();

      expect(find.text(t('securityKeys.section.also').toUpperCase()), findsOneWidget);
      expect(rig.codesRow.value, isNull, reason: 'the vault never listed its accounts');
      await rig.openCodes();

      expect(rig.codesSheet, findsOneWidget);
      expect(find.descendant(of: rig.codesSheet, matching: find.text('Registrar')), findsOneWidget);
      await rig.tap(find.descendant(of: rig.codesSheet, matching: find.bySemanticsLabel(t('export.close'))));
      expect((rig.codesRow.value! as Text).data, t('keyCodes.count', {'count': 4}));
      await _leave(tester);
    });

    testWidgets('is off, with the reason, for a key without the code application', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn(codes: false);

      await rig.openCodes();

      expect(rig.codesSheet, findsNothing);
      expect(rig.codesRow.onTap, isNull);
      expect(rig.codesRow.secondary, t('keyCodes.unsupported'));
      expect(rig.vault.keyAccountSaves, isEmpty, reason: 'nothing is remembered');
      await _leave(tester);
    });

    testWidgets('is off as soon as the sheet reads a key without the code application, before a tap', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn(codes: false);

      expect(rig.codesRow.onTap, isNull);
      expect(rig.codesRow.secondary, t('keyCodes.unsupported'));
      await _leave(tester);
    });

    testWidgets('counts what the vault remembers of the key as soon as the sheet reads it, listing nothing', (tester) async {
      const remembered = [
        KeyAccount(id: 'ka1', device: _device, name: 'Example:alice', issuer: 'Example', label: 'alice', addedAt: 1),
        KeyAccount(id: 'ka2', device: _device, name: 'Registrar:root', issuer: 'Registrar', label: 'root', addedAt: 1),
        KeyAccount(id: 'ka3', device: 'ffffffffffffffff', name: 'Other:bob', issuer: 'Other', label: 'bob', addedAt: 1),
      ];
      final rig = await _open(tester, remembered: remembered);
      await rig.plugIn();

      expect((rig.codesRow.value! as Text).data, t('keyCodes.count', {'count': 2}));
      expect(rig.oath.received, isEmpty, reason: 'the code application was selected, and asked nothing');
      await _leave(tester);
    });

    testWidgets('on an iPhone, reads the codes in one NFC session without reading the passkey side again', (tester) async {
      final rig = await _open(tester, capabilities: FakeSecurityKeys.iphone);
      final fido = FakeFidoKey();
      final key = FakeKey(productName: 'YubiKey 5C NFC', ctap: fido, applets: [rig.oath]).device(kinds: nfcKey);
      rig.phone.arrive(key);
      await rig.tap(find.text(t('securityKeys.wait.iphone.read')));
      int sessions() => rig.phone.calls.where((call) => call.startsWith('beginNfc')).length;
      final before = sessions();
      fido.requests.clear();

      // Held to the phone again, for the read the row starts
      rig.phone.arrive(key);
      await rig.openCodes();

      expect(rig.codesSheet, findsOneWidget);
      expect(sessions(), before + 1);
      expect(fido.requests, isEmpty, reason: 'the codes are asked of the key directly');
      await _leave(tester);
    });
  });

  group('Codes on this key', () {
    testWidgets('deletes an account after a confirmation that names it', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn();
      await rig.openCodes();

      await rig.tap(find.byTooltip(t('keyCodes.delete.named', {'name': 'Registrar'})));
      expect(find.text(t('keyCodes.delete.body', {'name': 'Registrar'})), findsOneWidget);
      await rig.tap(find.text(t('export.cancel')));
      expect(rig.oath.find('Registrar:root'), isNotNull, reason: 'cancelled: nothing sent');

      await rig.tap(find.byTooltip(t('keyCodes.delete.named', {'name': 'Registrar'})));
      await rig.tap(find.widgetWithText(FilledButton, t('keyCodes.delete')));

      expect(rig.oath.find('Registrar:root'), isNull);
      expect(rig.vault.state.keyAccounts.map((account) => account.name), isNot(contains('Registrar:root')));
      expect(find.descendant(of: rig.codesSheet, matching: find.text('Registrar')), findsNothing);
      await _leave(tester);
    });

    testWidgets('sets a password typed twice, and then offers to change or remove it', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn();
      await rig.openCodes();
      expect(find.text(t('keyCodes.password.change')), findsNothing);

      await rig.tap(find.text(t('keyCodes.password.set')));
      await tester.enterText(find.widgetWithText(TextField, t('keyCodes.password.new')), 'correct horse');
      await tester.enterText(find.widgetWithText(TextField, t('keyCodes.password.repeat')), 'correct horse');
      await tester.pump();
      await rig.tap(find.text(t('keyCodes.password.save')));

      expect(rig.oath.accessKey, isNotNull);
      expect(find.text(t('keyCodes.password.change')), findsOneWidget);
      expect(find.text(t('keyCodes.password.remove')), findsOneWidget);
      await _leave(tester);
    });

    testWidgets('erase stays off until the word matches, then empties the key and the vault’s entries for it', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn();
      await rig.openCodes();
      final before = List.of(rig.oath.id);
      FilledButton erase() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('keyCodes.erase.confirm')));

      await rig.tap(find.text(t('keyCodes.erase')));
      expect(find.textContaining(t('keyCodes.erase.body').substring(0, 40)), findsOneWidget);
      expect(erase().onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, 'ERAS');
      await tester.pump();
      expect(erase().onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, 'ERASE');
      await tester.pump();
      expect(erase().onPressed, isNotNull);
      await rig.tap(find.widgetWithText(FilledButton, t('keyCodes.erase.confirm')));

      expect(rig.oath.accounts, isEmpty);
      expect(rig.oath.id, isNot(before), reason: 'a reset gives the application a new id');
      expect(rig.vault.state.keyAccounts.where((account) => account.device == _device), isEmpty);
      expect(rig.codesSheet, findsNothing);
      expect(find.text(t('keyCodes.erased')), findsOneWidget);
      await _leave(tester);
    });

    testWidgets('forgets the key in this vault and sends nothing to it', (tester) async {
      final rig = await _open(tester);
      await rig.plugIn();
      await rig.openCodes();
      rig.vault.keyAccesses[_device] = keyAccessFor('correct horse', _device);
      rig.oath.received.clear();

      await rig.tap(find.text(t('keyCodes.forget')));
      await rig.tap(find.text(t('keyCodes.forget.confirm')));

      expect(rig.oath.received, isEmpty);
      expect(rig.oath.accounts, hasLength(4));
      expect(rig.vault.state.keyAccounts, isEmpty);
      expect(rig.vault.keyAccesses, isEmpty);
      expect(rig.codesSheet, findsNothing);
      await _leave(tester);
    });
  });
}
