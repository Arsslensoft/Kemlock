import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/security_keys/security_key_controller.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/ui/ui.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_oath_key.dart';
import '../fakes/fake_security_keys.dart';
import '../features/accounts/codes_fakes.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the Security key sheet with its Codes row, and "Codes on this
/// key", in dark and light, on a fake phone with a fake key plugged in
/// (`SecurityKey.dc.html`'s Codes row; openspec: add-security-key-codes,
/// task 7.3):
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/key_codes_test.dart
void main() {
  FakeKey mockupKey() => FakeKey(
    productName: 'YubiKey 5C NFC',
    ctap: FakeFidoKey(pin: '123456', firmwareVersion: 58),
    applets: [
      FakeOathKey(
        accounts: [
          FakeOathAccount('Bank:ada@example.org', ascii.encode('bank secret 01234567')),
          FakeOathAccount('Cloudflare:ada@example.org', ascii.encode('cloudflare secret 01')),
          FakeOathAccount('Registrar:ada@example.org', ascii.encode('registrar secret 012'), touch: true),
          FakeOathAccount('Mail server:root', ascii.encode('mail server secret 0')),
        ],
      ),
    ],
  );

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    /// The Security key sheet over Settings with the mockup's key plugged in.
    Future<void> open(WidgetTester tester) async {
      usePhoneScreen(tester);
      useReducedMotion(tester);
      final phone = FakeSecurityKeys();
      final container = ProviderContainer(
        overrides: [
          messageCatalogProvider.overrideWithValue(testCatalog),
          keyValueStoreProvider.overrideWithValue(KeyValueStore.memory()),
          clockProvider.overrideWithValue(phone.now),
          phone.asOverride,
          keySheetVaultOpenProvider.overrideWith((ref) => true),
          fakeVault(FakeVaultController(openVault())),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(brightness),
            debugShowCheckedModeBanner: false,
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
      phone.arrive(mockupKey().device(kinds: {SecurityKeyLinkKind.usbHid, SecurityKeyLinkKind.usbCcid}));
      await tester.pumpAndSettle();
    }

    Future<void> openCodes(WidgetTester tester) async {
      final row = find.widgetWithText(GroupRow, t('keyCodes.row'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    }

    testScreenshot('key codes: the Codes row, $name', (tester) async {
      await open(tester);
      await openCodes(tester);
      await tester.tap(find.bySemanticsLabel(t('export.close')).last);
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'key_codes_row_$name');
      await leave(tester);
    });

    testScreenshot('key codes: codes on this key, $name', (tester) async {
      await open(tester);
      await openCodes(tester);
      await takeScreenshot(tester, 'key_codes_sheet_$name');
      await leave(tester);
    });

    testScreenshot('key codes: erasing, $name', (tester) async {
      await open(tester);
      await openCodes(tester);
      final erase = find.text(t('keyCodes.erase'));
      await tester.ensureVisible(erase);
      await tester.pumpAndSettle();
      await tester.tap(erase);
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'key_codes_erase_$name');
      await leave(tester);
    });
  }
}
