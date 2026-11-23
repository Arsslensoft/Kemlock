import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/public_suffixes.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/attachment_store.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_approval_notice.dart';
import '../fakes/fake_attachments.dart';
import '../fakes/fake_autofill.dart';
import '../fakes/fake_credential_exchange.dart';
import '../fakes/fake_live_server.dart';
import '../fakes/fake_reminders.dart';
import '../fakes/fake_setup_links.dart';
import '../fakes/fake_unlock_keys.dart';
import '../vault/fast_kdf.dart';
import 'test_app.dart';

/// The biometric prompt, answered as the test says.
class FakeBiometrics implements Biometrics {
  FakeBiometrics({this.available = true, this.passes = true});

  bool available;

  /// Whether the person passes the next prompts; false as if they cancelled.
  bool passes;

  /// The reasons of every prompt shown, in order.
  final List<String> prompts = [];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts.add(reason);
    return passes;
  }
}

/// The whole app, as a phone would run it, on storage in memory, with
/// cheap key derivation and a fake biometric prompt.
///
/// ```dart
/// var app = TestApp();
/// await app.createVault('pw');       // optional: a vault already on the phone
/// await app.pump(tester);             // the lock screen
/// await app.unlock(tester, 'pw');     // straight to the Codes tab
/// app = await app.restart(tester);    // the same phone, back at the lock screen
/// ```
class TestApp {
  TestApp({
    KeyValueStore? store,
    FakeBiometrics? biometrics,
    FakeAutofill? autofill,
    FakeSetupLinks? links,
    FakeIosCredentialExchange? exchange,
    FakeAttachmentStore? attachments,
    FakeUnlockKeys? unlockKeys,
    FakeReminders? reminders,
    this.now,
  }) : store = store ?? KeyValueStore.memory(),
       attachments = attachments ?? FakeAttachmentStore(),
       biometrics = biometrics ?? FakeBiometrics(available: false),
       unlockKeys = unlockKeys ?? FakeUnlockKeys(available: biometrics?.available ?? false),
       autofill = autofill ?? FakeAutofill(),
       links = links ?? FakeSetupLinks(),
       exchange = exchange ?? FakeIosCredentialExchange(),
       reminders = reminders ?? FakeReminders();

  final KeyValueStore store;

  /// `local_auth`'s prompt, for the gates that hold no key.
  final FakeBiometrics biometrics;

  /// The Keychain or Keystore keys biometric unlock opens the vault with,
  /// there when [biometrics] are available unless given.
  final FakeUnlockKeys unlockKeys;

  /// The phone's autofill, which keeps what the app hands it.
  final FakeAutofill autofill;

  /// The set-up links other apps hand the app.
  final FakeSetupLinks links;

  /// The exports another app hands the app on iOS 26.
  final FakeIosCredentialExchange exchange;

  /// The phone's scheduled notifications, and its answer to the permission prompt.
  final FakeReminders reminders;

  /// The files attached to notes, kept in memory as the phone would store them.
  final FakeAttachmentStore attachments;

  /// The time the app reads; [testNow] when null.
  DateTime Function()? now;

  late final VaultRegistry vaults = VaultRegistry(store);
  late final VaultStore vaultStore = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: unlockKeys);

  late ProviderContainer container;

  List<Override> get overrides => [
    messageCatalogProvider.overrideWithValue(testCatalog),
    keyValueStoreProvider.overrideWithValue(store),
    clockProvider.overrideWithValue(now ?? () => testNow),
    vaultRegistryProvider.overrideWithValue(vaults),
    vaultStoreProvider.overrideWithValue(vaultStore),
    biometricsProvider.overrideWithValue(biometrics),
    unlockKeys.asOverride,
    autofill.asOverride,
    links.asOverride,
    exchange.asOverride,
    reminders.asOverride,
    FakeApprovalNotice().asOverride,
    FakeLiveServer().asOverride,
    attachmentStoreProvider.overrideWithValue(attachments),
    // The asset bundle can't load it in fake time; the file is read once per test run
    publicSuffixListProvider.overrideWith((ref) => bundledSuffixes),
  ];

  /// Sets a vault up on the "phone" before the app starts.
  Future<VaultSession> createVault(String password) => vaultStore.setupVault(password);

  /// The overrides [pump] was last given, which [restart] passes on.
  List<Override> _extra = const [];

  /// Starts the app. Its providers go when it leaves the screen: when the
  /// test pumps something else, and at the end of the test, before Flutter
  /// checks that no timer is left (see [_AppScope]). The effects are held
  /// still unless [effects] is [EffectsMode.running].
  Future<void> pump(WidgetTester tester, {List<Override> overrides = const [], EffectsMode effects = EffectsMode.pinned}) async {
    useReducedMotion(tester);
    _extra = overrides;
    container = ProviderContainer(overrides: [...this.overrides, ...overrides]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _AppScope(
        key: ObjectKey(container),
        container: container,
        child: EffectsScope(pinned: effects.phase, child: const KemlockApp()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Closes the app and starts it again on the same phone, as after the
  /// phone killed it: a new app on the same storage, with the same fakes,
  /// clock and overrides, and nothing kept in memory. An open vault was
  /// open in memory only, as it lived in the WebView's sessionStorage, so
  /// the new app asks for the password.
  ///
  /// ```dart
  /// app = await app.restart(tester);   // the lock screen
  /// ```
  Future<TestApp> restart(WidgetTester tester) async {
    final next = TestApp(
      store: store,
      biometrics: biometrics,
      unlockKeys: unlockKeys,
      autofill: autofill,
      links: links,
      exchange: exchange,
      reminders: reminders,
      attachments: attachments,
      now: now,
    );
    await next.pump(tester, overrides: _extra);
    return next;
  }

  VaultController get controller => container.read(vaultControllerProvider.notifier);

  VaultState get state => container.read(vaultControllerProvider);

  /// Opens the vault the way the lock screen does once a password checks out.
  Future<void> unlock(WidgetTester tester, String password) async {
    // In fake time, so timers the unlock starts (auto-lock, sync) run as the test pumps; the cheap scrypt needs no isolate.
    await controller.open(await vaultStore.unlockAnyVault(password, vaults.startingVault()));
    await tester.pumpAndSettle();
  }
}

/// The app's provider scope, which disposes [container] when it leaves the
/// screen, as the phone frees an app's memory when it is closed.
///
/// A provider whose last listener leaves the screen with the whole scope
/// is never disposed: the scope cancels the dispose it was asked for as it
/// goes. The Codes tab's second ticker would then keep its timer, and
/// flutter_test fails a test that leaves a timer behind once it has taken
/// the widgets away, before tear-downs run.
class _AppScope extends StatefulWidget {
  const _AppScope({super.key, required this.container, required this.child});

  final ProviderContainer container;
  final Widget child;

  @override
  State<_AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<_AppScope> {
  @override
  void dispose() {
    widget.container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(container: widget.container, child: widget.child);
}
