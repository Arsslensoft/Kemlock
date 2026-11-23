import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_clipboard.dart';
import '../../helpers/test_app.dart';

/// The RFC 6238 SHA-1 seed: at 59 s the 6-digit code is 287082, from 60 to
/// 89 s it is 359152, then 969429. As an HOTP secret (RFC 4226), counter 0
/// gives 755224 and counter 1 gives 287082.
const rfcAccount = OtpAccount(id: 'acc', issuer: 'GitHub', label: 'octocat', secret: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', addedAt: 0);

/// The open vault as a screen sees it, holding [accounts].
VaultState openVault({
  List<OtpAccount> accounts = const [],
  List<BackupService> backupServices = const [],
  List<KeyAccount> keyAccounts = const [],
}) => VaultState(
  phase: VaultPhase.unlocked,
  accounts: accounts,
  backupServices: backupServices,
  keyAccounts: keyAccounts,
  vault: const VaultInfo(id: 'vault'),
);

/// A vault controller that records what the screens ask of it, as the
/// Vitest tests' stubbed context did, and changes nothing unless [apply].
class FakeVaultController extends VaultController {
  FakeVaultController(this.initial, {this.apply = false});

  final VaultState initial;

  /// Apply updates and reorders to the state, as the real controller would.
  final bool apply;

  final List<OtpAccount> updated = [];
  final List<List<String>> reordered = [];
  final List<OtpAccount> deleted = [];
  int locks = 0;

  /// Every list of on-key accounts the screens had saved, in order.
  final List<List<KeyAccount>> keyAccountSaves = [];

  /// What proves a key's code password, as the vault would remember it, by key.
  final Map<String, Uint8List> keyAccesses = {};

  @override
  VaultState build() => initial;

  @override
  Future<void> updateAccount(OtpAccount updated) async {
    this.updated.add(updated);
    if (apply) state = state.copyWith(accounts: [for (final a in state.accounts) a.id == updated.id ? updated : a]);
  }

  @override
  Future<void> reorderAccounts(List<String> orderedIds) async {
    reordered.add(orderedIds);
    if (!apply) return;
    final position = {for (final (i, id) in orderedIds.indexed) id: i};
    state = state.copyWith(accounts: [for (final a in state.accounts) position.containsKey(a.id) ? a.copyWith(order: position[a.id]) : a]);
  }

  @override
  Future<void> deleteAccount(OtpAccount removed) async => deleted.add(removed);

  /// What the vault remembers of the accounts on keys is kept in memory,
  /// whatever [apply] says: reading a key is nothing without it.
  @override
  Future<bool> saveKeyAccounts(List<KeyAccount> next) async {
    keyAccountSaves.add(next);
    state = state.copyWith(keyAccounts: next);
    return true;
  }

  @override
  Future<Uint8List?> keyAccess(String device) async => keyAccesses[device];

  @override
  Future<bool> rememberKeyAccess(String device, Uint8List accessKey) async {
    keyAccesses[device] = accessKey;
    return true;
  }

  @override
  Future<bool> forgetKeyAccess(String device) async {
    keyAccesses.remove(device);
    return true;
  }

  @override
  void lock() => locks++;
}

/// Overrides the vault controller with [fake].
Override fakeVault(FakeVaultController fake) => vaultControllerProvider.overrideWith(() => fake);

/// A clock that starts at [startMs] (Unix ms) and moves with the test's
/// fake time, so `tester.pump(duration)` moves it on as timers fire.
Override movingClock(WidgetTester tester, int startMs) {
  final origin = tester.binding.clock.now();
  return clockProvider.overrideWithValue(
    () => DateTime.fromMillisecondsSinceEpoch(startMs + tester.binding.clock.now().difference(origin).inMilliseconds),
  );
}

/// [pumpScreen], with the clock at [atMs] (Unix ms) moving on with the
/// test's fake time (see [movingClock]) instead of standing still.
Future<ProviderContainer> pumpAt(
  WidgetTester tester,
  Widget child, {
  required int atMs,
  Brightness brightness = Brightness.dark,
  KeyValueStore? store,
  List<Override> overrides = const [],
  bool reducedMotion = true,
}) async {
  if (reducedMotion) useReducedMotion(tester);
  final container = ProviderContainer(
    overrides: [
      messageCatalogProvider.overrideWithValue(testCatalog),
      keyValueStoreProvider.overrideWithValue(store ?? KeyValueStore.memory()),
      movingClock(tester, atMs),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  _screens.add(container);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      key: ObjectKey(container),
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(brightness),
        debugShowCheckedModeBanner: false,
        localizationsDelegates: localizationsDelegates(testCatalog),
        supportedLocales: supportedLocales,
        builder: (context, child) => ToastHost(child: child!),
        home: child,
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Stands in for the system clipboard: records what is copied and gives
/// back the last of it.
class FakeClipboard {
  FakeClipboard() {
    answerSensitiveCopies(writes.add);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          writes.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
          return null;
        case 'Clipboard.getData':
          return {'text': writes.lastOrNull};
        case 'Clipboard.hasStrings':
          return {'value': writes.isNotEmpty};
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  final List<String?> writes = [];

  String? get text => writes.lastOrNull;
}

/// The code a [CodeDigits] shows, found by its grouped digits ("287 082"),
/// as screen readers hear it.
Finder findCode(String grouped) => find.byWidgetPredicate((w) => w is CodeDigits && CodeDigits.grouped(w.code) == grouped);

/// The containers [pumpAt] made in this test.
final _screens = <ProviderContainer>[];

/// Takes the screen away and disposes what [pumpAt] made, so the second
/// ticker and a clipboard waiting to be cleared stop. Flutter fails a test
/// that ends with a timer running, and the ticker's provider isn't
/// disposed when its whole provider scope leaves at once, as it does at
/// the end of a test.
Future<void> leaveScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (final container in _screens) {
    container.dispose();
  }
  _screens.clear();
}

/// A widget test of something that shows codes, which [leaveScreen]s at the end.
void testCodes(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
  await body(tester);
  await leaveScreen(tester);
});
