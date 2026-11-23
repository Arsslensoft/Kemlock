import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_reminders.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/features/lock/unlock_attempts.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/shared_items.dart';
import 'package:kemlock/platform/unlock_keys.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_reminders.dart';
import '../fakes/fake_shared_items.dart';
import '../fakes/fake_unlock_keys.dart';
import '../features/keys/pgp_kit.dart';
import '../helpers/old_biometric_entry.dart';
import 'fast_kdf.dart';
import 'old_vault.dart' show makeVaultOld;
import 'rotation_helpers.dart' show newKit;

class FakeBiometrics implements Biometrics {
  bool available = true;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async => true;
}

/// A vault store whose saves fail on demand, as a full disk would.
class FlakyVaultStore extends VaultStore {
  FlakyVaultStore(super.store, super.vaults, UnlockKeys unlockKeys) : super(deriveKey: fastKdf, unlockKeys: unlockKeys);

  bool failSaves = false;

  @override
  Future<void> saveAccounts(List<OtpAccount> accounts, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveAccounts(accounts, session);

  @override
  Future<void> saveBackupServices(List<BackupService> services, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveBackupServices(services, session);

  @override
  Future<void> saveKeys(List<VaultKey> keys, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveKeys(keys, session);

  @override
  Future<void> saveContacts(List<Contact> contacts, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveContacts(contacts, session);
}

/// Someone's public key, checked on a day in early November.
const _grace = Contact(
  id: 'c1',
  name: 'Grace Hopper',
  publicKey: 'mDMEavvBvhYJKwYBBAHaRw8BAQdA',
  source: ContactSource.qr,
  checkedAt: 1_793_700_000_000,
  checkedFingerprint: '894F6AAC8FCE0FAF7EE21BB6B405E72AFBA23495',
  addedAt: 0,
);
const _alan = Contact(id: 'c2', name: 'Alan Turing', publicKey: 'mDMEavvBxRYJ', source: ContactSource.file, addedAt: 0);

/// Reads a one-byte public half as a PGP key expiring at 17:00 UTC on that day of January 2095.
crypto.PgpKeyInfo readDay(Uint8List public) => crypto.PgpKeyInfo(
  crypto.PgpKey(
    version: 4,
    fingerprint: Uint8List(20),
    algorithm: 'ed25519',
    created: DateTime.utc(2020),
    expires: DateTime.utc(2095, 1, public.single, 17),
    hasSecret: false,
    protected: false,
    revoked: false,
  ),
  const ['Ada <ada@example.org>'],
  const [],
);

const _github = OtpAccount(id: '', issuer: 'GitHub', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _gitlab = OtpAccount(id: '', issuer: 'GitLab', label: 'me', secret: 'GEZDGNBVGY3TQOJQ', addedAt: 0);

void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late FlakyVaultStore vaultStore;
  late FakeBiometrics biometrics;
  late FakeUnlockKeys unlockKeys;
  late FakeReminders reminders;
  late FakeSharedItems shared;

  /// Where shared files wait, for the tests that share one.
  Directory? shareRoot;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 10, 16, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
    // The app's localizations load them before any screen shows
    await initializeDateFormatting('en');
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    unlockKeys = FakeUnlockKeys();
    vaultStore = FlakyVaultStore(store, vaults, unlockKeys);
    biometrics = FakeBiometrics();
    now = DateTime.utc(2026, 10, 16, 12);
    reminders = FakeReminders();
    shared = FakeSharedItems();
    shareRoot = null;
    container = ProviderContainer(
      overrides: [
        reminders.asOverride,
        shared.asOverride,
        shareTempRootProvider.overrideWithValue(() async => shareRoot!),
        pgpKeyInfoReaderProvider.overrideWithValue(readDay),
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(catalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(biometrics),
        unlockKeys.asOverride,
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);
  VaultState state() => container.read(vaultControllerProvider);
  ToastMessage? toast() => container.read(toastsProvider);
  String t(String id, [Map<String, Object?> args = const {}]) => catalog.of(AppLocale.en).t(id, args);

  Future<VaultSession> openNew([String password = 'pw']) async {
    final session = await vaultStore.setupVault(password);
    await controller().open(session);
    return session;
  }

  group('the vault gate', () {
    test('starts at setup without a vault and locked with one', () async {
      expect(state().phase, VaultPhase.setup);

      await vaultStore.setupVault('pw');
      container.invalidate(vaultControllerProvider);

      expect(state().phase, VaultPhase.locked);
    });

    test('opens a vault with its accounts and services, and remembers it', () async {
      final session = await vaultStore.setupVault('pw');
      await vaultStore.saveAccounts([_github.copyWith(id: 'a1', addedAt: 1)], session);
      await vaultStore.saveBackupServices([const BackupService(id: 's1', serviceName: 'GitHub', codes: [], addedAt: 1)], session);

      await controller().open(session);

      expect(state().isUnlocked, isTrue);
      expect(state().accounts.single.id, 'a1');
      expect(state().backupServices.single.id, 's1');
      expect(state().vault, const VaultInfo(id: mainVault));
      expect(vaults.startingVault(), mainVault);
    });

    test('goes back to the lock screen when the data does not decrypt', () async {
      final session = await vaultStore.setupVault('pw');
      store.setItem('backmycodes_vault_data', '{"kemCT":"AAAA","nonce":"AAAA","ct":"AAAA"}');

      await controller().open(session);

      expect(state().phase, VaultPhase.locked);
      expect(state().session, isNull);
      expect(toast()?.message, t('app.snack.unlockFailed'));
      expect(toast()?.severity, ToastSeverity.error);
    });

    test('offers biometric unlock when the phone has it and the vault has none', () async {
      await openNew();

      expect(state().offerBiometric, isTrue);
      controller().biometricOffered();
      expect(state().offerBiometric, isFalse);
    });

    test('offers no biometric unlock without biometrics the hardware key can use, once set up, or for a hidden vault', () async {
      // local_auth would show a prompt (a weak face unlock), but the key needs Class 3
      unlockKeys.available = false;
      await openNew();
      expect(state().offerBiometric, isFalse);

      unlockKeys.available = true;
      await writeOldBiometricEntry(store, vaults, state().session!);
      await controller().open(state().session!);
      expect(state().offerBiometric, isFalse);

      final hidden = await vaultStore.createVault('Diary', 'other', listed: false);
      await controller().open(await vaultStore.unlockAnyVault('other', hidden));
      expect(state().vault.hidden, isTrue);
      expect(state().offerBiometric, isFalse);
    });

    test('offers biometric unlock again to a vault that gave it up moving over to authenticated values', () async {
      final session = await vaultStore.setupVault('pw');
      await makeVaultOld(store, vaults, vaultStore, session, 'pw');
      await vaultStore.enableBiometricUnlock(session, 'Turn it on');
      expect(vaultStore.hasBiometricUnlock(), isTrue);

      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));

      expect(vaultStore.hasBiometricUnlock(), isFalse);
      expect(state().session!.authenticated, isTrue);
      expect(state().offerBiometric, isTrue);
    });

    test('offers biometric unlock again after a password unlock deleted the old entry', () async {
      final session = await vaultStore.setupVault('pw');
      await writeOldBiometricEntry(store, vaults, session);

      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));

      expect(store.getItem('backmycodes_native_bio'), isNull);
      expect(state().offerBiometric, isTrue);
      expect(state().keyExposed, isTrue);
    });

    // openspec: add-security-key-unlock, task 4.7
    test('offers no biometric unlock while the vault needs a security key, and offers it again in mode "password"', () async {
      final session = await openNew();
      controller().biometricOffered();
      await vaultStore.setRecoveryKey(session, newKit());
      final key = (credential: randomBytes(64), output: randomBytes(32));
      var proof = await vaultStore.enrolKey(
        session,
        await vaultStore.proveOwner(password: 'pw'),
        salt: vaultStore.keyChallenge().salt,
        credential: key.credential,
        output: key.output,
        name: 'Example Key',
        pinBound: true,
      );

      proof = await vaultStore.setUnlockMode(session, proof, UnlockMode.both);
      await controller().open(session);
      expect(state().isUnlocked, isTrue);
      expect(state().offerBiometric, isFalse);
      // Nor after its key pair was replaced
      await controller().replaceKey('', kit: newKit(), proof: proof);
      expect(state().offerBiometric, isFalse);
      final replaced = state().session!;

      final step = await vaultStore.beginUnlock('pw', mainVault) as UnlockNeedsKey;
      proof = await vaultStore.proveOwner(password: 'pw', key: key);
      await vaultStore.unlockWithSecurityKey(mainVault, key, pending: step.pending);
      await vaultStore.setUnlockMode(replaced, proof, UnlockMode.password);
      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));
      expect(state().offerBiometric, isTrue);
    });

    test('says once how many wrong passwords there were before it opened, and nothing without any', () async {
      final session = await vaultStore.setupVault('pw');
      final last = now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;

      await controller().open(session, failures: UnlockFailures(count: 2, last: last));

      final args = failuresArgs(
        UnlockFailures(count: 2, last: last),
        now: now,
        locale: 'en',
      );
      expect(args['when'], 'earlier');
      expect(toast()?.message, t('vault.failures.report', args));
      expect(toast()?.severity, ToastSeverity.info);

      container.read(toastsProvider.notifier).dismiss();
      await controller().open(session, failures: UnlockFailures(count: 1, last: last), phoneSlot: true);
      expect(
        toast()?.message,
        t(
          'vault.failures.reportPhone',
          failuresArgs(
            UnlockFailures(count: 1, last: last),
            now: now,
            locale: 'en',
          ),
        ),
      );

      container.read(toastsProvider.notifier).dismiss();
      await controller().open(session);
      expect(toast(), isNull);
    });

    test('locks and forgets the keys and contents', () async {
      await openNew();
      await controller().addAccount(_github);

      controller().lock();

      expect(state().phase, VaultPhase.locked);
      expect(state().session, isNull);
      expect(state().accounts, isEmpty);
    });

    test('switches to another listed vault by locking onto it', () async {
      await openNew('first');
      final work = await vaultStore.createVault('Work', 'second', listed: true);

      controller().switchVault(work);

      expect(state().phase, VaultPhase.locked);
      expect(vaults.startingVault(), work);
      expect(state().vault.id, work);
    });

    test('deletes the open vault, going to setup when it was the last', () async {
      await openNew();

      controller().deleteVault();

      expect(state().phase, VaultPhase.setup);
      expect(vaultStore.isVaultSetup(), isFalse);
    });

    test("deletes the open vault's biometric unlock key with it, and no other", () async {
      await openNew('first');
      final work = await vaultStore.createVault('Work', 'second', listed: true);
      final session = await vaultStore.unlockAnyVault('second', work);
      await vaultStore.enableBiometricUnlock(session, 'Turn it on');
      await controller().open(session);
      vaults.active = mainVault;
      await vaultStore.enableBiometricUnlock(await vaultStore.unlockAnyVault('first', mainVault), 'Turn it on');
      vaults.active = work;

      controller().deleteVault();
      await pumpEventQueue();

      expect(unlockKeys.calls.last, 'delete $work');
      expect(unlockKeys.keys.keys, [mainVault]);
    });

    test("deletes every vault's biometric unlock key when every vault is wiped", () async {
      final session = await openNew();
      await vaultStore.enableBiometricUnlock(session, 'Turn it on');

      vaultStore.wipeVault();
      controller().wiped();
      await pumpEventQueue();

      expect(unlockKeys.calls.last, 'deleteAll');
      expect(unlockKeys.keys, isEmpty);
    });

    test('forgets a shared file waiting when every vault is wiped, deletes it and clears the native side once', () async {
      final root = shareRoot = Directory.systemTemp.createTempSync('share-wipe');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      await vaultStore.setupVault('pw');
      container.invalidate(vaultControllerProvider);
      final file = File('${root.path}${Platform.pathSeparator}ab12${Platform.pathSeparator}contract.pdf')
        ..createSync(recursive: true)
        ..writeAsStringSync('the contract');
      container.listen(pendingShareProvider, (_, _) {});
      shared.send(SharedFile(path: file.path, name: 'contract.pdf', size: 12));
      await pumpEventQueue();
      expect(container.read(pendingShareProvider), isA<SharedFile>());

      vaultStore.wipeVault();
      controller().wiped();
      await pumpEventQueue();

      expect(container.read(pendingShareProvider), isNull);
      expect(file.existsSync(), isFalse);
      expect(shared.clears, 1);
    });

    test('deletes the open vault, going to the lock screen when others are left', () async {
      await openNew('first');
      final work = await vaultStore.createVault('Work', 'second', listed: true);
      await controller().open(await vaultStore.unlockAnyVault('second', work));

      controller().deleteVault();

      expect(state().phase, VaultPhase.locked);
      expect(vaults.allVaultIds(), [mainVault]);
    });

    test('re-reads the name after Settings changed it', () async {
      await openNew();
      vaultStore.renameVault(mainVault, 'Personal');

      controller().vaultChanged();

      expect(state().vault.name, 'Personal');
    });
  });

  group('accounts', () {
    test('adds an account with an id, the time and a stamp, saved encrypted', () async {
      final session = await openNew();

      await controller().addAccount(_github);

      final added = state().accounts.single;
      expect(added.id, isNotEmpty);
      expect(added.addedAt, now.millisecondsSinceEpoch);
      expect(added.updatedAt, now.millisecondsSinceEpoch);
      expect(await vaultStore.loadAccounts(session), [added]);
      expect(toast()?.message, t('app.snack.accountAdded', {'name': 'GitHub'}));
      expect(state().revision, 1);
    });

    test('refuses an account with the same issuer and secret', () async {
      await openNew();
      await controller().addAccount(_github);

      await controller().addAccount(_github.copyWith(label: 'other'));

      expect(state().accounts, hasLength(1));
      expect(toast()?.message, t('app.snack.accountExists'));
      expect(state().revision, 1);
    });

    test('adds several at once, skipping ones already saved or repeated', () async {
      await openNew();
      await controller().addAccount(_github);

      await controller().addAccounts([_github, _gitlab, _gitlab]);

      expect(state().accounts.map((a) => a.issuer), ['GitHub', 'GitLab']);
      expect(toast()?.message, t('app.snack.accountsAdded', {'count': 1, 'dupCount': 2}));
      expect(toast()?.severity, ToastSeverity.success);
    });

    test('says so, without saving, when every one is already there', () async {
      await openNew();
      await controller().addAccount(_github);

      await controller().addAccounts([_github]);

      expect(toast()?.severity, ToastSeverity.info);
      expect(state().revision, 1);
    });

    test('stamps only the account that changed', () async {
      await openNew();
      await controller().addAccounts([_github, _gitlab]);
      final [github, gitlab] = state().accounts;
      now = now.add(const Duration(minutes: 1));

      await controller().updateAccount(github.copyWith(note: 'work'));

      expect(state().accounts.first.note, 'work');
      expect(state().accounts.first.updatedAt, now.millisecondsSinceEpoch);
      expect(state().accounts.last, gitlab);
    });

    test('puts the list back when an edit fails to save', () async {
      await openNew();
      await controller().addAccount(_github);
      final before = state().accounts;
      vaultStore.failSaves = true;

      await controller().updateAccount(before.single.copyWith(note: 'lost'));

      expect(state().accounts, before);
      expect(toast()?.message, t('app.snack.accountUpdateFailed'));
    });

    test('saves a custom order', () async {
      await openNew();
      await controller().addAccounts([_github, _gitlab]);
      final [github, gitlab] = state().accounts;

      await controller().reorderAccounts([gitlab.id, github.id]);

      expect({for (final a in state().accounts) a.issuer: a.order}, {'GitHub': 1, 'GitLab': 0});
    });

    test('removes an account and brings it back where it was with Undo', () async {
      final session = await openNew();
      await controller().addAccounts([_github, _gitlab]);
      final github = state().accounts.first;

      await controller().deleteAccount(github);

      expect(state().accounts.map((a) => a.issuer), ['GitLab']);
      expect(toast()?.message, t('app.snack.accountRemoved', {'name': 'GitHub'}));
      expect(toast()?.actionLabel, t('app.undo'));

      now = now.add(const Duration(seconds: 3));
      toast()!.onAction!();
      await pumpEventQueue();

      expect(state().accounts.map((a) => a.issuer), ['GitHub', 'GitLab']);
      // Stamped as just changed, so it outlives a deletion sync may already have shared
      expect(state().accounts.first.updatedAt, now.millisecondsSinceEpoch);
      expect((await vaultStore.loadAccounts(session)).map((a) => a.issuer), ['GitHub', 'GitLab']);
    });

    test('Undo after another vault was opened puts nothing into that vault', () async {
      await openNew();
      final diary = await vaultStore.createVault('Diary', 'other', listed: false);
      await controller().open(await vaultStore.unlockAnyVault('other', diary));
      await controller().addAccount(_github);
      await controller().deleteAccount(state().accounts.single);
      final undo = toast()!.onAction!;

      // The toast is still up when the vault locks and the first one is opened
      controller().lock();
      final first = await vaultStore.unlockAnyVault('pw', mainVault);
      await controller().open(first);
      undo();
      await pumpEventQueue();

      expect(state().accounts, isEmpty);
      expect(await vaultStore.loadAccounts(first), isEmpty);
    });

    test('says so when a removal fails to save', () async {
      await openNew();
      await controller().addAccount(_github);
      vaultStore.failSaves = true;

      await controller().deleteAccount(state().accounts.single);

      expect(state().accounts, hasLength(1));
      expect(toast()?.message, t('app.snack.accountRemoveFailed'));
    });
  });

  group('backup services', () {
    test('adds a service with unused codes', () async {
      await openNew();

      await controller().addBackupService('GitHub', ['1111', '2222']);

      final service = state().backupServices.single;
      expect(service.codes.map((c) => c.toJson()), [
        {'code': '1111', 'used': false},
        {'code': '2222', 'used': false},
      ]);
      expect(toast()?.message, t('app.snack.backupSaved', {'name': 'GitHub'}));
    });

    test('marks a code used, remembering when, and unused again', () async {
      await openNew();
      await controller().addBackupService('GitHub', ['1111', '2222']);
      final id = state().backupServices.single.id;

      await controller().setBackupCodeUsed(id, 1, true);
      expect(state().backupServices.single.codes[1].usedAt, now.millisecondsSinceEpoch);

      await controller().setBackupCodeUsed(id, 1, false);
      expect(state().backupServices.single.codes[1].toJson(), {'code': '2222', 'used': false});
    });

    test('deletes a service', () async {
      await openNew();
      await controller().addBackupService('GitHub', ['1111']);

      await controller().deleteBackupService(state().backupServices.single.id);

      expect(state().backupServices, isEmpty);
      expect(toast()?.message, t('app.snack.backupDeleted'));
    });
  });

  test('takes an import, counting the accounts it saved', () async {
    final session = await openNew();

    await controller().imported(
      [_github.copyWith(id: 'a', addedAt: 1), _gitlab.copyWith(id: 'b', addedAt: 1)],
      const [BackupService(id: 's', serviceName: 'GitHub', codes: [], addedAt: 1)],
    );

    expect(await vaultStore.loadAccounts(session), hasLength(2));
    expect(await vaultStore.loadBackupServices(session), hasLength(1));
    expect(toast()?.message, t('app.snack.importSuccess', {'count': 2}));
  });

  test("saves what sync merged without counting it as the user's change", () async {
    final session = await openNew();
    final synced = Lists(
      accounts: [_github.copyWith(id: 'a', addedAt: 1)],
      backupServices: const [],
    );

    await controller().applySynced(synced);

    expect(state().accounts.single.id, 'a');
    expect(state().revision, 0);
    expect((await vaultStore.loadAccounts(session)).single.id, 'a');
  });

  test('keeps the new session after a password change', () async {
    final session = await openNew();
    final changed = await vaultStore.changePassword(session, 'new');

    controller().passwordChanged(changed);

    expect(state().session, same(changed));
    expect(toast()?.message, t('app.snack.passwordChanged'));
  });

  // openspec: replace-vault-key-pair, tasks 4.1 and 6.1
  group('replacing the key pair', () {
    test('goes on with the new key pair and offers biometric unlock again', () async {
      final old = await openNew();
      await vaultStore.enableBiometricUnlock(old, 'Unlock');
      controller().biometricOffered();

      final next = await controller().replaceKey('pw');

      expect(state().session, same(next));
      expect(next.secretKey, isNot(old.secretKey));
      expect(state().replacingKey, isFalse);
      expect(vaultStore.hasBiometricUnlock(), isFalse);
      expect(state().offerBiometric, isTrue);
    });

    test('offers no biometric unlock where the phone has none the key can use', () async {
      await openNew();
      unlockKeys.available = false;

      await controller().replaceKey('pw');

      expect(state().offerBiometric, isFalse);
    });

    test('says it is replacing for as long as it runs', () async {
      await openNew();
      final seen = <bool>[];
      container.listen(vaultControllerProvider.select((s) => s.replacingKey), (_, replacing) => seen.add(replacing));

      await controller().replaceKey('pw');

      expect(seen, [true, false]);
    });

    test('an edit made during the replacement is saved afterwards with the new key', () async {
      await openNew();

      final replacing = controller().replaceKey('pw');
      final adding = controller().addAccount(_github);
      final next = await replacing;
      await adding;

      expect(state().accounts.map((a) => a.issuer), ['GitHub']);
      expect((await vaultStore.loadAccounts(next)).map((a) => a.issuer), ['GitHub']);
      expect(store.getItem(keyKeyRotation), isNull);
    });

    test('keeps the session and says nothing changed when the password is wrong', () async {
      final old = await openNew();

      await expectLater(controller().replaceKey('not it'), throwsA(isA<IncorrectPasswordError>()));

      expect(state().session, same(old));
      expect(state().replacingKey, isFalse);
    });

    test('goes on with the new key pair when some values open with neither key', () async {
      final old = await openNew();
      store.setItem('backmycodes_damaged', '{"kemCT":"AAAA","nonce":"AAAA","ct":"AAAA"}');

      final error = await controller()
          .replaceKey('pw')
          .then<KeyReplacementIncomplete?>((_) => null, onError: (Object e) => e as KeyReplacementIncomplete);

      expect(state().session, same(error!.session));
      expect(state().session!.secretKey, isNot(old.secretKey));
      expect(state().replacingKey, isFalse);
    });
  });

  // openspec: replace-vault-key-pair, task 5.4
  group('a vault known to be exposed', () {
    Future<VaultSession> openWith(Map<String, Object?>? keyInfo) async {
      final session = await vaultStore.setupVault('pw');
      if (keyInfo != null) await vaultStore.saveEncryptedValue(keyKeyInfo, keyInfo, session);
      await controller().open(session);
      return session;
    }

    test('and never asked is offered a new key pair, once', () async {
      await openWith({'exposed': true, 'asked': false});

      expect(state().keyExposed, isTrue);
      expect(state().offerKeyReplacement, isTrue);

      await controller().keyReplacementOffered();
      expect(state().offerKeyReplacement, isFalse);
      expect(state().keyExposed, isTrue);
      controller().lock();
      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));
      expect(state().offerKeyReplacement, isFalse);
      expect(state().keyExposed, isTrue);
    });

    test('and asked already is exposed, and not offered again', () async {
      await openWith({'exposed': true, 'asked': true});

      expect(state().keyExposed, isTrue);
      expect(state().offerKeyReplacement, isFalse);
    });

    test('not exposed is neither', () async {
      await openWith(null);

      expect(state().keyExposed, isFalse);
      expect(state().offerKeyReplacement, isFalse);
    });

    test('is neither once its key pair is replaced', () async {
      await openWith({'exposed': true, 'asked': false});

      await controller().replaceKey('pw');

      expect(state().keyExposed, isFalse);
      expect(state().offerKeyReplacement, isFalse);
      controller().lock();
      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));
      expect(state().keyExposed, isFalse);
    });

    test('opens even when what is known about its key pair won’t open', () async {
      final session = await vaultStore.setupVault('pw');
      store.setItem(keyKeyInfo, '{"kemCT":"AAAA","nonce":"AAAA","ct":"AAAA"}');

      await controller().open(session);

      expect(state().isUnlocked, isTrue);
      expect(state().keyExposed, isFalse);
    });
  });

  group('changing a PGP key', () {
    final changedAt = DateTime.utc(2026, 11, 20, 12);

    Future<VaultKey> held() async {
      await openNew();
      await controller().addKey(await pgpVaultKey(updatedAt: 1));
      return state().keys.single;
    }

    Future<crypto.ParsedKey> changed(VaultKey key, crypto.PgpChange change) =>
        crypto.makeKey(crypto.PgpChangeRequest(unb64(key.privateKey), change, now: changedAt));

    test('a changed key is saved under its id, with a new updatedAt', () async {
      final key = await held();
      final grown = await changed(key, const crypto.AddPgpUserId(name: 'Ada', email: 'ada@work.example'));
      now = DateTime.utc(2026, 10, 17, 9);

      expect(await controller().replaceKeyHalves(key, grown.private, grown.public!), isTrue);

      final saved = state().keys.single;
      expect((saved.id, saved.name, saved.addedAt), (key.id, key.name, key.addedAt));
      expect((saved.privateKey, saved.publicKey), (b64(grown.private), b64(grown.public!)));
      expect(saved.updatedAt, now.millisecondsSinceEpoch);
      expect(await vaultStore.loadKeys(state().session!), [saved]);
    });

    test('bytes of another key, missing a packet, or that do not read are refused, the vault as it was', () async {
      final key = await held();
      final other = await pgpVaultKey(path: 'gnupg/editing/protected.secret.asc');
      // GnuPG's copy of the key after it changed it holds the latest self-signatures only
      final after = await pgpVaultKey(path: 'gnupg/editing/signing-subkey.after.secret.asc');
      final grown = await changed(key, const crypto.SetPgpExpiry(null, alsoSubkeys: true));
      for (final (private, public) in [
        (unb64(other.privateKey), unb64(other.publicKey!)),
        (unb64(after.privateKey), unb64(after.publicKey!)),
        (Uint8List.fromList([1, 2, 3]), grown.public!),
        (grown.private, unb64(other.publicKey!)),
      ]) {
        expect(await controller().replaceKeyHalves(key, private, public), isFalse);
        expect(state().keys.single, key);
        expect(toast()?.message, t('vault.snack.keyUpdateFailed'));
      }
      expect(await vaultStore.loadKeys(state().session!), [key]);
    });

    test('a failed save puts the list back', () async {
      final key = await held();
      final grown = await changed(key, const crypto.SetPgpExpiry(null, alsoSubkeys: true));
      vaultStore.failSaves = true;

      expect(await controller().replaceKeyHalves(key, grown.private, grown.public!), isFalse);
      expect(state().keys.single, key);
      expect(toast()?.message, t('vault.snack.keyUpdateFailed'));
    });
  });

  // openspec: add-pgp-contacts, task 3.4
  group('contacts', () {
    /// The two contacts as the vault holds them once added at the test clock.
    Future<void> addBoth() async {
      expect(await controller().addContact(_grace), isTrue);
      expect(await controller().addContact(_alan), isTrue);
    }

    void expectBoth() {
      expect(state().contacts.map((c) => c.name), ['Grace Hopper', 'Alan Turing']);
      expect((state().contacts.first.checkedAt, state().contacts.first.checkedFingerprint), (_grace.checkedAt, _grace.checkedFingerprint));
      expect(state().contacts.last.checkedAt, isNull);
    }

    test('are added as of now, saved sealed, and say so', () async {
      final session = await openNew();

      await addBoth();

      expectBoth();
      expect(state().contacts.first.addedAt, now.millisecondsSinceEpoch);
      expect(toast()?.message, t('vault.snack.contactAdded', {'name': 'Alan Turing'}));
      expect(await vaultStore.loadContacts(session), state().contacts);
      expect(store.getItem('backmycodes_contact_data'), isNot(contains('Grace')));
      expect(state().revision, 2);
    });

    test('are there after unlock by password', () async {
      await openNew();
      await addBoth();

      controller().lock();
      expect(state().contacts, isEmpty);
      await controller().open(await vaultStore.unlockVault('pw'));

      expectBoth();
    });

    test('are there after unlock by biometrics', () async {
      final session = await openNew();
      await addBoth();
      await vaultStore.enableBiometricUnlock(session, 'Turn it on');

      controller().lock();
      final unlock = await vaultStore.unlockWithBiometrics('Unlock', biometrics);
      await controller().open(unlock.session!);

      expectBoth();
    });

    test('are there after unlock by Recovery Kit', () async {
      final session = await openNew();
      await addBoth();
      final made = makeKit(2, 3);
      final kit = RecoveryKey(kitId: made.kitId, key: made.key, threshold: 2, shares: 3, createdAt: '2026-11-16T00:00:00.000Z');
      await vaultStore.setRecoveryKey(session, kit);

      controller().lock();
      await controller().open(await vaultStore.unlockWithRecoveryKey(kit.kitId, kit.key));

      expectBoth();
    });

    test('are still there after the master password changes', () async {
      final session = await openNew('old password');
      await addBoth();

      await vaultStore.changePassword(session, 'new password');
      controller().lock();
      await controller().open(await vaultStore.unlockVault('new password'));

      expectBoth();
    });

    test('a vault never given one opens with none, and writes no value for them', () async {
      await openNew();
      await controller().addAccount(_github);

      controller().lock();
      await controller().open(await vaultStore.unlockVault('pw'));

      expect(state().contacts, isEmpty);
      expect(store.getItem('backmycodes_contact_data'), isNull);
    });

    test('a failed save puts the list back and says so', () async {
      await openNew();
      await controller().addContact(_grace);
      final before = state().contacts;
      vaultStore.failSaves = true;

      expect(await controller().updateContact(before.single.unchecked()), isFalse);
      expect(state().contacts, before);
      expect(toast()?.message, t('vault.snack.contactUpdateFailed'));
      expect(toast()?.severity, ToastSeverity.error);

      expect(await controller().addContact(_alan), isFalse);
      expect(state().contacts, before);
      expect(toast()?.message, t('vault.snack.contactAddFailed'));

      await controller().deleteContact(before.single);
      expect(state().contacts, before);
      expect(toast()?.message, t('vault.snack.contactRemoveFailed'));
    });

    test('an import adds the contacts it is given, keeping their checks, and gives a taken id another', () async {
      final session = await openNew();
      await controller().addContact(_alan);
      final held = state().contacts.single;

      await controller().imported(const [], const [], contacts: [_grace.copyWith(id: held.id)]);

      expect(state().contacts.map((c) => c.name), ['Alan Turing', 'Grace Hopper']);
      final grace = state().contacts.last;
      expect(grace.id, isNot(held.id));
      expect((grace.checkedAt, grace.checkedFingerprint), (_grace.checkedAt, _grace.checkedFingerprint));
      expect(await vaultStore.loadContacts(session), state().contacts);
    });

    test('are among what sync is given, and what sync merged is saved without counting as a change', () async {
      final session = await openNew();
      await controller().addContact(_grace);
      expect(state().lists.contacts, state().contacts);
      final revision = state().revision;
      final stored = store.getItem('backmycodes_contact_data');

      // Nothing changed for contacts: their value is not written again
      await controller().applySynced(state().lists);
      expect(store.getItem('backmycodes_contact_data'), stored);

      final merged = [state().contacts.single.unchecked(), _alan];
      await controller().applySynced(Lists(contacts: merged));

      expect(state().contacts, merged);
      expect(state().revision, revision);
      expect(await vaultStore.loadContacts(session), merged);
    });

    test('an edit is stamped as changed', () async {
      final session = await openNew();
      await controller().addContact(_grace);
      now = now.add(const Duration(minutes: 5));

      expect(await controller().updateContact(state().contacts.single.copyWith(name: 'Grace')), isTrue);

      expect((state().contacts.single.name, state().contacts.single.updatedAt), ('Grace', now.millisecondsSinceEpoch));
      expect((await vaultStore.loadContacts(session)).single.name, 'Grace');
    });

    test('delete offers Undo, and Undo restores the contact with its check', () async {
      final session = await openNew();
      await addBoth();
      final grace = state().contacts.first;

      await controller().deleteContact(grace);

      expect(state().contacts.map((c) => c.name), ['Alan Turing']);
      expect((await vaultStore.loadContacts(session)).map((c) => c.name), ['Alan Turing']);
      expect(toast()?.message, t('vault.snack.contactRemoved', {'name': 'Grace Hopper'}));
      expect(toast()?.actionLabel, t('app.undo'));
      now = now.add(const Duration(seconds: 3));
      toast()!.onAction!();
      await pumpEventQueue();

      expectBoth();
      // Stamped as just changed, so it outlives a deletion sync already shared
      expect(state().contacts.first.updatedAt, now.millisecondsSinceEpoch);
      expect((await vaultStore.loadContacts(session)).first.checkedFingerprint, _grace.checkedFingerprint);
    });
  });

  group('key reminders follow the keys', () {
    // A PGP key whose public half is one byte, the day of January 2095 it expires on at 17:00 UTC
    VaultKey keyExpiringOn(int day, {String? id}) => VaultKey(
      id: id ?? 'k$day',
      name: 'Key $day',
      kind: KeyKind.pgp,
      algorithm: 'pgp',
      privateKey: base64.encode([day]),
      publicKey: base64.encode([day]),
      origin: KeyOrigin.imported,
      addedAt: 0,
    );
    DateTime expiryOf(int day) => DateTime.utc(2095, 1, day, 17);

    /// The ids [vault]'s keys expiring on [days] call for at the clock's time.
    Set<int> wanted(List<int> days, {String vault = mainVault}) => {
      for (final day in days)
        for (final before in reminderDaysBefore)
          if (DateTime.utc(2095, 1, day - before, 9).isAfter(now)) reminderId(vault, DateTime.utc(2095, 1, day - before, 9)),
    };

    Future<Set<int>> pending() async {
      await pumpEventQueue();
      return reminders.pending();
    }

    void turnOn([String vault = mainVault]) => store.setItem(vaults.vaultKey(prefsKey, vault), '{"keyReminders":true}');

    setUp(() => now = DateTime.utc(2094, 12, 20, 12));

    test('the helper counts three mornings for a key twelve days away', () {
      expect(wanted([1]), hasLength(3));
      expect(wanted([1]), {
        for (final reminder in wantedReminders([
          keyStanding(readDay(Uint8List.fromList([1])), now),
        ], now))
          reminderId(mainVault, reminder.when),
      });
      expect(expiryOf(1).difference(now).inDays, 12);
    });

    test('nothing is ever scheduled while reminders were never turned on', () async {
      await openNew();
      await controller().addKey(keyExpiringOn(1));
      controller().lock();
      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));

      expect(await pending(), isEmpty);
      expect(reminders.calls, isEmpty);
      expect(reminders.permissionRequests, 0);
    });

    test('unlocking schedules what the keys of the vault call for', () async {
      final session = await vaultStore.setupVault('pw');
      await vaultStore.saveKeys([keyExpiringOn(1), keyExpiringOn(10)], session);
      turnOn();

      await controller().open(session);

      expect(await pending(), wanted([1, 10]));
      expect(await pending(), hasLength(6));
    });

    test('adding, renaming and deleting a key each leave what its keys call for, and Undo brings it back', () async {
      await openNew();
      turnOn();

      await controller().addKey(keyExpiringOn(1));
      expect(await pending(), wanted([1]));

      await controller().addKey(keyExpiringOn(10));
      expect(await pending(), wanted([1, 10]));

      final calls = reminders.calls.length;
      await controller().updateKey(state().keys.first.copyWith(name: 'Renamed'));
      expect(await pending(), wanted([1, 10]));
      expect(reminders.calls, hasLength(calls), reason: 'a new name changes no notification');

      await controller().deleteKey(state().keys.first);
      expect(await pending(), wanted([10]));

      toast()!.onAction!();
      expect(await pending(), wanted([1, 10]));
    });

    test('an import that brings keys schedules theirs', () async {
      await openNew();
      turnOn();

      await controller().imported(const [], const [], keys: [keyExpiringOn(1), keyExpiringOn(10)]);

      expect(await pending(), wanted([1, 10]));
    });

    test('what sync merged replaces the schedule: a key added elsewhere, another deleted there', () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      expect(await pending(), wanted([1]));

      await controller().applySynced(Lists(keys: [keyExpiringOn(10)]));

      expect(await pending(), wanted([10]));
    });

    test('locking leaves the notifications, which are for the locked phone', () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      await pending();

      controller().lock();

      expect(await pending(), wanted([1]));
    });

    test('a later unlock drops the mornings that have passed', () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      expect(await pending(), hasLength(3));
      controller().lock();

      now = DateTime.utc(2094, 12, 31, 12);
      await controller().open(await vaultStore.unlockAnyVault('pw', mainVault));

      expect(await pending(), wanted([1]));
      expect(await pending(), hasLength(1));
    });

    test('a hidden vault schedules nothing, and hiding a vault takes its notifications back', () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      expect(await pending(), wanted([1]));

      vaults.setListed(mainVault, false);
      controller().vaultChanged();
      expect(state().vault.hidden, isTrue);
      expect(await pending(), isEmpty);

      await controller().addKey(keyExpiringOn(10));
      expect(await pending(), isEmpty);
      expect(store.getItem(keyKeyReminders), isNull);

      vaults.setListed(mainVault, true);
      controller().vaultChanged();
      expect(await pending(), wanted([1, 10]));
    });

    test("opening a hidden vault leaves the listed vault's notifications as they were", () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      final listed = await pending();
      controller().lock();
      // A second vault, hidden, with reminders on and a key of its own
      vaults.active = 'secret';
      final session = await vaultStore.setupVault('other');
      await vaultStore.saveKeys([keyExpiringOn(10)], session);
      vaults.setListed('secret', false);
      turnOn('secret');
      final calls = reminders.calls.length;

      await controller().open(session);

      expect(state().vault, const VaultInfo(id: 'secret', hidden: true));
      expect(state().keys.single.id, 'k10');
      expect(await pending(), listed);
      expect(reminders.calls, hasLength(calls));
      expect(store.getItem(keyKeyReminders), isNot(contains('secret')));
    });

    test("deleting the open vault cancels its notifications and leaves another vault's", () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      await pending();
      controller().lock();
      vaults.active = 'work';
      final session = await vaultStore.setupVault('other');
      vaults.setListed(mainVault, true);
      vaults.setListed('work', true);
      turnOn('work');
      await controller().open(session);
      await controller().addKey(keyExpiringOn(10));
      expect(await pending(), {
        ...wanted([1]),
        ...wanted([10], vault: 'work'),
      });

      controller().deleteVault();

      expect(await pending(), wanted([1]));
    });

    test('wiping every vault leaves no notification', () async {
      await openNew();
      turnOn();
      await controller().addKey(keyExpiringOn(1));
      await controller().addKey(keyExpiringOn(10));
      expect(await pending(), hasLength(6));

      // As the lock screen does: the storage first, then the controller
      vaults.removeAllVaults();
      controller().wiped();

      expect(await pending(), isEmpty);
      expect(store.getItem(keyKeyReminders), isNull);
    });
  });

  // openspec: add-security-key-codes, task 3.3
  group('accounts on a security key', () {
    const yubi = '0102030405060708';
    const other = 'aaaaaaaaaaaaaaaa';
    const listed = [
      KeyAccountSeen(name: 'Example:alice@example.org', type: KeyAccountType.totp, touch: false),
      KeyAccountSeen(name: '60/Slow:bob', type: KeyAccountType.totp, algorithm: 'SHA256', touch: true),
      KeyAccountSeen(name: 'Example:counter', type: KeyAccountType.hotp),
      KeyAccountSeen(name: '_hidden:Example:secret', type: KeyAccountType.totp),
    ];
    final accessKey = Uint8List.fromList(List.generate(16, (i) => i));

    KeyAccount named(String name) => state().keyAccounts.singleWhere((account) => account.name == name);

    test('a first read adds what the key lists, by its parts, and skips hidden names', () async {
      final session = await openNew();

      expect(await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed), isTrue);

      expect([for (final a in state().keyAccounts) a.name], ['Example:alice@example.org', '60/Slow:bob', 'Example:counter']);
      final slow = named('60/Slow:bob');
      expect((slow.issuer, slow.label, slow.period, slow.algorithm, slow.touch), ('Slow', 'bob', 60, 'SHA256', true));
      expect(slow.keyName, 'YubiKey 5C NFC');
      expect(slow.device, yubi);
      expect(slow.addedAt, now.millisecondsSinceEpoch);
      expect(named('Example:counter').type, KeyAccountType.hotp);
      expect(state().revision, 1);
      expect(await vaultStore.loadKeyAccounts(session), state().keyAccounts);
      expect(state().lists.keyAccounts, state().keyAccounts);
    });

    test('a second read of the same list writes nothing', () async {
      await openNew();
      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed);
      final stored = store.getItem('backmycodes_key_account_data');
      final before = state().keyAccounts;

      now = now.add(const Duration(minutes: 5));
      expect(await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed), isTrue);
      // Over NFC the key gives no name: the one known stays.
      expect(await controller().reconcileKey(yubi, null, listed), isTrue);

      expect(store.getItem('backmycodes_key_account_data'), stored, reason: 'not even sealed again');
      expect(identical(state().keyAccounts, before), isTrue);
      expect(state().revision, 1);
    });

    test('a name the key no longer lists is deleted, and leaves a tombstone at the next sync', () async {
      await openNew();
      await controller().reconcileKey(yubi, null, listed);
      final gone = named('Example:counter').id;
      final known = state().lists.ids.toList();

      await controller().reconcileKey(yubi, null, listed.sublist(0, 2));

      expect([for (final a in state().keyAccounts) a.name], ['Example:alice@example.org', '60/Slow:bob']);
      final merged = mergeScope(scopeLists(state().lists, null), known, null, now: now.millisecondsSinceEpoch);
      expect([for (final tomb in merged.doc.deleted) tomb.id], [gone]);
    });

    test('a name on both keeps its id, tags and note', () async {
      await openNew();
      await controller().reconcileKey(yubi, null, listed);
      final alice = named('Example:alice@example.org');
      expect(await controller().updateKeyAccount(alice.copyWith(tags: ['work'], note: 'admin')), isTrue);

      now = now.add(const Duration(minutes: 5));
      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', [
        listed[0],
        const KeyAccountSeen(name: 'New:carol', type: KeyAccountType.totp),
      ]);

      final after = named('Example:alice@example.org');
      expect(after.id, alice.id);
      expect(after.tags, ['work']);
      expect(after.note, 'admin');
      expect(after.addedAt, alice.addedAt);
      expect(after.keyName, 'YubiKey 5C NFC');
      expect([for (final a in state().keyAccounts) a.name], ['Example:alice@example.org', 'New:carol']);
    });

    test('a read that ended before the key said which accounts need a touch keeps what was known', () async {
      await openNew();
      await controller().reconcileKey(yubi, null, listed);

      await controller().reconcileKey(yubi, null, const [
        KeyAccountSeen(name: '60/Slow:bob', type: KeyAccountType.totp, algorithm: 'SHA256'),
      ]);

      expect(state().keyAccounts.single.touch, isTrue);
    });

    test('an account moved from the vault brings its tags and note', () async {
      await openNew();

      await controller().reconcileKey(yubi, null, const [
        KeyAccountSeen(name: 'Example:alice', type: KeyAccountType.totp, tags: ['bank'], note: 'moved'),
      ]);

      expect(state().keyAccounts.single.tags, ['bank']);
      expect(state().keyAccounts.single.note, 'moved');
    });

    test('another key’s entries are untouched', () async {
      await openNew();
      await controller().reconcileKey(other, 'Spare key', const [
        KeyAccountSeen(name: 'Example:alice@example.org', type: KeyAccountType.totp),
      ]);
      final spare = state().keyAccounts.single;

      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed);
      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', const []);

      expect(state().keyAccounts, [spare]);
    });

    test('forgetting a key removes its entries and its remembered proof, of that key only', () async {
      final session = await openNew();
      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed);
      await controller().reconcileKey(other, 'Spare key', const [
        KeyAccountSeen(name: 'Example:alice@example.org', type: KeyAccountType.totp),
      ]);
      expect(await controller().rememberKeyAccess(yubi, accessKey), isTrue);
      expect(await controller().rememberKeyAccess(other, Uint8List(16)), isTrue);
      expect(await controller().keyAccess(yubi), accessKey);

      expect(await controller().forgetKey(yubi), isTrue);

      expect([for (final a in state().keyAccounts) a.device], [other]);
      expect(await controller().keyAccess(yubi), isNull);
      expect(await controller().keyAccess(other), Uint8List(16));
      expect(await vaultStore.loadKeyAccess(session), {other: Uint8List(16)});

      expect(await controller().forgetKey(other), isTrue);
      expect(state().keyAccounts, isEmpty);
      expect(store.getItem('backmycodes_key_account_data'), isNull, reason: 'the vault holds nothing about a key any more');
      expect(store.getItem('backmycodes_key_access'), isNull);
    });

    test('they load when the vault opens, and go when it locks', () async {
      final session = await openNew();
      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed);
      final held = state().keyAccounts;

      controller().lock();
      expect(state().keyAccounts, isEmpty);
      expect(await controller().keyAccess(yubi), isNull);

      await controller().open(session);
      expect(state().keyAccounts, held);
    });

    test('an import adds each entry once, by key and name', () async {
      await openNew();
      await controller().reconcileKey(yubi, 'YubiKey 5C NFC', listed.sublist(0, 1));
      const incoming = [
        KeyAccount(id: 'x1', device: yubi, name: 'Example:alice@example.org', issuer: 'Example', label: 'alice@example.org', addedAt: 3),
        KeyAccount(id: 'x2', device: yubi, name: 'New:carol', issuer: 'New', label: 'carol', tags: ['t'], addedAt: 3),
      ];

      expect(await controller().addKeyAccounts(incoming), 1);
      expect(await controller().addKeyAccounts(incoming), 0);

      expect([for (final a in state().keyAccounts) a.name], ['Example:alice@example.org', 'New:carol']);
      expect(named('New:carol').id, isNot('x2'));
      expect(named('New:carol').tags, ['t']);
    });

    test('what sync merged is taken and saved', () async {
      final session = await openNew();
      const synced = KeyAccount(id: 'ka9', device: yubi, name: 'Example:alice', issuer: 'Example', label: 'alice', addedAt: 3);

      await controller().applySynced(Lists(accounts: state().accounts, keyAccounts: const [synced]));

      expect(state().keyAccounts, [synced]);
      expect(await vaultStore.loadKeyAccounts(session), [synced]);
      expect(state().revision, 0, reason: 'not a change of the person’s');
    });
  });
}
