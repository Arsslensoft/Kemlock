import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/json.dart' show unset;
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
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

/// A vault store whose saves of vault items fail on demand, as a full disk would.
class _FlakyStore extends VaultStore {
  _FlakyStore(super.store, super.vaults) : super(deriveKey: fastKdf);

  bool failSaves = false;

  @override
  Future<void> saveNotes(List<SecureNote> notes, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveNotes(notes, session);

  @override
  Future<void> saveKeys(List<VaultKey> keys, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveKeys(keys, session);

  @override
  Future<void> savePasskeys(List<Passkey> passkeys, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.savePasskeys(passkeys, session);
}

const _passport = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 0);
const _wifi = SecureNote(id: 'n2', title: 'Wi-Fi', text: 'hunter2', addedAt: 0);

VaultKey _key(String id, String name, {String? public = 'MCowBQYDK2VwAyEAaaaa', String private = 'MC4CAQAwBQYDK2VwBCIEIA=='}) => VaultKey(
  id: id,
  name: name,
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: private,
  publicKey: public,
  origin: KeyOrigin.generated,
  addedAt: 0,
);

Passkey _passkey(String id, String credentialId, {String rpId = 'github.com'}) => Passkey(
  id: id,
  credentialId: credentialId,
  rpId: rpId,
  userHandle: 'dXNlcg',
  userName: 'octocat@example.com',
  privateKey: 'MIGHAgEAMBMGByqGSM49AgEG',
  addedAt: 0,
);

void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late _FlakyStore vaultStore;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 11, 15, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = _FlakyStore(store, vaults);
    now = DateTime.utc(2026, 11, 15, 12);
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

  group('notes', () {
    test('are added, stamped and saved encrypted', () async {
      final session = await openNew();

      expect(await controller().addNote(_passport), isTrue);

      final note = state().notes.single;
      expect((note.title, note.addedAt, note.updatedAt), ('Passport', now.millisecondsSinceEpoch, now.millisecondsSinceEpoch));
      expect(state().revision, 1);
      expect(toast()?.message, t('vault.snack.noteAdded', {'name': 'Passport'}));
      expect(await vaultStore.loadNotes(session), [note]);
      // Stored like the accounts: nothing of the note in the clear
      expect(store.getItem('backmycodes_note_data'), isNot(contains('Passport')));
    });

    test('keep a piv object through reading, writing, copying and the vault', () async {
      // The management key of a security key's PIV application, as add-piv-management writes it.
      const json = <String, Object?>{
        'id': 'n9',
        'title': 'Management key – Example Key 12345678',
        'text': 'A1B2 C3D4',
        'addedAt': 0,
        'piv': {'key': '12345678', 'algorithm': 'aes256', 'managementKey': 'a1b2c3d4', 'later': true},
      };
      final note = SecureNote.fromJson(json);

      expect(note.toJson(), json);
      expect(note.toJson().keys.last, 'piv');
      expect(note.copyWith(text: 'edited').toJson()['piv'], json['piv']);
      expect(note.inSpace(null).toJson()['piv'], json['piv']);

      final session = await openNew();
      await controller().addNote(note);
      controller().lock();
      await controller().open(session);

      expect(state().notes.single.toJson()['piv'], json['piv']);
      expect((await vaultStore.loadNotes(session)).single.toJson()['piv'], json['piv']);
    });

    test('read the piv object as the management key it keeps, and write it only when set', () {
      // A note without one writes what it wrote before: no piv key at all.
      expect(_passport.toJson(), {'id': 'n1', 'title': 'Passport', 'text': 'In the drawer', 'addedAt': 0});
      expect(SecureNote.fromJson(_passport.toJson()).piv, isNull);

      const piv = NotePivKey(key: '12345678', algorithm: 'aes256', managementKey: 'a1b2c3d4');
      final kept = _passport.copyWith(piv: piv);
      expect(kept.toJson()['piv'], {'key': '12345678', 'algorithm': 'aes256', 'managementKey': 'a1b2c3d4'});
      expect(SecureNote.fromJson(kept.toJson()), kept);
      expect(SecureNote.fromJson(kept.toJson()).piv, piv);
      expect(kept.copyWith(title: 'renamed').piv, piv);
      expect(kept.copyWith(piv: unset).toJson().containsKey('piv'), isFalse);

      // A piv this version can't read is kept as it was, and one set later takes its place.
      final odd = SecureNote.fromJson({..._passport.toJson(), 'piv': 'not an object'});
      expect((odd.piv, odd.toJson()['piv']), (null, 'not an object'));
      expect(odd.copyWith(piv: piv).toJson()['piv'], piv.toJson());
    });

    test('are read again when the vault opens', () async {
      final session = await openNew();
      await controller().addNote(_passport);
      await controller().addNote(_wifi);

      controller().lock();
      expect(state().notes, isEmpty);
      await controller().open(session);

      expect(state().notes.map((note) => note.title), ['Passport', 'Wi-Fi']);
    });

    test('are updated, and stamped as changed', () async {
      final session = await openNew();
      await controller().addNote(_passport);
      now = now.add(const Duration(minutes: 5));

      final saved = await controller().updateNote(state().notes.single.copyWith(text: 'In the safe'));

      expect(saved, isTrue);
      expect(state().notes.single.text, 'In the safe');
      expect(state().notes.single.updatedAt, now.millisecondsSinceEpoch);
      expect((await vaultStore.loadNotes(session)).single.text, 'In the safe');
    });

    test('are deleted, and come back with Undo', () async {
      final session = await openNew();
      await controller().addNote(_passport);
      await controller().addNote(_wifi);
      final passport = state().notes.first;

      await controller().deleteNote(passport);

      expect(state().notes.map((note) => note.title), ['Wi-Fi']);
      expect(toast()?.message, t('vault.snack.noteRemoved', {'name': 'Passport'}));
      expect(toast()?.actionLabel, t('app.undo'));
      now = now.add(const Duration(seconds: 3));
      toast()!.onAction!();
      await pumpEventQueue();

      expect(state().notes.map((note) => note.title), ['Passport', 'Wi-Fi']);
      // Stamped as just changed, so it outlives a deletion sync already shared
      expect(state().notes.first.updatedAt, now.millisecondsSinceEpoch);
      expect((await vaultStore.loadNotes(session)).map((note) => note.id), [passport.id, state().notes.last.id]);
    });

    test('go back to what was saved when a save fails, and say so', () async {
      await openNew();
      await controller().addNote(_passport);
      final before = state().notes;
      vaultStore.failSaves = true;

      expect(await controller().updateNote(before.single.copyWith(text: 'changed')), isFalse);
      expect(state().notes, before);
      expect(toast()?.message, t('vault.snack.noteUpdateFailed'));

      expect(await controller().addNote(_wifi), isFalse);
      expect(state().notes, before);
      expect(toast()?.message, t('vault.snack.noteAddFailed'));

      await controller().deleteNote(before.single);
      expect(state().notes, before);
      expect(toast()?.message, t('vault.snack.noteRemoveFailed'));
    });

    test('still open after the master password changes', () async {
      final session = await openNew('old password');
      await controller().addNote(_passport);

      await vaultStore.changePassword(session, 'new password');
      controller().lock();
      final reopened = await vaultStore.unlockVault('new password');
      await controller().open(reopened);

      expect(state().notes.single.title, 'Passport');
    });

    test('belong to their vault', () async {
      await openNew('first');
      await controller().addNote(_passport);
      final second = await vaultStore.createVault('Work', 'second', listed: true);
      controller().switchVault(second);
      await controller().open(await vaultStore.unlockVault('second'));

      expect(state().notes, isEmpty);
      await controller().addNote(_wifi);
      expect(store.getItem('backmycodes_note_data::$second'), isNotNull);

      controller().deleteVault();
      expect(store.getItem('backmycodes_note_data::$second'), isNull);
      expect(store.getItem('backmycodes_note_data'), isNotNull);
    });
  });

  group('passkeys', () {
    test('are added, saved encrypted and read again at unlock', () async {
      final session = await openNew();

      expect(await controller().addPasskey(_passkey('p1', 'cred-1')), isTrue);

      expect(state().passkeys.single.addedAt, now.millisecondsSinceEpoch);
      expect(toast()?.message, t('vault.snack.passkeyAdded', {'name': 'github.com'}));
      expect(store.getItem('backmycodes_passkey_data'), isNot(contains('github')));
      controller().lock();
      await controller().open(session);
      expect(state().passkeys.single.credentialId, 'cred-1');
    });

    test('are not added twice: the same credential id is the same passkey', () async {
      await openNew();
      await controller().addPasskey(_passkey('p1', 'cred-1'));

      expect(await controller().addPasskey(_passkey('p2', 'cred-1')), isFalse);

      expect(state().passkeys, hasLength(1));
      expect(toast()?.message, t('vault.snack.passkeyExists', {'name': 'github.com'}));
    });

    test('are added in bulk, skipping the ones held, in one save', () async {
      final session = await openNew();
      await controller().addPasskey(_passkey('p1', 'cred-1'));
      final revision = state().revision;

      final added = await controller().addPasskeys([
        _passkey('p2', 'cred-1'),
        _passkey('p3', 'cred-2', rpId: 'gitlab.com'),
        _passkey('p4', 'cred-2', rpId: 'gitlab.com'),
      ]);

      expect(added, 1);
      expect(state().passkeys.map((passkey) => passkey.credentialId), ['cred-1', 'cred-2']);
      expect(state().revision, revision + 1);
      expect((await vaultStore.loadPasskeys(session)).map((passkey) => passkey.id), ['p1', 'p3']);
      expect(await controller().addPasskeys([_passkey('p5', 'cred-2')]), 0);
    });

    test('are edited and deleted with Undo, and roll back when a save fails', () async {
      await openNew();
      await controller().addPasskey(_passkey('p1', 'cred-1'));

      expect(await controller().updatePasskey(state().passkeys.single.copyWith(label: 'Work')), isTrue);
      expect(state().passkeys.single.label, 'Work');

      await controller().deletePasskey(state().passkeys.single);
      expect(state().passkeys, isEmpty);
      toast()!.onAction!();
      await pumpEventQueue();
      expect(state().passkeys.single.label, 'Work');

      vaultStore.failSaves = true;
      final before = state().passkeys;
      expect(await controller().updatePasskey(before.single.copyWith(label: 'Home')), isFalse);
      expect(state().passkeys, before);
      expect(toast()?.message, t('vault.snack.passkeyUpdateFailed'));
      expect(await controller().addPasskeys([_passkey('p9', 'cred-9')]), isNull);
      expect(state().passkeys, before);
    });
  });

  group('keys', () {
    test('are added, saved encrypted and read again at unlock', () async {
      final session = await openNew();

      expect(await controller().addKey(_key('k1', 'laptop')), isTrue);

      expect(state().keys.single.addedAt, now.millisecondsSinceEpoch);
      expect(toast()?.message, t('vault.snack.keyAdded', {'name': 'laptop'}));
      expect(store.getItem('backmycodes_key_data'), isNot(contains('laptop')));
      controller().lock();
      await controller().open(session);
      expect(state().keys.single.name, 'laptop');
    });

    test('are not added twice: the same public half is the same key, whatever its name', () async {
      await openNew();
      await controller().addKey(_key('k1', 'laptop'));

      expect(await controller().addKey(_key('k2', 'desktop')), isFalse);

      expect(state().keys.single.name, 'laptop');
      expect(toast()?.message, t('vault.snack.keyExists', {'name': 'laptop'}));
      // Another key pair is another key
      expect(await controller().addKey(_key('k3', 'desktop', public: 'MCowBQYDK2VwAyEAbbbb')), isTrue);
      expect(state().keys, hasLength(2));
    });

    test('of an unknown algorithm are told apart by their private half', () async {
      await openNew();
      await controller().addKey(_key('k1', 'odd', public: null, private: 'AAAA'));

      expect(await controller().addKey(_key('k2', 'odd again', public: null, private: 'AAAA')), isFalse);
      expect(await controller().addKey(_key('k3', 'other', public: null, private: 'BBBB')), isTrue);
    });

    test('are renamed, deleted with Undo, and roll back when a save fails', () async {
      await openNew();
      await controller().addKey(_key('k1', 'laptop'));

      expect(await controller().updateKey(state().keys.single.copyWith(name: 'work laptop')), isTrue);
      expect(state().keys.single.name, 'work laptop');

      await controller().deleteKey(state().keys.single);
      expect(state().keys, isEmpty);
      toast()!.onAction!();
      await pumpEventQueue();
      expect(state().keys.single.name, 'work laptop');

      vaultStore.failSaves = true;
      final before = state().keys;
      expect(await controller().updateKey(before.single.copyWith(name: 'x')), isFalse);
      expect(state().keys, before);
      expect(toast()?.message, t('vault.snack.keyUpdateFailed'));
    });

    test('keep a card object they were given through reading, writing, copying and a save', () async {
      // What a key on a security key carries (openspec: add-openpgp-card)
      const card = {
        'aid': 'D2760001240103040006123456780000',
        'slots': {'sig': 'AA', 'dec': 'BB'},
      };
      final json = {..._key('k1', 'on a card').toJson(), 'card': card};
      final key = VaultKey.fromJson(json);

      expect(key.toJson(), json);
      expect(key.copyWith(name: 'renamed').toJson(), {...json, 'name': 'renamed'});

      final session = await openNew();
      expect(await controller().addKey(key), isTrue);
      final saved = state().keys.single.toJson();
      expect(saved['card'], card);
      controller().lock();
      await controller().open(session);
      expect(state().keys.single.toJson(), saved);
    });

    test('without a card write the JSON they always wrote', () {
      final key = _key('k1', 'laptop');

      expect(key.isOnCard, isFalse);
      expect(key.card, isNull);
      expect(key.toJson(), {
        'id': 'k1',
        'name': 'laptop',
        'kind': 'ssh',
        'algorithm': 'ed25519',
        'private': 'MC4CAQAwBQYDK2VwBCIEIA==',
        'public': 'MCowBQYDK2VwAyEAaaaa',
        'origin': 'generated',
        'addedAt': 0,
      });
    });

    test('on a card keep the card as a field, through copying, and lose it only when asked', () {
      const card = {
        'aid': 'D2760001240103040006123456780000',
        'slots': {'sig': 'AA', 'dec': 'BB'},
      };
      final key = VaultKey.fromJson({..._key('k1', 'on a card').toJson(), 'card': card});

      expect(key.isOnCard, isTrue);
      expect(key.card, card);
      expect(key.extra, isEmpty);
      expect(VaultKey.fromJson(key.toJson()), key);
      expect(key.copyWith(name: 'renamed').card, card);
      expect(key.copyWith(card: unset).isOnCard, isFalse);
      expect(key.copyWith(card: unset).toJson().containsKey('card'), isFalse);
    });

    test('keep a card value that is not an object as they found it', () {
      final key = VaultKey.fromJson({..._key('k1', 'odd').toJson(), 'card': 'a card'});

      expect(key.isOnCard, isFalse);
      expect(key.toJson()['card'], 'a card');
    });
  });

  group('what sync merged', () {
    test('is saved for every kind, and read again at unlock', () async {
      final session = await openNew();
      await controller().addNote(_wifi);

      await controller().applySynced(Lists(keys: [_key('k1', 'laptop')], notes: const [_passport], passkeys: [_passkey('p1', 'cred-1')]));

      expect(state().notes.single.title, 'Passport');
      controller().lock();
      await controller().open(session);
      expect(
        (state().keys.single.name, state().notes.single.title, state().passkeys.single.credentialId),
        ('laptop', 'Passport', 'cred-1'),
      );
    });

    test('leaves a list sync did not change unsaved', () async {
      final session = await openNew();
      await controller().addNote(_passport);
      final before = store.getItem('backmycodes_note_data');

      await controller().applySynced(Lists(notes: state().notes, keys: [_key('k1', 'laptop')]));

      // Every save of a list is a fresh encryption, so an unchanged value means no save
      expect(store.getItem('backmycodes_note_data'), before);
      expect((await vaultStore.loadKeys(session)).single.name, 'laptop');
    });
  });
}
