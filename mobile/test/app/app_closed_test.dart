import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/app_closed_lock.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_app_closed.dart';
import '../fakes/fake_unlock_keys.dart';
import '../vault/fast_kdf.dart';

/// Closing the main screen for good locks the vault, now that the engine
/// outlives it (openspec: add-pgp-mail-provider, task 2.2).
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  group('the lock', () {
    test('locks at once with no hold', () {
      var locks = 0;
      AppClosedLock(holds: AutoLockHolds(), lock: () => locks++, shown: () => false).closed();
      expect(locks, 1);
    });

    testWidgets('waits for a hold, then locks with no screen in front', (tester) async {
      var locks = 0;
      final holds = AutoLockHolds();
      final release = holds.hold();
      final closedLock = AppClosedLock(holds: holds, lock: () => locks++, shown: () => false)..closed();
      await tester.pump(const Duration(seconds: 30));
      expect(locks, 0);
      release();
      await tester.pump(AppClosedLock.checkEvery);
      expect(locks, 1);
      await tester.pump(const Duration(seconds: 30));
      expect(locks, 1, reason: 'it locks once');
      closedLock.dispose();
    });

    testWidgets('does not lock when the hold ends with a screen in front', (tester) async {
      var locks = 0;
      final holds = AutoLockHolds();
      final release = holds.hold();
      final closedLock = AppClosedLock(holds: holds, lock: () => locks++, shown: () => true)..closed();
      release();
      await tester.pump(const Duration(seconds: 5));
      expect(locks, 0);
      closedLock.dispose();
    });

    testWidgets('a screen coming back ends the wait', (tester) async {
      var locks = 0;
      final holds = AutoLockHolds();
      final release = holds.hold();
      final closedLock = AppClosedLock(holds: holds, lock: () => locks++, shown: () => false)..closed();
      closedLock.shown();
      release();
      await tester.pump(const Duration(seconds: 5));
      expect(locks, 0);
      closedLock.dispose();
    });
  });

  group('in the app', () {
    late ProviderContainer container;
    late FakeAppClosedSignal signal;

    setUp(() async {
      final store = KeyValueStore.memory();
      final vaults = VaultRegistry(store);
      final vaultStore = VaultStore(store, vaults, deriveKey: fastKdf);
      signal = FakeAppClosedSignal();
      container = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(store),
          messageCatalogProvider.overrideWithValue(await MessageCatalog.load()),
          vaultRegistryProvider.overrideWithValue(vaults),
          vaultStoreProvider.overrideWithValue(vaultStore),
          FakeUnlockKeys(available: false).asOverride,
          signal.asOverride,
          appShownProvider.overrideWithValue(() => false),
        ],
      );
      addTearDown(container.dispose);
      await container.read(vaultControllerProvider.notifier).open(await vaultStore.setupVault('pw'));
      container.read(appClosedLockProvider);
    });

    bool unlocked() => container.read(vaultControllerProvider).isUnlocked;

    test('the message locks an open vault', () async {
      expect(unlocked(), isTrue);
      signal.close();
      await Future<void>.delayed(Duration.zero);
      expect(unlocked(), isFalse);
    });

    test('a hold keeps it open, and its end with no screen attached locks', () async {
      final release = container.read(autoLockHoldsProvider).hold();
      signal.close();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(unlocked(), isTrue);
      release();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(unlocked(), isFalse);
    });

    test('nothing happens where the message never comes, as on iOS', () async {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(unlocked(), isTrue);
    });
  });
}
