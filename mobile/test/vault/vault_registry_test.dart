import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/storage/preferences_backend.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';
import 'rotation_helpers.dart' show newKit;

void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
  });

  void addVault(String id, {String? name}) =>
      store.setItem(vaults.vaultKey(keyConfig, id), name == null ? '{"salt":"s"}' : '{"salt":"s","name":"$name"}');

  test('keeps the storage keys earlier versions used for the first vault', () {
    addVault(mainVault);

    expect(store.getItem('backmycodes_vault_config'), isNotNull);
    expect(vaults.vaultKey('backmycodes_vault_data'), 'backmycodes_vault_data');
    expect(vaults.allVaultIds(), [mainVault]);
    expect(vaults.listedVaultIds(), [mainVault]);
    expect(vaults.startingVault(), mainVault);
    expect(vaults.vaultName(mainVault), isNull);
  });

  test("keys another vault's data with its id", () {
    vaults.active = 'abc123';

    expect(vaults.vaultKey('backmycodes_vault_data'), 'backmycodes_vault_data::abc123');
    expect(vaults.vaultKey('backmycodes_vault_data', mainVault), 'backmycodes_vault_data');
  });

  test('lists every vault, the first one first', () {
    addVault('w1');
    addVault(mainVault);
    addVault('w2');

    expect(vaults.allVaultIds(), [mainVault, 'w1', 'w2']);
  });

  test('lists a vault on the lock screen unless it is hidden', () {
    addVault(mainVault);
    addVault('work', name: 'Work');
    addVault('diary', name: 'Diary');
    vaults.setListed(mainVault, true);
    vaults.setListed('work', true);
    vaults.setListed('diary', false);

    expect(vaults.listedVaultIds(), [mainVault, 'work']);
    expect(vaults.hiddenVaultIds(), ['diary']);
    expect(vaults.isListed('diary'), isFalse);
    expect(vaults.vaultName('work'), 'Work');
    expect(store.getItem('backmycodes_vaults'), '{"listed":["main","work"]}');
  });

  test('never remembers a hidden vault as the one to start on', () {
    addVault(mainVault);
    addVault('work');
    addVault('diary');
    vaults.setListed(mainVault, true);
    vaults.setListed('work', true);
    vaults.setListed('diary', false);

    vaults.rememberVault('work');
    expect(vaults.startingVault(), 'work');
    vaults.rememberVault('diary');
    expect(vaults.startingVault(), 'work');
    expect(store.storedKeys().map(store.getItem), isNot(contains('diary')));
  });

  test('forgets the last vault when it is hidden', () {
    addVault(mainVault);
    addVault('work');
    vaults.setListed(mainVault, true);
    vaults.setListed('work', true);
    vaults.rememberVault('work');

    vaults.setListed('work', false);

    expect(vaults.startingVault(), mainVault);
    expect(store.getItem('backmycodes_last_vault'), isNull);
  });

  test('can hide the first vault too', () {
    addVault(mainVault);
    addVault('decoy');
    vaults.setListed(mainVault, true);
    vaults.setListed('decoy', true);

    vaults.setListed(mainVault, false);

    expect(vaults.listedVaultIds(), ['decoy']);
    expect(vaults.hiddenVaultIds(), [mainVault]);
  });

  test('reads a broken registry as no registry', () {
    addVault(mainVault);
    store.setItem('backmycodes_vaults', 'not json');

    expect(vaults.listedVaultIds(), [mainVault]);
  });

  test('deletes one vault and leaves the others', () {
    addVault(mainVault);
    store.setItem('backmycodes_vault_data', 'personal');
    addVault('work');
    store.setItem('backmycodes_vault_data::work', 'work');
    store.setItem('backmycodes_locale', 'fr');
    vaults.setListed(mainVault, true);
    vaults.setListed('work', true);
    vaults.active = 'work';

    vaults.removeVaultData('work');

    expect(vaults.allVaultIds(), [mainVault]);
    expect(store.storedKeys().where((k) => k.contains('::')), isEmpty);
    expect(vaults.active, mainVault);
    expect(store.getItem('backmycodes_vault_data'), 'personal');
    expect(vaults.listedVaultIds(), [mainVault]);
  });

  test("deletes a vault's biometric entry with it, and only that vault's", () {
    addVault(mainVault);
    store.setItem('backmycodes_native_bio', 'personal');
    addVault('work');
    store.setItem('backmycodes_native_bio::work', 'work');

    vaults.removeVaultData('work');
    expect(store.getItem('backmycodes_native_bio::work'), isNull);
    expect(store.getItem('backmycodes_native_bio'), 'personal');

    vaults.removeVaultData(mainVault);
    expect(store.getItem('backmycodes_native_bio'), isNull);
  });

  test('deletes the first vault without touching the device keys', () {
    addVault(mainVault);
    store.setItem('backmycodes_vault_data', 'personal');
    addVault('work');
    store.setItem('backmycodes_locale', 'fr');

    vaults.removeVaultData(mainVault);

    expect(vaults.allVaultIds(), ['work']);
    expect(store.getItem('backmycodes_locale'), 'fr');
    expect(store.getItem('backmycodes_vault_data'), isNull);
  });

  test('wipes every vault but keeps the language', () {
    addVault(mainVault);
    addVault('diary');
    store.setItem('backmycodes_locale', 'fr');

    vaults.removeAllVaults();

    expect(vaults.allVaultIds(), isEmpty);
    expect(store.storedKeys(), ['backmycodes_locale']);
  });

  test('keeps the offline switch out of every vault', () {
    addVault(mainVault);
    addVault('work');
    store.setItem('backmycodes_offline', '{"on":true}');

    expect(vaults.keysOf(mainVault), isNot(contains('backmycodes_offline')));
    expect(vaults.keysOf('work'), isNot(contains('backmycodes_offline')));

    vaults.removeVaultData(mainVault);
    expect(store.getItem('backmycodes_offline'), '{"on":true}');
  });

  test('wipes every vault but keeps the language, the look and offline mode', () {
    addVault(mainVault);
    addVault('diary');
    store.setItem('backmycodes_locale', 'fr');
    store.setItem('backmycodes_theme', 'dark');
    store.setItem('backmycodes_offline', '{"on":true}');
    // What Premium kept there before Kemlock was free is old data now, and goes with the vaults
    store.setItem('backmycodes_premium', '{"active":true,"at":1}');
    store.setItem('backmycodes_unlock_erase', '{"after":10}');

    vaults.removeAllVaults();

    expect(vaults.allVaultIds(), isEmpty);
    expect(store.storedKeys().toSet(), {'backmycodes_locale', 'backmycodes_theme', 'backmycodes_offline'});
  });

  group('an erase of every vault the app is killed in the middle of', () {
    const note = '{"at":1,"after":10}';
    const phone = {
      'backmycodes_vault_config': '{"salt":"s"}',
      'backmycodes_vault_data': 'personal',
      'backmycodes_unlock_erase': '{"after":10}',
      'backmycodes_vault_config::diary': '{"salt":"s"}',
      'backmycodes_vault_data::diary': 'diary',
      'backmycodes_locale': 'fr',
    };

    // The mark, the five keys, the note, the mark again
    for (var writes = 0; writes <= 8; writes++) {
      test('never leaves a vault without its mark, and the next launch finishes it, killed after $writes writes', () async {
        final storage = _KilledStorage(phone)..writesLeft = writes;
        final running = await KeyValueStore.open(storage);
        VaultRegistry(running).removeAllVaults(erasedNote: note);
        await running.flush();

        // The app starts again, and its writes reach storage
        storage.writesLeft = null;
        final relaunched = await KeyValueStore.open(storage);
        final vaults = VaultRegistry(relaunched);
        if (writes == 0) {
          // Not begun: everything is as it was, the erase setting too
          expect(storage.values, phone);
        } else if (writes < 8) {
          expect(relaunched.getItem(keyErasing), note, reason: 'cut short, it says so');
        } else {
          expect(relaunched.getItem(keyErasing), isNull);
        }

        expect(vaults.finishCutShortErase(), writes > 0 && writes < 8);

        if (writes == 0) return;
        expect(vaults.allVaultIds(), isEmpty);
        expect(relaunched.getItem(keyErased), note);
        expect(relaunched.getItem(keyErasing), isNull);
        expect(relaunched.getItem('backmycodes_locale'), 'fr');
        await relaunched.flush();
        expect(storage.values, {'backmycodes_locale': 'fr', keyErased: note});
      });
    }

    test('a reset asked for by hand leaves no note, cut short or not', () async {
      final storage = _KilledStorage(phone)..writesLeft = 3;
      final running = await KeyValueStore.open(storage);
      VaultRegistry(running).removeAllVaults();
      await running.flush();

      final relaunched = await KeyValueStore.open(storage);
      expect(VaultRegistry(relaunched).finishCutShortErase(), isTrue);

      expect(VaultRegistry(relaunched).allVaultIds(), isEmpty);
      expect(relaunched.getItem(keyErased), isNull);
      expect(relaunched.storedKeys(), ['backmycodes_locale']);
    });

    test('nothing is finished at a launch without the mark', () {
      addVault(mainVault);

      expect(vaults.finishCutShortErase(), isFalse);
      expect(vaults.allVaultIds(), [mainVault]);
    });
  });

  test('tells listeners when the active vault changes, after the current task', () async {
    var heard = 0;
    vaults.listen(() => heard++);

    vaults.active = 'work';
    vaults.active = 'work';
    expect(heard, 0);
    await Future<void>.delayed(Duration.zero);

    expect(heard, 1);
  });

  test('makes six-byte hex ids', () {
    expect(VaultRegistry.newVaultId(), matches(RegExp(r'^[0-9a-f]{12}$')));
  });

  // openspec: add-security-key-unlock, task 5.5
  test('a key enrolled for a hidden vault, and its mode turned on, change no key outside that vault’s own', () async {
    final vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
    await vault.setupVault('pw');
    final hidden = await vault.createVault('Diary', 'diary', listed: false);
    final session = await vault.unlockAnyVault('diary', mainVault);
    await vault.setRecoveryKey(session, newKit());
    Map<String, String?> outside() => {
      for (final key in store.storedKeys())
        if (!key.endsWith('::$hidden')) key: store.getItem(key),
    };
    final before = outside();

    final proof = await vault.enrolKey(
      session,
      await vault.proveOwner(password: 'diary'),
      salt: vault.keyChallenge().salt,
      credential: randomBytes(64),
      output: randomBytes(32),
      name: 'Example Key',
      pinBound: true,
    );
    await vault.setUnlockMode(session, proof, UnlockMode.both);

    expect(outside(), before);
    expect(vault.unlockMode(hidden), UnlockMode.both);
    expect(vault.unlockMode(mainVault), UnlockMode.password);
  });
}

/// The phone's storage, which takes [writesLeft] more writes and then none,
/// as when the app is killed; null takes them all.
class _KilledStorage implements PreferencesBackend {
  _KilledStorage(Map<String, String> values) : values = {...values};

  final Map<String, String> values;
  int? writesLeft;

  bool _takes() {
    final left = writesLeft;
    if (left == null) return true;
    if (left == 0) return false;
    writesLeft = left - 1;
    return true;
  }

  @override
  Future<Map<String, String>> readAll() async => {...values};

  @override
  Future<void> set(String key, String value) async {
    if (_takes()) values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (_takes()) values.remove(key);
  }
}
