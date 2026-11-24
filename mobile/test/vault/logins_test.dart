import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/logins/login_inbox.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/generated_password.dart';
import 'package:kemlock/models/login.dart';
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

const _larkspur = Login(
  id: 'l1',
  name: 'Larkspur Mail',
  username: 'ada@example.org',
  password: 'hunter2-first',
  websites: ['larkspur.example'],
  addedAt: 0,
);

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
  int ms() => now.millisecondsSinceEpoch;

  Future<VaultSession> openNew() async {
    final session = await vaultStore.setupVault('pw');
    await controller().open(session);
    return session;
  }

  test('are added, stamped and saved encrypted, and come back at the next opening', () async {
    final session = await openNew();

    expect(await controller().addLogin(_larkspur), isTrue);

    final login = state().logins.single;
    expect((login.addedAt, login.updatedAt, login.passwordChangedAt), (ms(), ms(), ms()));
    expect(state().revision, 1);
    expect(toast()?.message, t('vault.snack.loginAdded', {'name': 'Larkspur Mail'}));
    // Stored like the accounts: neither the password nor the username in the clear
    final stored = store.getItem('backmycodes_login_data')!;
    expect(stored, isNot(contains('hunter2')));
    expect(stored, isNot(contains('ada@example.org')));

    controller().lock();
    await controller().open(session);
    expect(state().logins, [login]);
  });

  test('a changed password keeps the one it replaced, with when', () async {
    await openNew();
    await controller().addLogin(_larkspur);
    final added = state().logins.single;

    now = now.add(const Duration(days: 3));
    expect(await controller().updateLogin(added.copyWith(password: 'hunter2-second', note: 'new')), isTrue);

    final changed = state().logins.single;
    expect(changed.password, 'hunter2-second');
    expect(changed.note, 'new');
    expect(changed.passwordChangedAt, ms());
    expect(changed.previousPasswords, [PreviousPassword(password: 'hunter2-first', until: ms())]);
  });

  test('an edit that keeps the password adds no previous password', () async {
    await openNew();
    await controller().addLogin(_larkspur);
    await controller().updateLogin(state().logins.single.copyWith(name: 'Larkspur'));

    expect(state().logins.single.previousPasswords, isNull);
    expect(state().logins.single.name, 'Larkspur');
  });

  test('deletes a previous password for good', () async {
    await openNew();
    await controller().addLogin(_larkspur);
    await controller().updateLogin(state().logins.single.copyWith(password: 'hunter2-second'));
    final login = state().logins.single;

    expect(await controller().deletePreviousPassword(login, login.previousPasswords!.single), isTrue);

    expect(state().logins.single.previousPasswords, isNull);
    expect(state().logins.single.toJson().containsKey('previousPasswords'), isFalse);
  });

  test('a delete is undone with its previous passwords', () async {
    await openNew();
    await controller().addLogin(_larkspur);
    await controller().updateLogin(state().logins.single.copyWith(password: 'hunter2-second'));
    final before = state().logins.single;

    await controller().deleteLogin(before);
    expect(state().logins, isEmpty);
    expect(toast()?.message, t('vault.snack.loginRemoved', {'name': 'Larkspur Mail'}));

    toast()!.onAction!();
    await pumpEventQueue();
    expect(state().logins.single.previousPasswords, before.previousPasswords);
    expect(state().logins.single.password, 'hunter2-second');
  });

  test('a failed save puts the list back as it was, and says so', () async {
    await openNew();
    await controller().addLogin(_larkspur);
    final before = state().logins;

    vaultStore.failSaves = true;
    expect(await controller().updateLogin(before.single.copyWith(password: 'other')), isFalse);

    expect(state().logins, before);
    expect(toast()?.message, t('vault.snack.loginUpdateFailed'));
  });

  test('go with their vault, and are sealed again with a new key pair', () async {
    final session = await openNew();
    await controller().addLogin(_larkspur);
    expect(vaultStore.sealedValueKeys(mainVault), contains('backmycodes_login_data'));

    vaults.removeVaultData(mainVault);
    expect(store.getItem('backmycodes_login_data'), isNull);
    expect(await vaultStore.loadLogins(session), isEmpty);
  });

  // openspec: add-passwords, task 7.5
  test('come in with an import, each once, and are saved', () async {
    final session = await openNew();
    await controller().addLogin(_larkspur);

    await controller().imported(
      const [],
      const [],
      logins: [
        _larkspur.copyWith(name: 'Theirs'),
        _larkspur.copyWith(id: 'l2'),
      ],
    );

    expect(state().logins.map((login) => (login.id, login.name)), [('l1', 'Larkspur Mail'), ('l2', 'Larkspur Mail')]);
    expect((await vaultStore.loadLogins(session)).map((login) => login.id), ['l1', 'l2']);
  });

  // openspec: add-passwords, task 4.5
  group('saved by AutoFill', () {
    LoginInboxRecord saved(
      String password, {
      String id = 'p1',
      String? username = 'ada@example.org',
      String? site = 'larkspur.example',
      int at = 5,
    }) => LoginInboxRecord.login(id: id, name: 'Larkspur', username: username, password: password, site: site, at: at);

    test('are added when no login is theirs, marked as saved by AutoFill, without a toast', () async {
      await openNew();

      expect(await controller().takeLoginRecords([saved('first', site: 'shop.example')]), (added: 1, updated: 0));

      final login = state().logins.single;
      expect((login.id, login.name, login.password, login.source), ('p1', 'Larkspur', 'first', Login.fromAutofill));
      expect(login.websites, ['shop.example']);
      expect(login.passwordChangedAt, 5);
      expect(state().revision, 1);
      expect(toast(), isNull);
    });

    test('update the login of the same id, keeping the password it replaces', () async {
      await openNew();
      await controller().addLogin(_larkspur);

      expect(await controller().takeLoginRecords([saved('hunter2-second', id: 'l1', username: null, site: null, at: 9)]), (
        added: 0,
        updated: 1,
      ));

      final login = state().logins.single;
      expect((login.password, login.passwordChangedAt), ('hunter2-second', 9));
      expect(login.previousPasswords!.single.password, 'hunter2-first');
      expect(login.name, 'Larkspur Mail', reason: 'only the password changes');
    });

    test('update the login of the same site and username, whatever their case', () async {
      await openNew();
      await controller().addLogin(_larkspur);

      final taken = await controller().takeLoginRecords([
        saved('hunter2-second', username: 'Ada@Example.org', site: 'mail.larkspur.example'),
      ]);

      expect(taken, (added: 0, updated: 1));
      expect(state().logins.single.id, 'l1');
      expect(state().logins.single.password, 'hunter2-second');
    });

    test('of another username on the same site are added beside it', () async {
      await openNew();
      await controller().addLogin(_larkspur);

      expect(await controller().takeLoginRecords([saved('other', username: 'grace@example.org')]), (added: 1, updated: 0));
      expect(state().logins.map((login) => login.id), ['l1', 'p1']);
    });

    test('with the same password change nothing and save nothing', () async {
      await openNew();
      await controller().addLogin(_larkspur);
      final before = (state().logins, store.getItem('backmycodes_login_data'), state().revision);

      expect(await controller().takeLoginRecords([saved('hunter2-first', id: 'l1')]), (added: 0, updated: 0));

      expect((state().logins, store.getItem('backmycodes_login_data'), state().revision), before);
    });

    test('go in oldest first, so the newest password wins', () async {
      await openNew();
      await controller().addLogin(_larkspur);

      await controller().takeLoginRecords([saved('third', id: 'l1', at: 30), saved('second', id: 'l1', at: 20)]);

      final login = state().logins.single;
      expect(login.password, 'third');
      expect(login.previousPasswords!.map((p) => p.password), ['second', 'hunter2-first']);
    });

    test('bring back a login deleted since', () async {
      await openNew();
      await controller().addLogin(_larkspur);
      await controller().deleteLogin(state().logins.single);
      expect(state().logins, isEmpty);

      expect(await controller().takeLoginRecords([saved('again', id: 'l1')]), (added: 1, updated: 0));
      expect(state().logins.single.id, 'l1');
    });

    test('taken twice change nothing the second time', () async {
      await openNew();
      final records = [saved('first'), LoginInboxRecord.generated(password: 'Xk9-generated', site: 'news.example', at: 7)];

      await controller().takeLoginRecords(records);
      final after = (state().logins, state().generated);

      expect(await controller().takeLoginRecords(records), (added: 0, updated: 0));
      expect((state().logins, state().generated), after);
    });

    test('a failed save changes nothing and says so by its null', () async {
      await openNew();
      vaultStore.failSaves = true;

      expect(await controller().takeLoginRecords([saved('first')]), isNull);
      expect(state().logins, isEmpty);
      expect(state().revision, 0);
    });
  });

  // openspec: add-passwords, task 4.6
  group('generated by AutoFill', () {
    test('are kept, encrypted, until a saved login holds them', () async {
      final session = await openNew();

      await controller().takeLoginRecords([const LoginInboxRecord.generated(password: 'Xk9-generated', site: 'news.example', at: 7)]);

      expect(state().generated, [const GeneratedPassword(password: 'Xk9-generated', site: 'news.example', at: 7)]);
      expect(state().revision, 0, reason: 'never synced, so no sync is due');
      expect(
        store.getItem('backmycodes_generated_data'),
        isNot(contains('Xk9-generated')),
        reason: 'a dash is not base64, so only the plaintext can match',
      );
      expect(await vaultStore.loadGenerated(session), state().generated);

      await controller().takeLoginRecords([
        const LoginInboxRecord.login(id: 'p1', name: 'News', password: 'Xk9-generated', site: 'news.example', generated: true, at: 8),
      ]);
      expect(state().generated, isEmpty);
      expect(await vaultStore.loadGenerated(session), isEmpty);
    });

    test('that a login already holds are not kept', () async {
      await openNew();
      await controller().addLogin(_larkspur);

      await controller().takeLoginRecords([const LoginInboxRecord.generated(password: 'hunter2-first', at: 7)]);
      expect(state().generated, isEmpty);
    });

    test('are kept a month, the older ones going as the vault opens', () async {
      final session = await vaultStore.setupVault('pw');
      final day = const Duration(days: 1).inMilliseconds;
      await vaultStore.saveGenerated([
        GeneratedPassword(password: 'old', at: ms() - 31 * day),
        GeneratedPassword(password: 'recent', at: ms() - 29 * day),
      ], session);

      await controller().open(session);

      expect(state().generated.map((item) => item.password), ['recent']);
      expect((await vaultStore.loadGenerated(session)).map((item) => item.password), ['recent']);
    });

    test('that a login came to hold go as the vault opens', () async {
      final session = await vaultStore.setupVault('pw');
      await vaultStore.saveLogins([_larkspur], session);
      await vaultStore.saveGenerated([
        GeneratedPassword(password: 'hunter2-first', at: ms()),
        GeneratedPassword(password: 'unsaved', at: ms()),
      ], session);

      await controller().open(session);

      expect(state().generated.map((item) => item.password), ['unsaved']);
    });

    test('can be forgotten one by one', () async {
      final session = await openNew();
      await controller().takeLoginRecords([
        const LoginInboxRecord.generated(password: 'one', at: 1),
        const LoginInboxRecord.generated(password: 'two', at: 2),
      ]);

      expect(await controller().deleteGenerated(state().generated.first), isTrue);

      expect(state().generated.map((item) => item.password), ['two']);
      expect((await vaultStore.loadGenerated(session)).map((item) => item.password), ['two']);
    });
  });
}
