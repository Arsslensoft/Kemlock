import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../vault/fast_kdf.dart';

/// A vault store whose saves fail on demand, as a full disk would.
class _FlakyStore extends VaultStore {
  _FlakyStore(super.store, super.vaults) : super(deriveKey: fastKdf);

  bool failAccounts = false;
  bool failServices = false;

  @override
  Future<void> saveAccounts(List<OtpAccount> accounts, VaultSession session) =>
      failAccounts ? Future.error(Exception('disk full')) : super.saveAccounts(accounts, session);

  @override
  Future<void> saveBackupServices(List<BackupService> services, VaultSession session) =>
      failServices ? Future.error(Exception('disk full')) : super.saveBackupServices(services, session);
}

class _NoBiometrics implements Biometrics {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

const _added = 1_700_000_000_000;

OtpAccount _account(String id, {List<String>? dismissed}) =>
    OtpAccount(id: id, issuer: 'Trello', label: id, secret: 'JBSWY3DPEHPK3PXP', addedAt: _added, breachesDismissed: dismissed);

void main() {
  late MessageCatalog catalog;
  late _FlakyStore vaultStore;
  late VaultSession session;
  late ProviderContainer container;
  final now = DateTime.utc(2026, 11, 15, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  /// A vault holding two Trello accounts, one of another service and Trello's backup codes.
  setUp(() async {
    final store = KeyValueStore.memory();
    final vaults = VaultRegistry(store);
    vaultStore = _FlakyStore(store, vaults);
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(catalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(_NoBiometrics()),
        // No biometrics the hardware key could use, without the native side
        FakeUnlockKeys(available: false).asOverride,
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
    session = await vaultStore.setupVault('pw');
    await vaultStore.saveAccounts([_account('a1'), _account('a2'), _account('other')], session);
    await vaultStore.saveBackupServices([const BackupService(id: 's1', serviceName: 'Trello', codes: [], addedAt: _added)], session);
    await container.read(vaultControllerProvider.notifier).open(session);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);
  VaultState state() => container.read(vaultControllerProvider);
  ToastMessage? toast() => container.read(toastsProvider);
  String t(String id) => catalog.of(AppLocale.en).t(id);
  OtpAccount account(String id) => state().accounts.singleWhere((a) => a.id == id);
  BackupService service(String id) => state().backupServices.singleWhere((s) => s.id == id);

  test('marks a breach dealt with for one account, stamps it and saves it', () async {
    final revision = state().revision;

    await controller().dismissBreach('Trello', accountIds: ['a1']);

    expect(account('a1').breachesDismissed, ['Trello']);
    expect(account('a1').updatedAt, now.millisecondsSinceEpoch);
    expect(account('a2').breachesDismissed, isNull);
    expect(account('a2').updatedAt, isNull);
    expect(service('s1').breachesDismissed, isNull);
    expect(state().revision, revision + 1);
    expect(toast()!.message, t('breaches.snack.dealtWith'));
    expect(toast()!.actionLabel, t('app.undo'));
    final saved = await vaultStore.loadAccounts(session);
    expect(saved.singleWhere((a) => a.id == 'a1').breachesDismissed, ['Trello']);
  });

  test('marks it for every entry of a service at once', () async {
    await controller().dismissBreach('Trello', accountIds: ['a1', 'a2'], serviceIds: ['s1']);

    expect(account('a1').breachesDismissed, ['Trello']);
    expect(account('a2').breachesDismissed, ['Trello']);
    expect(service('s1').breachesDismissed, ['Trello']);
    expect(service('s1').updatedAt, now.millisecondsSinceEpoch);
    expect(account('other').breachesDismissed, isNull);
    expect((await vaultStore.loadBackupServices(session)).single.breachesDismissed, ['Trello']);
  });

  test('adds to the breaches an entry already dealt with', () async {
    await controller().dismissBreach('Trello', accountIds: ['a1']);
    await controller().dismissBreach('Trello2', accountIds: ['a1']);

    expect(account('a1').breachesDismissed, ['Trello', 'Trello2']);
  });

  test('Undo makes the breach new again for the same entries, and no others', () async {
    await controller().dismissBreach('Trello', accountIds: ['a2']);
    await controller().dismissBreach('Trello', accountIds: ['a1', 'a2'], serviceIds: ['s1']);

    toast()!.onAction!();
    await pumpEventQueue();

    // a2 was dealt with before, so the Undo of the second mark leaves it
    expect(account('a1').breachesDismissed, isNull);
    expect(account('a1').toJson().containsKey('breachesDismissed'), isFalse);
    expect(account('a2').breachesDismissed, ['Trello']);
    expect(service('s1').breachesDismissed, isNull);
    expect((await vaultStore.loadAccounts(session)).singleWhere((a) => a.id == 'a1').breachesDismissed, isNull);
  });

  test('does nothing for a breach that is already dealt with, or for ids the vault does not have', () async {
    await controller().dismissBreach('Trello', accountIds: ['a1']);
    container.read(toastsProvider.notifier).dismiss();
    final revision = state().revision;

    await controller().dismissBreach('Trello', accountIds: ['a1', 'missing'], serviceIds: ['missing']);

    expect(state().revision, revision);
    expect(toast(), isNull);
  });

  test('a failed save leaves the lists as they were and says so', () async {
    vaultStore.failAccounts = true;

    await controller().dismissBreach('Trello', accountIds: ['a1'], serviceIds: ['s1']);

    expect(account('a1').breachesDismissed, isNull);
    expect(service('s1').breachesDismissed, isNull);
    expect(toast()!.message, t('breaches.snack.failed'));
    expect(toast()!.severity, ToastSeverity.error);
    expect(toast()!.onAction, isNull);
  });

  test('when only the backup codes fail to save, the accounts go back too', () async {
    vaultStore.failServices = true;

    await controller().dismissBreach('Trello', accountIds: ['a1'], serviceIds: ['s1']);

    expect(account('a1').breachesDismissed, isNull);
    expect((await vaultStore.loadAccounts(session)).singleWhere((a) => a.id == 'a1').breachesDismissed, isNull);
    expect(toast()!.message, t('breaches.snack.failed'));
  });

  test('does nothing while the vault is locked', () async {
    controller().lock();

    await controller().dismissBreach('Trello', accountIds: ['a1']);

    expect(toast(), isNull);
  });
}
