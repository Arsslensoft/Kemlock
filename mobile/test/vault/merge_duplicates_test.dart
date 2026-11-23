import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/duplicates/dedup_store.dart';
import 'package:kemlock/features/duplicates/dedup_tagger.dart';
import 'package:kemlock/features/duplicates/duplicate_merge.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

class _NoBiometrics implements Biometrics {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// A vault store whose saves of logins fail on demand, as a full disk would.
class _FlakyStore extends VaultStore {
  _FlakyStore(super.store, super.vaults) : super(deriveKey: fastKdf);

  bool failSaves = false;

  @override
  Future<void> saveLogins(List<Login> logins, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveLogins(logins, session);
}

Login _login(String id, {String name = 'Proton', String password = 'one', String? accountId, String? spaceId}) => Login(
  id: id,
  name: name,
  username: 'sam',
  password: password,
  websites: const ['proton.me'],
  accountId: accountId,
  spaceId: spaceId,
  addedAt: 0,
);

// The plan's tasks 6.1 and 6.2: a merge, its roll-back and its Undo
void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late _FlakyStore vaultStore;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 11, 21, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = _FlakyStore(store, vaults);
    now = DateTime.utc(2026, 11, 21, 12);
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(catalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(_NoBiometrics()),
        FakeUnlockKeys(available: false).asOverride,
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);
  VaultState state() => container.read(vaultControllerProvider);
  ToastMessage? toast() => container.read(toastsProvider);
  String t(String id, [Map<String, Object?> args = const {}]) => catalog.of(AppLocale.en).t(id, args);
  void later(Duration by) => now = now.add(by);

  Future<VaultSession> openNew() async {
    final session = await vaultStore.setupVault('pw');
    await controller().open(session);
    return session;
  }

  /// Two logins one site and username apart, the second added a minute after the first.
  Future<void> twoLogins({String? spaceOfSecond}) async {
    await controller().addLogin(_login('a', name: 'proton.me', password: 'old'));
    later(const Duration(minutes: 1));
    await controller().addLogin(_login('b', name: 'Proton Mail', password: 'new', spaceId: spaceOfSecond));
  }

  /// Two codes of one secret, the second a minute newer, and a login linked to the first: the ids they were given.
  Future<({String root, String aws})> twoCodesAndALink() async {
    await controller().addAccount(OtpAccount(id: 'x', issuer: 'AWS root account', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
    later(const Duration(minutes: 1));
    await controller().addAccount(OtpAccount(id: 'y', issuer: 'Amazon Web Services', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
    final root = state().accounts.firstWhere((account) => account.issuer == 'AWS root account').id;
    final aws = state().accounts.firstWhere((account) => account.issuer == 'Amazon Web Services').id;
    await controller().addLogin(_login('l', name: 'AWS', accountId: root));
    return (root: root, aws: aws);
  }

  MergeChoices loginChoices({Set<String> readOnly = const {}}) => MergeChoices(dedupItems(logins: state().logins), readOnlySlots: readOnly);

  Future<List<MergeRecord>> records() async => (await DedupStore(vaultStore).loadAnswers(state().session!)).mergeRecords;

  group('a merge', () {
    test('keeps the newest login, loses no password and removes the other', () async {
      await openNew();
      await twoLogins();

      expect(await controller().mergeDuplicates(loginChoices()), isTrue);

      final login = state().logins.single;
      expect((login.id, login.name, login.password), ('b', 'Proton Mail', 'new'));
      expect(login.previousPasswords!.map((previous) => previous.password), ['old']);
      expect(toast()?.message, t('vault.snack.duplicatesMerged', {'count': 1}));
      expect(toast()?.actionLabel, t('app.undo'));
    });

    test('writes its record first, with both items as they were', () async {
      await openNew();
      await twoLogins();
      final before = state().logins;

      await controller().mergeDuplicates(loginChoices());

      final record = (await records()).single;
      expect(record.kind, 'login');
      expect(record.kept, before.last.toJson());
      expect(record.removed, [before.first.toJson()]);
      expect(record.undoable(now.millisecondsSinceEpoch), isTrue);
    });

    test('keeps the space\'s copy when the group is across places', () async {
      await openNew();
      await twoLogins(spaceOfSecond: 'team');
      // The vault's copy is the newer one, and the space's still stays
      later(const Duration(minutes: 5));
      await controller().updateLogin(state().logins.first.copyWith(name: 'Proton newest'));

      await controller().mergeDuplicates(loginChoices());

      final login = state().logins.single;
      expect((login.id, login.spaceId, login.name), ('b', 'team', 'Proton newest'));
    });

    test('merges each kind of item into one', () async {
      await openNew();
      await controller().addNote(const SecureNote(id: 'n1', title: 'Old', text: 'same', addedAt: 0));
      later(const Duration(minutes: 1));
      await controller().addNote(const SecureNote(id: 'n2', title: 'New', text: 'same', addedAt: 0));
      await controller().addAccount(OtpAccount(id: 'c1', issuer: 'Google', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
      later(const Duration(minutes: 1));
      await controller().addAccount(OtpAccount(id: 'c2', issuer: 'google.com', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
      await controller().addBackupService('GitLab', ['1', '2']);
      await controller().addBackupService('GitLab again', ['2', '1']);
      await controller().addCard(
        const PaymentCard(id: 'k1', name: 'Visa', number: '4111111111111111', expMonth: 12, expYear: 2030, addedAt: 0),
      );
      await controller().addCard(
        const PaymentCard(id: 'k2', name: 'Visa 2', number: '4111 1111 1111 1111', expMonth: 12, expYear: 2030, addedAt: 0),
      );
      await controller().addIdentity(const Identity(id: 'i1', name: 'Home', givenName: 'Sam', email: 'sam@example.org', addedAt: 0));
      await controller().addIdentity(const Identity(id: 'i2', name: 'Work', givenName: 'Sam', email: 'sam@example.org', addedAt: 0));

      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(notes: state().notes))), isTrue);
      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(accounts: state().accounts))), isTrue);
      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(services: state().backupServices))), isTrue);
      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(cards: state().cards))), isTrue);
      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(identities: state().identities))), isTrue);

      expect(state().notes.single.title, 'New');
      expect(state().accounts.single.issuer, 'google.com');
      expect(state().backupServices, hasLength(1));
      expect(state().cards, hasLength(1));
      expect(state().identities, hasLength(1));
      expect(await records(), hasLength(5));
    });

    test('relinks a login linked to a code that goes to the code that stays', () async {
      await openNew();
      final ids = await twoCodesAndALink();

      await controller().mergeDuplicates(MergeChoices(dedupItems(accounts: state().accounts)));

      expect(state().accounts.single.id, ids.aws);
      expect(state().logins.single.accountId, ids.aws);
      expect((await records()).single.relinked.single['accountId'], ids.root);
    });

    test('a failed save leaves the vault as it was, with no record, and says so', () async {
      await openNew();
      await twoLogins();
      final before = state().logins;

      vaultStore.failSaves = true;
      expect(await controller().mergeDuplicates(loginChoices()), isFalse);

      expect(state().logins, before);
      expect(await records(), isEmpty);
      expect(toast()?.message, t('vault.snack.duplicatesMergeFailed'));
    });

    test('a failed relink puts the code that was merged back', () async {
      await openNew();
      await twoCodesAndALink();
      final accounts = state().accounts;
      final logins = state().logins;

      vaultStore.failSaves = true;
      await controller().mergeDuplicates(MergeChoices(dedupItems(accounts: state().accounts)));

      expect(state().accounts, accounts);
      expect(state().logins, logins);
      expect(await records(), isEmpty);
    });
  });

  group('Undo merge', () {
    test('from the toast brings both logins back as they were', () async {
      await openNew();
      await twoLogins();
      final before = state().logins;
      await controller().mergeDuplicates(loginChoices());

      toast()!.onAction!();
      await pumpEventQueue();

      expect(state().logins.map((login) => login.id), unorderedEquals(['a', 'b']));
      expect(state().logins.firstWhere((login) => login.id == 'a').password, 'old');
      expect(state().logins.firstWhere((login) => login.id == 'b').previousPasswords, before.last.previousPasswords);
      expect(await records(), isEmpty);
    });

    test('six days later puts both back, stamped as just changed', () async {
      await openNew();
      await twoLogins();
      await controller().mergeDuplicates(loginChoices());
      final id = (await records()).single.id;

      later(const Duration(days: 6));
      expect(await controller().undoMerge(id), isTrue);

      expect(state().logins, hasLength(2));
      expect({for (final login in state().logins) login.changedAt}, {now.millisecondsSinceEpoch});
      expect(toast()?.message, t('vault.snack.duplicatesUndone'));
    });

    test('puts a relinked login back on the code it was linked to', () async {
      await openNew();
      final ids = await twoCodesAndALink();
      await controller().mergeDuplicates(MergeChoices(dedupItems(accounts: state().accounts)));

      await controller().undoMerge((await records()).single.id);

      expect(state().accounts.map((account) => account.id), unorderedEquals([ids.root, ids.aws]));
      expect(state().logins.single.accountId, ids.root);
    });

    test('is no longer offered after 30 days', () async {
      await openNew();
      await twoLogins();
      await controller().mergeDuplicates(loginChoices());
      final id = (await records()).single.id;

      later(const Duration(days: 31));

      expect(await controller().undoMerge(id), isFalse);
      expect(state().logins, hasLength(1));
    });

    test('works only in the vault the merge was made in: not from another session, and not for an unknown record', () async {
      final session = await openNew();
      await twoLogins();
      await controller().mergeDuplicates(loginChoices());
      final id = (await records()).single.id;

      controller().lock();
      await controller().open(await vaultStore.unlockAnyVault('pw', vaults.startingVault()));

      expect(await controller().undoMerge(id, from: session), isFalse);
      expect(await controller().undoMerge('no-such-record'), isFalse);
      expect(state().logins, hasLength(1));
      expect(await controller().undoMerge(id), isTrue);
      expect(state().logins, hasLength(2));
    });
  });
}
