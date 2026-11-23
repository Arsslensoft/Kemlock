// Codes on a key are open to everyone at three doors: the Codes row, "Read the
// key" and the key's account sheet (openspec: add-security-key-codes, task 9.1).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/accounts/accounts_page.dart';
import 'package:kemlock/features/accounts/key_account_card.dart';
import 'package:kemlock/features/accounts/key_account_sheet.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/features/security_keys/security_key_controller.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../accounts/codes_fakes.dart';
import 'key_codes_harness.dart';

const _remembered = [
  KeyAccount(
    id: 'ka1',
    device: '0102030405060708',
    keyName: 'YubiKey 5C NFC',
    name: 'Example:alice@example.org',
    issuer: 'Example',
    label: 'alice@example.org',
    addedAt: 1,
  ),
  KeyAccount(
    id: 'ka2',
    device: '0102030405060708',
    keyName: 'YubiKey 5C NFC',
    name: 'Registrar:root',
    issuer: 'Registrar',
    label: 'root',
    touch: true,
    addedAt: 1,
  ),
];

/// A phone with a fake key held to it, and a vault that remembers [_remembered].
class _Rig {
  _Rig(this.tester, this.vault, this.oath, this.phone, this.container);

  final WidgetTester tester;
  final FakeVaultController vault;
  final FakeOathKey oath;
  final FakeSecurityKeys phone;
  final ProviderContainer container;

  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }
}

Future<_Rig> _open(WidgetTester tester, Widget home, {bool plugIn = false}) async {
  tester.view.physicalSize = const Size(420, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  useReducedMotion(tester);
  final phone = FakeSecurityKeys();
  final vault = FakeVaultController(openVault(keyAccounts: _remembered));
  final oath = FakeOathKey(accounts: usualAccounts());
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
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final key = FakeKey(productName: 'YubiKey 5C NFC', ctap: FakeFidoKey(), applets: [oath]);
  phone.arrive(key.device(kinds: plugIn ? usbKey : nfcKey));
  await tester.pumpAndSettle();
  _containers.add(container);
  return _Rig(tester, vault, oath, phone, container);
}

Future<_Rig> _openKeySheet(WidgetTester tester) async {
  final rig = await _open(tester, const Scaffold(body: Center(child: Text('Settings'))), plugIn: true);
  unawaited(showSecurityKeySheet(tester.element(find.byType(Scaffold).first)));
  await tester.pumpAndSettle();
  return rig;
}

Finder get _codesRow => find.widgetWithText(GroupRow, t('keyCodes.row'));

/// The containers [_open] made in this test.
final _containers = <ProviderContainer>[];

/// Takes the screen away and disposes what [_open] made, so no ticker or timer outlives the test.
Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
  for (final container in _containers) {
    container.dispose();
  }
  _containers.clear();
}

void main() {
  testWidgets('the Codes row reads the key', (tester) async {
    final rig = await _openKeySheet(tester);

    await rig.tap(_codesRow);

    expect(rig.oath.received, contains(0xa1));
    await _leave(tester);
  });

  testWidgets('the sheet’s read of the key gives the Codes row its count, before a tap', (tester) async {
    final rig = await _openKeySheet(tester);

    expect(rig.container.read(keyCodesProvider).apps.values.single?.device, '0102030405060708');
    expect(find.descendant(of: _codesRow, matching: find.text(t('keyCodes.count', {'count': 2}))), findsOneWidget);
    expect(rig.oath.received, isEmpty, reason: 'nothing listed');
    await _leave(tester);
  });

  testWidgets('“Read the key” reads it, and the remembered names list', (tester) async {
    final rig = await _open(tester, const Scaffold(body: AccountsPage()));

    expect(find.byType(KeyAccountCard), findsNWidgets(2));
    await rig.tap(find.text(t('keyCodes.read')));

    expect(rig.oath.received, contains(0xa1));
    await _leave(tester);
  });

  testWidgets('an export counts the names on the key', (tester) async {
    await _open(tester, const Scaffold(body: SizedBox.expand()));
    unawaited(showExportSheet(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();

    expect(find.text(t('export.onKey', {'count': 2})), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('“Forget this key” works, with nothing sent to the key', (tester) async {
    final rig = await _open(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showKeyAccountSheet(context, account: _remembered.first),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await rig.tap(find.text('open'));

    await rig.tap(find.text(t('keyCodes.forget')));
    await rig.tap(find.text(t('keyCodes.forget.confirm')));

    expect(rig.vault.state.keyAccounts, isEmpty);
    expect(rig.oath.received, isEmpty);
    await _leave(tester);
  });
}
