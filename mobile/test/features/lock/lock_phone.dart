import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';

/// The system's biometric prompt, answered as the test says.
class PromptBiometrics implements Biometrics {
  PromptBiometrics({this.available = true, this.passes = true, this.error});

  bool available;

  /// Whether the person passes the next prompts; false as if they cancelled.
  bool passes;

  /// Thrown by the next prompts instead of answering, when set.
  Object? error;

  /// Called while a prompt is up.
  VoidCallback? onPrompt;

  /// The reasons of every prompt shown, in order.
  final List<String> prompts = [];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts.add(reason);
    onPrompt?.call();
    if (error case final error?) throw error;
    return passes;
  }
}

/// A phone for the setup and lock screens: storage in memory, cheap key
/// derivation, a biometric prompt the test answers, and the hardware keys of
/// biometric unlock, there when [biometrics] are available unless given.
class LockPhone {
  LockPhone({
    KeyValueStore? store,
    PromptBiometrics? biometrics,
    FakeUnlockKeys? unlockKeys,
    VaultStore Function(KeyValueStore store, VaultRegistry vaults)? vaultStore,
    this.extra = const [],
  }) : store = store ?? KeyValueStore.memory(),
       biometrics = biometrics ?? PromptBiometrics(available: false),
       _makeStore = vaultStore,
       unlockKeys = unlockKeys ?? FakeUnlockKeys(available: biometrics?.available ?? false);

  /// More overrides, such as a fake of something the screen talks to.
  final List<Override> extra;

  /// The phone's storage: in memory unless given, such as one opened again
  /// from the same backend after the app was killed.
  final KeyValueStore store;
  late final VaultRegistry vaults = VaultRegistry(store);
  late final VaultStore vaultStore =
      _makeStore?.call(store, vaults) ?? VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: unlockKeys);
  final VaultStore Function(KeyValueStore store, VaultRegistry vaults)? _makeStore;

  /// `local_auth`'s prompt, for the gates that hold no key.
  final PromptBiometrics biometrics;

  /// The Keychain or Keystore keys biometric unlock opens the vault with.
  final FakeUnlockKeys unlockKeys;
  late ProviderContainer container;

  List<Override> get overrides => [
    vaultRegistryProvider.overrideWithValue(vaults),
    vaultStoreProvider.overrideWithValue(vaultStore),
    biometricsProvider.overrideWithValue(biometrics),
    unlockKeys.asOverride,
    ...extra,
  ];

  /// Turns biometric unlock on for the vault [session] opened, as the
  /// enable sheet does, before the screen shows.
  Future<void> enableBiometrics(WidgetTester tester, VaultSession session) async {
    await tester.runAsync(() => vaultStore.enableBiometricUnlock(session, 'Turn it on'));
    unlockKeys.prompts.clear();
    unlockKeys.calls.clear();
  }

  /// Sets the first vault up with [password], before the screen shows.
  Future<VaultSession> createVault(WidgetTester tester, String password) async =>
      (await tester.runAsync(() => vaultStore.setupVault(password)))!;

  /// Adds a vault called [name], listed on the lock screen or hidden, and returns its id.
  Future<String> addVault(WidgetTester tester, String name, String password, {bool listed = true}) async =>
      (await tester.runAsync(() => vaultStore.createVault(name, password, listed: listed)))!;

  /// Pumps [screen] on this phone, with motion reduced unless [reducedMotion] is false.
  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget screen, {
    Brightness brightness = Brightness.dark,
    bool reducedMotion = true,
  }) async => container = await pumpScreen(
    tester,
    screen,
    store: store,
    overrides: overrides,
    brightness: brightness,
    reducedMotion: reducedMotion,
  );

  VaultState get state => container.read(vaultControllerProvider);

  VaultController get controller => container.read(vaultControllerProvider.notifier);
}

/// A page with an Open button that calls [show], to open a sheet from.
class SheetOpener extends StatelessWidget {
  const SheetOpener(this.show, {super.key});

  final Future<void> Function(BuildContext context) show;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(onPressed: () => show(context), child: const Text('Open')),
      ),
    ),
  );
}

/// A phone screen, 393 by 852 points with a notch and a home bar, so the
/// screens lay out as they do on a phone.
void usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 852) * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

/// The button labelled [label], whatever kind it is.
Finder buttonLabelled(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

/// Whether the button labelled [label] can be pressed.
bool isEnabled(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(buttonLabelled(label)).enabled;

/// The text field labelled [label].
Finder fieldLabelled(String label) => find.widgetWithText(TextField, label);

/// Whether the field labelled [label] hides what was typed.
bool isObscured(WidgetTester tester, String label) => tester.widget<TextField>(fieldLabelled(label)).obscureText;

/// Scrolls [finder] into view, taps it and lets the screen settle.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Types [text] into the field labelled [label].
Future<void> typeInto(WidgetTester tester, String label, String text) async {
  await tester.enterText(fieldLabelled(label), text);
  await tester.pumpAndSettle();
}
