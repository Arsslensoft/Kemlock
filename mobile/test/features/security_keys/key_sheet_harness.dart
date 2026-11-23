import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/security_keys/security_key_controller.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';

const nfc = {SecurityKeyLinkKind.nfc};
const usb = {SecurityKeyLinkKind.usbHid, SecurityKeyLinkKind.usbCcid};
const smartcard = {SecurityKeyLinkKind.smartcard};

/// Whether the vault is open, as the sheet under test sees it.
class _VaultOpen extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool open) => state = open;
}

final _vaultOpen = NotifierProvider<_VaultOpen, bool>(_VaultOpen.new);

/// The Security key sheet open over a page, on a fake phone.
class KeySheetRig {
  KeySheetRig(this.tester, this.phone, this.container, this.store);

  final WidgetTester tester;
  final FakeSecurityKeys phone;
  final ProviderContainer container;
  final KeyValueStore store;

  AutoLockHolds get holds => container.read(autoLockHoldsProvider);

  /// [key] is held to the phone or plugged in, over links of [kinds].
  Future<FakeDevice> present(FakeKey key, Set<SecurityKeyLinkKind> kinds) async {
    final device = key.device(kinds: kinds);
    phone.arrive(device);
    await tester.pumpAndSettle();
    return device;
  }

  /// [device] is taken away or unplugged.
  Future<void> remove(FakeDevice device) async {
    phone.remove(device);
    await tester.pumpAndSettle();
  }

  /// The vault locks.
  Future<void> lockVault() async {
    container.read(_vaultOpen.notifier).set(false);
    await tester.pumpAndSettle();
  }

  /// Opens the sheet again after it was closed.
  Future<void> reopen() async {
    unawaited(showSecurityKeySheet(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();
  }

  /// Closes the sheet on top.
  Future<void> close() async {
    await tester.tap(find.bySemanticsLabel(t('export.close')).last);
    await tester.pumpAndSettle();
  }

  /// Taps the row of the sheet named by the message [id].
  Future<void> tapRow(String id) async {
    await tester.tap(find.widgetWithText(GroupRow, t(id)).last);
    await tester.pumpAndSettle();
  }

  /// Taps the button or link with the message [id].
  Future<void> tap(String id, [Map<String, Object?> args = const {}]) async {
    final target = find.text(t(id, args)).last;
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// Types [pin] in the PIN prompt and continues.
  Future<void> typePin(String pin) async {
    await tester.enterText(find.byType(TextField).last, pin);
    await tester.pump();
    await tap('securityKeys.pin.continue');
  }

  /// The requests [fido] got that carried a PIN: a token asked for, or a change.
  static List<String> pinRequests(FakeFidoKey fido) => [
    for (final request in fido.requests)
      if (request == '6.5' || request == '6.9' || request == '6.4') request,
  ];
}

/// The row named by the message [id].
Finder keyRow(String id) => find.widgetWithText(GroupRow, t(id));

/// Whether the row named by [id] can be tapped.
bool rowTappable(WidgetTester tester, String id) => tester.widget<GroupRow>(keyRow(id).last).onTap != null;

/// Opens the Security key sheet on a phone with [capabilities], on a
/// screen tall enough for the whole sheet. The app's clock is the fake
/// phone's, so time limits and the key's own rules run on one clock.
Future<KeySheetRig> openKeySheet(
  WidgetTester tester, {
  SecurityKeyCapabilities capabilities = FakeSecurityKeys.android,
  Brightness brightness = Brightness.dark,
  AppLocale locale = AppLocale.en,
  FakeSecurityKeys? phone,
  bool tall = true,
  List<Override> overrides = const [],
}) async {
  if (tall) {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  useReducedMotion(tester);
  final fake = phone ?? FakeSecurityKeys(phone: capabilities);
  final store = KeyValueStore.memory();
  final container = ProviderContainer(
    overrides: [
      messageCatalogProvider.overrideWithValue(testCatalog),
      keyValueStoreProvider.overrideWithValue(store),
      clockProvider.overrideWithValue(fake.now),
      fake.asOverride,
      keySheetVaultOpenProvider.overrideWith((ref) => ref.watch(_vaultOpen)),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      key: ObjectKey(container),
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(brightness),
        debugShowCheckedModeBanner: false,
        localizationsDelegates: localizationsDelegates(testCatalog),
        supportedLocales: supportedLocales,
        locale: locale.locale,
        builder: (context, child) => ToastHost(child: child!),
        home: const Scaffold(body: Center(child: Text('Settings'))),
      ),
    ),
  );
  await tester.pump();
  final rig = KeySheetRig(tester, fake, container, store);
  await rig.reopen();
  return rig;
}
