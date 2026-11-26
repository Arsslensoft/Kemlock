import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/duplicates/dedup_tagger.dart';
import 'package:kemlock/features/duplicates/duplicate_merge.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';
import 'package:kemlock_core/models/item_link.dart';
import 'package:kemlock_core/vault/item_links.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

class _NoBiometrics implements Biometrics {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

// A link names the UUID of the item, so every item here has one
const _loginId = '11111111-1111-4111-8111-111111111111';
const _otherLoginId = '22222222-2222-4222-8222-222222222222';
const _noteId = '33333333-3333-4333-8333-333333333333';
const _goneId = '99999999-9999-4999-8999-999999999999';

Login _login(String id, {String name = 'Proton', List<ItemLink> links = const []}) => Login(
  id: id,
  name: name,
  username: 'sam',
  password: 'pw',
  websites: const ['proton.me'],
  links: links,
  addedAt: 0,
);

SecureNote _note(String id, {List<ItemLink> links = const []}) => SecureNote(id: id, title: 'Recovery plan', links: links, addedAt: 0);

// Two-way links between items (docs/crypto.md, "Item bodies", `links`) on the vault controller: linking, unlinking, deleting and merging
void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vaultStore;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 11, 25, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = VaultStore(store, vaults, deriveKey: fastKdf);
    now = DateTime.utc(2026, 11, 25, 12);
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
  void later(Duration by) => now = now.add(by);
  String t(String id, [Map<String, Object?> args = const {}]) => catalog.of(AppLocale.en).t(id, args);

  Future<void> openNew() async {
    final session = await vaultStore.setupVault('pw');
    await controller().open(session);
  }

  Login login([String id = _loginId]) => state().logins.firstWhere((login) => login.id == id);
  SecureNote note() => state().notes.single;
  Set<String> linksOfLogin([String id = _loginId]) => login(id).links.ids;

  group('linking', () {
    test('writes both items, each naming the other', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId));

      later(const Duration(minutes: 1));

      expect(await controller().linkItems(login(), note()), isTrue);

      expect(linksOfLogin(), {_noteId});
      expect(note().links.ids, {_loginId});
      expect(login().changedAt, now.millisecondsSinceEpoch);
      expect(note().changedAt, now.millisecondsSinceEpoch);
    });

    test('shows on both items, and as one link, not two', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId));
      await controller().linkItems(login(), note());

      final fromLogin = linkedItemsOf(state().lists, login());
      final fromNote = linkedItemsOf(state().lists, note());

      expect([for (final item in fromLogin) (item.id, item.entry?.id, item.oneWay)], [(_noteId, _noteId, false)]);
      expect([for (final item in fromNote) (item.id, item.entry?.id, item.oneWay)], [(_loginId, _loginId, false)]);
    });

    test('a link only one end names shows on both items, and linking again writes the missing end', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId, links: const [ItemLink(_loginId)]));

      expect(linkedItemsOf(state().lists, login()).single.oneWay, isTrue);
      expect(linkedItemsOf(state().lists, note()).single.oneWay, isTrue);

      expect(await controller().linkItems(note(), login()), isTrue);

      expect(linksOfLogin(), {_noteId});
      expect(linkedItemsOf(state().lists, login()).single.oneWay, isFalse);
    });

    test('keeps a link to an item the vault does not hold, as not available', () async {
      await openNew();
      await controller().addLogin(_login(_loginId, links: const [ItemLink(_goneId)]));
      await controller().addNote(_note(_noteId));

      final dangling = linkedItemsOf(state().lists, login()).single;
      expect(dangling.id, _goneId);
      expect(dangling.entry, isNull);

      await controller().linkItems(login(), note());
      await controller().unlinkItems(login(), note());

      expect(linksOfLogin(), {_goneId});
    });
  });

  group('an edit that lands between the saves of the two ends', () {
    test('is kept when linking, since each end is changed as the vault holds it when its list is saved', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId));
      // The note is renamed right after the login's list is saved, before the note's is
      var renamed = false;
      final stop = store.listen('backmycodes_login_data', () {
        if (renamed) return;
        renamed = true;
        unawaited(controller().updateNote(note().copyWith(title: 'Renamed')));
      });
      addTearDown(stop);

      expect(await controller().linkItems(login(), note()), isTrue);

      expect(renamed, isTrue);
      expect(note().title, 'Renamed');
      expect(note().links.ids, {_loginId});
      expect(linksOfLogin(), {_noteId});
    });

  });

  group('a link that changes nothing', () {
    test('says so, and returns false, for an item with no item id yet', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      // An id that is not a UUID has no item id, and there is no Kemlock Server account to make one
      await controller().addNote(SecureNote(id: 'legacy-note', title: 'Old', addedAt: 0));

      expect(await controller().linkItems(login(), note()), isFalse);

      expect(toast()?.message, t('links.snack.nothing'));
      expect(login().links, isEmpty);
      expect(note().links, isEmpty);
    });
  });

  group('saving an edit from a copy older than a link', () {
    test('a note saved from the page that opened before the link keeps the link', () async {
      await openNew();
      await controller().addNote(_note(_noteId));
      await controller().addLogin(_login(_loginId));
      // The note page holds this copy from when it opened
      final stale = note();
      await controller().linkItems(login(), note());

      expect(await controller().updateNote(stale.copyWith(title: 'Renamed')), isTrue);

      expect(note().title, 'Renamed');
      expect(note().links.ids, {_loginId});
      expect(linksOfLogin(), {_noteId});
    });

    test('a login saved from an old copy keeps its links too', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId));
      final stale = login();
      await controller().linkItems(login(), note());

      expect(await controller().updateLogin(stale.copyWith(name: 'Renamed')), isTrue);

      expect(login().name, 'Renamed');
      expect(linksOfLogin(), {_noteId});
    });
  });

  group('unlinking', () {
    test('removes both ends', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId));
      await controller().linkItems(login(), note());

      expect(await controller().unlinkItems(note(), login()), isTrue);

      expect(login().links, isEmpty);
      expect(note().links, isEmpty);
      expect(linkedItemsOf(state().lists, login()), isEmpty);
    });

    test('leaves the other links of both items', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addLogin(_login(_otherLoginId, name: 'Other'));
      await controller().addNote(_note(_noteId));
      await controller().linkItems(login(), note());
      await controller().linkItems(login(_otherLoginId), note());

      await controller().unlinkItems(login(), note());

      expect(linksOfLogin(), isEmpty);
      expect(note().links.ids, {_otherLoginId});
    });

    test('also clears the login of a code that was imported from it, whichever side asks', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addAccount(
        OtpAccount(id: 'code', issuer: 'Proton', label: 'sam', secret: 'JBSWY3DPEHPK3PXP', linkedLoginId: _loginId, addedAt: 0),
      );
      final code = state().accounts.single;

      expect(linkedItemsOf(state().lists, login()).single.viaLinkedLogin, isTrue);
      expect(linkedItemsOf(state().lists, code).single.entry?.id, _loginId);

      expect(await controller().unlinkItems(login(), code), isTrue);

      expect(state().accounts.single.linkedLoginId, isNull);
      expect(linkedItemsOf(state().lists, login()), isEmpty);
    });
  });

  group('deleting an item', () {
    test('takes it out of the links of the items that named it, and Undo puts the link back', () async {
      await openNew();
      await controller().addLogin(_login(_loginId));
      await controller().addNote(_note(_noteId));
      await controller().linkItems(login(), note());

      await controller().deleteNote(note());

      expect(state().notes, isEmpty);
      expect(login().links, isEmpty);
      expect(toast()?.actionLabel, t('app.undo'));

      toast()!.onAction!();
      await pumpEventQueue();

      expect(note().id, _noteId);
      expect(linksOfLogin(), {_noteId});
      expect(note().links.ids, {_loginId});
    });

    test('does so for a one-way link too, and for a code', () async {
      await openNew();
      await controller().addAccount(OtpAccount(id: 'code', issuer: 'Proton', label: 'sam', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
      // The vault gives a code its own id
      final code = state().accounts.single;
      await controller().addLogin(_login(_loginId, links: [ItemLink(code.id)]));

      await controller().deleteAccount(code);

      expect(state().accounts, isEmpty);
      expect(login().links, isEmpty);
    });

    test('keeps the links of the items it was not linked to, and a link to an item the vault does not hold', () async {
      await openNew();
      await controller().addLogin(_login(_loginId, links: const [ItemLink(_goneId)]));
      await controller().addLogin(_login(_otherLoginId, name: 'Other'));
      await controller().addNote(_note(_noteId));
      await controller().linkItems(login(), login(_otherLoginId));

      await controller().deleteNote(note());
      expect(linksOfLogin(), {_goneId, _otherLoginId});

      await controller().deleteLogin(login(_otherLoginId));
      expect(linksOfLogin(), {_goneId});
    });
  });

  group('merging duplicates', () {
    test('the item that stays takes over the links of the one that goes, and the items linked to it name the survivor', () async {
      await openNew();
      await controller().addLogin(_login(_loginId, name: 'proton.me', links: const [ItemLink(_goneId)]));
      await controller().addNote(_note(_noteId));
      // The older login, which goes, is the one linked to the note, and to an item the vault does not hold
      await controller().linkItems(login(), note());
      later(const Duration(minutes: 1));
      await controller().addLogin(_login(_otherLoginId, name: 'Proton Mail'));

      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(logins: state().logins))), isTrue);

      final survivor = state().logins.single;
      expect(survivor.id, _otherLoginId);
      expect(survivor.links.ids, {_noteId, _goneId});
      expect(note().links.ids, {_otherLoginId});
    });

    test('leaves the links of a vault that has none alone', () async {
      await openNew();
      await controller().addLogin(_login(_loginId, name: 'proton.me'));
      later(const Duration(minutes: 1));
      await controller().addLogin(_login(_otherLoginId, name: 'Proton Mail'));

      expect(await controller().mergeDuplicates(MergeChoices(dedupItems(logins: state().logins))), isTrue);

      expect(state().logins.single.links, isEmpty);
    });
  });
}
