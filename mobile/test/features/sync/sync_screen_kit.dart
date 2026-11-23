import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/sync_host.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/settings/offline_alert.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_kdf.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/platform/secret_clipboard.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_approval_notice.dart';
import '../../fakes/fake_live_server.dart';
import '../../fakes/fake_security_keys.dart';
import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/app_harness.dart' show FakeBiometrics;
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import 'fake_webdav.dart';

/// Sync as a test sets it, for widgets that only show the settings and
/// status: no vault, no store, no server.
class FakeSyncNotifier extends SyncNotifier {
  FakeSyncNotifier(this._initial);

  final SyncSnapshot _initial;

  @override
  SyncSnapshot build() => _initial;

  /// Replaces the settings, as joining or leaving a space does.
  void setSettings(SyncSettings settings) => state = SyncSnapshot(settings: settings, status: state.status, running: state.running);
}

/// Puts [snapshot] in [syncProvider]; read the notifier back as a
/// [FakeSyncNotifier] to change it.
Override fakeSync(SyncSnapshot snapshot) => syncProvider.overrideWith(() => FakeSyncNotifier(snapshot));

/// The folder the sheet tests type in, and the server path of a file in it.
const folder = 'https://dav.example.com/files/me/Kemlock/';
String folderPath(String file) => '/files/me/Kemlock/$file';

/// The key of the button that opens the sheet under test.
const openSheetKey = Key('open-sheet');

/// An open vault for the sync sheets, as the app has it once unlocked: its
/// sync settings loaded, a fake WebDAV folder ([server]), cheap scrypt.
///
/// ```dart
/// final kit = SyncSheetKit();
/// await kit.pump(tester, showSyncSheet);
/// await kit.open(tester);
/// ```
class SyncSheetKit {
  SyncSheetKit({FakeSecurityKeys? phone}) : phone = phone ?? FakeSecurityKeys(phone: SecurityKeyCapabilities.none);

  final server = FakeWebDav();
  final kv = KeyValueStore.memory();
  late final vaults = VaultRegistry(kv);

  /// No biometrics the hardware key could use, without the native side.
  final unlockKeys = FakeUnlockKeys(available: false);
  late final vaultStore = VaultStore(kv, vaults, deriveKey: fastKdf, unlockKeys: unlockKeys);

  /// The phone's reach to security keys: none unless a test gives one, as
  /// without the native side.
  final FakeSecurityKeys phone;

  late ProviderContainer container;
  late VaultSession session;

  /// The notification a sign-in request raises, kept in memory.
  final notice = FakeApprovalNotice();

  /// The live socket's server, which takes every connection.
  final live = FakeLiveServer();

  List<Override> get overrides => [
    notice.asOverride,
    live.asOverride,
    vaultRegistryProvider.overrideWithValue(vaults),
    vaultStoreProvider.overrideWithValue(vaultStore),
    biometricsProvider.overrideWithValue(FakeBiometrics(available: false)),
    unlockKeys.asOverride,
    phone.asOverride,
    webDavProvider.overrideWithValue(WebDav(server.client)),
    syncDeriveKeyProvider.overrideWithValue(fastKdf),
    // Nothing clears the clipboard later, so no timer outlives a test
    secretClipboardProvider.overrideWithValue(SecretClipboard(() => null)),
  ];

  /// Sets a vault up and opens it, on a page with a button that calls
  /// [show]. With [syncHost], sync runs as in the app ([SyncHost]);
  /// otherwise the settings are only loaded. [clock] is a clock the test
  /// moves, in place of the fixed one.
  Future<void> pump(
    WidgetTester tester,
    Future<void> Function(BuildContext context) show, {
    Brightness brightness = Brightness.dark,
    bool syncHost = false,
    List<Override> overrides = const [],
    DateTime Function()? clock,
  }) async {
    session = (await tester.runAsync(() => vaultStore.setupVault('pw')))!;
    final page = _Page(show: show);
    container = await pumpScreen(
      tester,
      syncHost ? SyncHost(child: page) : page,
      store: kv,
      brightness: brightness,
      clock: clock,
      overrides: [...this.overrides, ...overrides],
    );
    await vault.open(session);
    if (!syncHost) await sync.load(session);
    await tester.pumpAndSettle();
  }

  VaultController get vault => container.read(vaultControllerProvider.notifier);
  SyncNotifier get sync => container.read(syncProvider.notifier);

  /// The open vault's accounts and services as they are now.
  VaultState get vaultState => container.read(vaultControllerProvider);

  /// The sync settings as stored now.
  SyncSettings? get settings => container.read(syncProvider).settings;

  /// Opens the sheet and lets it settle.
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(openSheetKey));
    await tester.pumpAndSettle();
  }

  /// Turns offline mode on or off, as the switch in Settings does.
  Future<void> setOffline(WidgetTester tester, bool on) async {
    container.read(offlineProvider.notifier).set(on);
    await tester.pumpAndSettle();
  }

  /// Stores [next] as the vault's sync settings, as the sheets do.
  Future<void> save(SyncSettings next) => sync.saveSettings(next, session);

  /// Types the folder and its login into the sheet's fields.
  Future<void> fillDav(WidgetTester tester, {String url = folder}) async {
    await tester.enterText(field(t('sync.field.url')), url);
    await tester.enterText(field(t('sync.field.username')), 'me');
    await tester.enterText(field(t('sync.field.password')), 'app-pw');
    await tester.pump();
  }
}

/// The paused alert saying [message], with its "Network settings" action.
Finder offlineAlert(String message) => find.widgetWithText(OfflineAlert, message);

/// The text field labelled [label].
Finder field(String label) => find.widgetWithText(TextField, label);

/// The button (text, filled or outlined) labelled [label].
Finder buttonWithText(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton)).first;

/// Taps the button labelled [label] (scrolled into view first) and settles.
Future<void> tapButton(WidgetTester tester, String label) async {
  final button = buttonWithText(label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// The button labelled [label], to check whether it's on.
ButtonStyleButton button(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(buttonWithText(label));

/// A page with something on it, as Settings would be, and the button that opens the sheet.
class _Page extends StatelessWidget {
  const _Page({required this.show});

  final Future<void> Function(BuildContext context) show;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Text('Settings', style: AppType.h2.copyWith(color: context.palette.text)),
          const SizedBox(height: 24),
          Group(
            children: [
              GroupRow(
                key: openSheetKey,
                icon: const Icon(Icons.cloud_sync_outlined),
                primary: 'Devices',
                onTap: () => show(context),
                first: true,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
