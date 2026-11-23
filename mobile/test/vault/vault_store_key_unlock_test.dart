import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/scrypt.dart';
import 'package:kemlock/platform/unlock_keys.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/sealed_value.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/crashing_store.dart';
import '../fakes/fake_unlock_keys.dart';
import '../helpers/old_biometric_entry.dart';
import 'fast_kdf.dart';
import 'key_unlock_fixtures_test.dart' show KeyUnlockFixture;
import 'rotation_helpers.dart';

/// What a security key holds for a vault and gives for its salt. The store
/// never talks to a key: it takes what one gave.
class TestKey {
  final Uint8List credential = randomBytes(64);
  final Uint8List output = randomBytes(32);

  KeyReading get reading => (credential: credential, output: Uint8List.fromList(output));

  /// What a key that is not this one would give for the same credential.
  KeyReading get forged => (credential: credential, output: randomBytes(32));
}

/// What a password typed on the lock screen did.
enum Typed { opened, needsKey, wrong }

// openspec: add-security-key-unlock, section 4
void main() {
  late CrashingStore store;
  late Phone phone;
  late VaultStore vault;
  late VaultSession session;

  setUp(() async {
    store = CrashingStore();
    phone = Phone(store);
    vault = phone.vault;
    session = await vault.setupVault('pw');
  });

  String rawConfig([String id = mainVault]) => phone.store.getItem(phone.vaults.vaultKey(keyConfig, id))!;
  Map<String, Object?> config([String id = mainVault]) => jsonDecode(rawConfig(id)) as Map<String, Object?>;

  /// Enrols [key] for the active vault of [on] with [proof], as the sheet does.
  Future<OwnerProof> enrol(
    OwnerProof proof,
    TestKey key, {
    bool pinBound = true,
    String name = 'Example Key',
    VaultStore? on,
    VaultSession? of,
  }) {
    final target = on ?? vault;
    return target.enrolKey(
      of ?? session,
      proof,
      salt: target.keyChallenge().salt,
      credential: key.credential,
      output: key.output,
      name: name,
      pinBound: pinBound,
    );
  }

  /// A vault with one key enrolled and, unless [kit] is false, a Recovery
  /// Kit, in [mode]. Returns the proof for it as it is.
  Future<OwnerProof> inMode(UnlockMode mode, TestKey key, {bool kit = true, bool pinBound = true}) async {
    if (kit) await vault.setRecoveryKey(session, newKit());
    var proof = await enrol(await vault.proveOwner(password: 'pw'), key, pinBound: pinBound);
    if (mode != UnlockMode.password) proof = await vault.setUnlockMode(session, proof, mode);
    return proof;
  }

  /// The proof for the vault in [mode], given afresh.
  Future<OwnerProof> prove(UnlockMode mode, TestKey key, {String password = 'pw'}) => vault.proveOwner(
    password: mode.hasPassword ? password : null,
    key: mode.needsKey || vault.enrolledKeys().isNotEmpty ? key.reading : null,
  );

  Future<(Typed, PendingKeyStep?)> type(String password, {String? chosen = mainVault, VaultStore? on}) async {
    try {
      return switch (await (on ?? vault).beginUnlock(password, chosen)) {
        UnlockOpened() => (Typed.opened, null),
        UnlockNeedsKey(:final pending) => (Typed.needsKey, pending),
      };
    } on IncorrectPasswordError {
      return (Typed.wrong, null);
    }
  }

  group('enrolling keys', () {
    test('a first key writes keyUnlock with mode "password", and the vault still opens with its password', () async {
      final key = TestKey();
      final before = config();

      final proof = await enrol(await vault.proveOwner(password: 'pw'), key);

      final unlock = KeyUnlock.of(config())!;
      expect(unlock.mode, UnlockMode.password);
      expect(unlock.check, isNull);
      expect(unlock.salt, hasLength(32));
      final entry = unlock.keys.single;
      expect(entry.name, 'Example Key');
      expect(entry.credential, key.credential);
      expect(entry.pinBound, isTrue);
      expect(entry.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(entry.addedAt, greaterThan(0));
      expect(vault.enrolledKeys().single.id, entry.id);
      expect(vault.unlockMode(), UnlockMode.password);
      // Everything else in the config is as it was, the private key's wrap included
      expect({...config()}..remove('keyUnlock'), before);
      expect((await vault.unlockAnyVault('pw', mainVault)).secretKey, session.secretKey);
      expect((await vault.unlockVault('pw')).secretKey, session.secretKey);
      // The entry wraps the key secret the proof now holds
      expect(await unwrapKeySecret(entry, key.output, unlock.salt), proof.keySecret);
      expect(proof.keySecret, hasLength(32));
    });

    test('a second key wraps the same key secret', () async {
      final first = TestKey();
      final second = TestKey();
      final proof = await enrol(await vault.proveOwner(password: 'pw'), first);
      await enrol(proof, second, name: 'Spare');

      final unlock = KeyUnlock.of(config())!;
      expect(unlock.keys.map((key) => key.name), ['Example Key', 'Spare']);
      final secrets = [
        await unwrapKeySecret(unlock.keys[0], first.output, unlock.salt),
        await unwrapKeySecret(unlock.keys[1], second.output, unlock.salt),
      ];
      expect(secrets[0], secrets[1]);
      expect(unlock.keys[0].id, isNot(unlock.keys[1].id));
      // Neither key's output opens the other's entry
      await expectLater(unwrapKeySecret(unlock.keys[1], first.output, unlock.salt), throwsA(isA<AesGcmAuthError>()));
    });

    test('a further key needs the key secret, which an enrolled key gives', () async {
      final first = TestKey();
      await enrol(await vault.proveOwner(password: 'pw'), first);
      final stored = rawConfig();

      // The password alone is the proof of this vault, but holds no key secret
      final passwordOnly = await vault.proveOwner(password: 'pw');
      expect(passwordOnly.keySecret, isNull);
      await expectLater(enrol(passwordOnly, TestKey()), throwsA(isA<ProofIncompleteError>()));
      expect(rawConfig(), stored);

      final withKey = await vault.proveOwner(password: 'pw', key: first.reading);
      await enrol(withKey, TestKey());
      expect(vault.enrolledKeys(), hasLength(2));
    });

    test('the same key cannot be enrolled twice, nor under another salt', () async {
      final key = TestKey();
      final proof = await enrol(await vault.proveOwner(password: 'pw'), key);
      final stored = rawConfig();

      await expectLater(enrol(proof, key), throwsA(isA<KeyAlreadyEnrolledError>()));
      await expectLater(
        vault.enrolKey(
          session,
          proof,
          salt: randomBytes(32),
          credential: randomBytes(64),
          output: randomBytes(32),
          name: 'x',
          pinBound: true,
        ),
        throwsArgumentError,
      );
      expect(rawConfig(), stored);
    });

    test('a key is renamed', () async {
      final key = TestKey();
      final proof = await enrol(await vault.proveOwner(password: 'pw'), key);
      final id = vault.enrolledKeys().single.id;

      await vault.renameKey(session, proof, id, '  Blue key ');

      expect(vault.enrolledKeys().single.name, 'Blue key');
      expect(vault.enrolledKeys().single.id, id);
      await expectLater(vault.renameKey(session, proof, 'ffffffffffffffff', 'x'), throwsA(isA<KeyNotEnrolledError>()));
    });

    test('removing the last key removes keyUnlock and leaves the config as before the first enrolment', () async {
      final before = rawConfig();
      final first = TestKey();
      final second = TestKey();
      var proof = await enrol(await vault.proveOwner(password: 'pw'), first);
      proof = await enrol(proof, second);
      final ids = [for (final key in vault.enrolledKeys()) key.id];

      await vault.removeKey(session, proof, ids[0]);
      expect(vault.enrolledKeys().single.id, ids[1]);
      // The removed key's output opens nothing that is left
      final unlock = KeyUnlock.of(config())!;
      await expectLater(unwrapKeySecret(unlock.keys.single, first.output, unlock.salt), throwsA(isA<AesGcmAuthError>()));
      expect(unlock.keyFor(first.credential), isNull);

      await vault.removeKey(session, proof, ids[1]);
      expect(rawConfig(), before);
      expect(vault.enrolledKeys(), isEmpty);
      expect(vault.keyChallenge().credentials, isEmpty);
    });

    test('nothing outside the vault’s config is written', () async {
      await fillVault(vault, phone.store, keyFuture, session);
      final other = await vault.createVault('Work', 'work', listed: true);
      Map<String, String?> others() => {...phone.snapshot}..remove(keyConfig);
      final before = others();
      final key = TestKey();

      var proof = await enrol(await vault.proveOwner(password: 'pw'), key);
      proof = await enrol(proof, TestKey());
      await vault.renameKey(session, proof, vault.enrolledKeys().first.id, 'Renamed');
      await vault.setUnlockMode(session, proof, UnlockMode.both);

      expect(others(), before);
      expect(KeyUnlock.of(config(other)), isNull);
    });

    test('the proof of another vault, or of another key pair, allows nothing', () async {
      final key = TestKey();
      final proof = await vault.proveOwner(password: 'pw');
      final work = await vault.createVault('Work', 'work', listed: true);
      final workSession = await vault.unlockAnyVault('work', work);
      final stored = rawConfig(work);

      // Work is the active vault now: Personal's proof is not its own
      await expectLater(enrol(proof, key, of: workSession), throwsA(isA<ProofIncompleteError>()));
      // And Work's proof with Personal's session
      final workProof = await vault.proveOwner(password: 'work');
      await expectLater(enrol(workProof, key), throwsStateError);
      expect(rawConfig(work), stored);
    });

    test('a proof that was wiped allows nothing', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.both, key);
      final stored = rawConfig();
      proof.wipe();

      await expectLater(vault.setUnlockMode(session, proof, UnlockMode.password), throwsA(isA<IncorrectPasswordError>()));
      await expectLater(enrol(proof, TestKey()), throwsA(isA<IncorrectPasswordError>()));
      expect(rawConfig(), stored);
    });

    test('a keyUnlock a newer version wrote is not written over', () async {
      final raw = rawConfig();
      phone.store.setItem(keyConfig, '${raw.substring(0, raw.length - 1)},"keyUnlock":{"v":2,"mode":"later"}}');
      final stored = rawConfig();

      await expectLater(enrol(await vault.proveOwner(password: 'pw'), TestKey()), throwsStateError);
      expect(rawConfig(), stored);
    });
  });

  group('the proof', () {
    test('needs the password of a password vault, and a key only when one is given', () async {
      final key = TestKey();
      await inMode(UnlockMode.password, key);

      await expectLater(vault.proveOwner(), throwsA(isA<ProofIncompleteError>()));
      await expectLater(vault.proveOwner(password: 'nope'), throwsA(isA<IncorrectPasswordError>()));
      await expectLater(vault.proveOwner(password: 'pw', key: TestKey().reading), throwsA(isA<KeyNotEnrolledError>()));
      await expectLater(vault.proveOwner(password: 'pw', key: key.forged), throwsA(isA<KeyNotEnrolledError>()));
      final proof = await vault.proveOwner(password: 'pw', key: key.reading);
      expect(proof.passwordKey, isNotNull);
      expect(proof.keySecret, isNotNull);
    });

    test('needs an enrolled key of a key-only vault, and no password', () async {
      final key = TestKey();
      await inMode(UnlockMode.key, key);

      await expectLater(vault.proveOwner(password: 'pw'), throwsA(isA<ProofIncompleteError>()));
      await expectLater(vault.proveOwner(key: TestKey().reading), throwsA(isA<KeyNotEnrolledError>()));
      await expectLater(vault.proveOwner(key: key.forged), throwsA(isA<KeyNotEnrolledError>()));
      final proof = await vault.proveOwner(key: key.reading);
      expect(proof.passwordKey, isNull);
      expect(proof.keySecret, hasLength(32));
    });

    test('needs both of a vault that needs both', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);

      await expectLater(vault.proveOwner(password: 'pw'), throwsA(isA<ProofIncompleteError>()));
      await expectLater(vault.proveOwner(key: key.reading), throwsA(isA<ProofIncompleteError>()));
      await expectLater(vault.proveOwner(password: 'nope', key: key.reading), throwsA(isA<IncorrectPasswordError>()));
      await expectLater(vault.proveOwner(password: 'pw', key: key.forged), throwsA(isA<KeyNotEnrolledError>()));
      final proof = await vault.proveOwner(password: 'pw', key: key.reading);
      expect(proof.passwordKey, isNotNull);
      expect(proof.keySecret, isNotNull);
    });
  });

  group('changing the mode', () {
    for (final from in UnlockMode.values) {
      for (final to in UnlockMode.values.where((mode) => mode != from)) {
        test('from ${from.name} to ${to.name}: the old mode’s proof is needed, then only the new mode’s secrets open the vault', () async {
          final key = TestKey();
          await inMode(from, key);
          final stored = rawConfig();
          final needsNewPassword = to.hasPassword && !from.hasPassword;
          final password = needsNewPassword ? 'a new password' : 'pw';

          // Without what opens the vault now there is no proof
          if (from.hasPassword) {
            await expectLater(vault.proveOwner(password: 'nope', key: key.reading), throwsA(isA<IncorrectPasswordError>()));
          }
          if (from.needsKey) {
            await expectLater(vault.proveOwner(password: 'pw'), throwsA(isA<ProofIncompleteError>()));
            await expectLater(vault.proveOwner(password: 'pw', key: key.forged), throwsA(isA<KeyNotEnrolledError>()));
          } else if (to.needsKey) {
            // The password is the proof of a password vault, but the change needs the key secret
            await expectLater(
              vault.setUnlockMode(session, await vault.proveOwner(password: 'pw'), to),
              throwsA(isA<ProofIncompleteError>()),
            );
          }
          if (needsNewPassword) {
            await expectLater(vault.setUnlockMode(session, await prove(from, key), to), throwsA(isA<ProofIncompleteError>()));
          }
          expect(rawConfig(), stored);

          final proof = await vault.setUnlockMode(session, await prove(from, key), to, newPassword: needsNewPassword ? password : null);

          expect(vault.unlockMode(), to);
          expect(KeyUnlock.of(config())!.check == null, to != UnlockMode.both);
          expect(proof.passwordKey == null, !to.hasPassword);
          // The proof given back is the new mode's
          await vault.renameKey(session, proof, vault.enrolledKeys().single.id, 'Checked');

          final (typed, pending) = await type(password);
          switch (to) {
            case UnlockMode.password:
              expect(typed, Typed.opened);
              await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading), throwsA(isA<ProofIncompleteError>()));
            case UnlockMode.key:
              expect(typed, Typed.wrong);
              expect((await vault.unlockWithSecurityKey(mainVault, key.reading)).secretKey, session.secretKey);
              await expectLater(vault.unlockWithSecurityKey(mainVault, key.forged), throwsA(isA<KeyNotEnrolledError>()));
            case UnlockMode.both:
              expect(typed, Typed.needsKey);
              // Neither alone, nor each with the other wrong
              await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading), throwsA(isA<ProofIncompleteError>()));
              await expectLater(vault.unlockWithSecurityKey(mainVault, key.forged, pending: pending), throwsA(isA<KeyNotEnrolledError>()));
              expect((await type('nope')).$1, Typed.wrong);
              expect((await vault.unlockWithSecurityKey(mainVault, key.reading, pending: pending)).secretKey, session.secretKey);
          }
          // The old password of a vault that got a new one opens nothing
          if (needsNewPassword) expect((await type('pw')).$1, Typed.wrong);
          // What an older version does with the password: the plain wrap
          if (to.needsKey) await expectLater(vault.unlockVault(password), throwsA(isA<AesGcmAuthError>()));
        });
      }
    }

    test('"key" is refused while an enrolled key does not tie its secret to its PIN, and "both" is not', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key, pinBound: false);
      final stored = rawConfig();

      expect(vault.unlockModeRefusal(UnlockMode.key), isA<KeyNotPinBoundError>());
      await expectLater(vault.setUnlockMode(session, proof, UnlockMode.key), throwsA(isA<KeyNotPinBoundError>()));
      expect(rawConfig(), stored);

      expect(vault.unlockModeRefusal(UnlockMode.both), isNull);
      await vault.setUnlockMode(session, proof, UnlockMode.both);
      expect(vault.unlockMode(), UnlockMode.both);
      // Nor from "both" with such a key
      await expectLater(
        vault.setUnlockMode(session, await prove(UnlockMode.both, key), UnlockMode.key),
        throwsA(isA<KeyNotPinBoundError>()),
      );
      // One key that does among two is not enough
      await enrol(await prove(UnlockMode.both, key), TestKey());
      expect(vault.unlockModeRefusal(UnlockMode.key), isA<KeyNotPinBoundError>());
    });

    test('a new password that opens another vault is refused, whichever way that vault opens', () async {
      final key = TestKey();
      await inMode(UnlockMode.key, key);
      // Work opens with its password, Diary needs both
      await vault.createVault('Work', 'work password', listed: true);
      final diary = await vault.createVault('Diary', 'diary password', listed: true);
      final diarySession = await vault.unlockAnyVault('diary password', diary);
      await vault.setRecoveryKey(diarySession, newKit());
      final diaryKey = TestKey();
      final diaryProof = await enrol(await vault.proveOwner(password: 'diary password'), diaryKey, of: diarySession);
      await vault.setUnlockMode(diarySession, diaryProof, UnlockMode.both);
      phone.vaults.active = mainVault;
      final stored = rawConfig();

      for (final taken in ['work password', 'diary password']) {
        await expectLater(
          vault.setUnlockMode(session, await vault.proveOwner(key: key.reading), UnlockMode.password, newPassword: taken),
          throwsA(isA<PasswordInUseError>()),
          reason: taken,
        );
      }
      expect(rawConfig(), stored);
      expect(await vault.passwordOpensAVault('diary password'), isTrue);
      expect(await vault.passwordOpensAVault('work password'), isTrue);
      expect(await vault.passwordOpensAVault('pw'), isFalse);
      // The password it had before it went key-only is free again
      await vault.setUnlockMode(session, await vault.proveOwner(key: key.reading), UnlockMode.both, newPassword: 'pw');
      expect(await vault.passwordOpensAVault('pw'), isTrue);
    });

    test('a new password for a vault that opened with a key alone keeps the salt the vaults share', () async {
      final key = TestKey();
      await inMode(UnlockMode.key, key);
      final salt = config()['salt'];

      await vault.setUnlockMode(session, await vault.proveOwner(key: key.reading), UnlockMode.password, newPassword: 'back again');

      expect(config()['salt'], salt);
      expect((await vault.unlockAnyVault('back again', mainVault)).secretKey, session.secretKey);
    });

    test('a hidden vault is refused "key" and takes "both"', () async {
      final hidden = await vault.createVault('Diary', 'diary', listed: false);
      final hiddenSession = await vault.unlockAnyVault('diary', mainVault);
      expect(phone.vaults.active, hidden);
      await vault.setRecoveryKey(hiddenSession, newKit());
      final key = TestKey();
      final proof = await enrol(await vault.proveOwner(password: 'diary'), key, of: hiddenSession);
      final stored = rawConfig(hidden);

      expect(vault.unlockModeRefusal(UnlockMode.key), isA<HiddenVaultKeyOnlyError>());
      await expectLater(vault.setUnlockMode(hiddenSession, proof, UnlockMode.key), throwsA(isA<HiddenVaultKeyOnlyError>()));
      expect(rawConfig(hidden), stored);

      await vault.setUnlockMode(hiddenSession, proof, UnlockMode.both);
      expect(vault.unlockMode(hidden), UnlockMode.both);
    });

    test('a failure before the write leaves the stored config unchanged', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key);
      final stored = rawConfig();

      // The app dies at the write itself
      store.diesAt = store.writes + 1;
      await expectLater(vault.setUnlockMode(session, proof, UnlockMode.both), throwsA(isA<StoreDied>()));

      final next = Phone(store.reopen());
      expect(next.store.getItem(keyConfig), stored);
      expect((await next.vault.unlockAnyVault('pw', mainVault)).secretKey, session.secretKey);
    });

    test('a key derivation that fails leaves the stored config unchanged', () async {
      final memory = KeyValueStore.memory();
      final failing = VaultStore(
        memory,
        VaultRegistry(memory),
        deriveKey: (password, salt) => password == 'boom' ? throw StateError('no memory') : fastKdf(password, salt),
        unlockKeys: FakeUnlockKeys(),
      );
      final own = await failing.setupVault('pw');
      await failing.setRecoveryKey(own, newKit());
      final key = TestKey();
      var proof = await enrol(
        await failing.proveOwner(password: 'pw'),
        key,
        on: failing,
        of: own,
      );
      proof = await failing.setUnlockMode(own, proof, UnlockMode.key);
      final stored = memory.getItem(keyConfig);

      await expectLater(failing.setUnlockMode(own, proof, UnlockMode.both, newPassword: 'boom'), throwsStateError);

      expect(memory.getItem(keyConfig), stored);
      expect((await failing.unlockWithSecurityKey(mainVault, key.reading)).secretKey, own.secretKey);
    });

    test('biometric unlock goes before the commit, so a kill between them leaves the vault as it was without it', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key);
      await vault.enableBiometricUnlock(session, 'Turn it on');
      final stored = rawConfig();
      // The biometric entry is deleted; the config's write after it is not
      store.diesAt = store.writes + 2;
      await expectLater(vault.setUnlockMode(session, proof, UnlockMode.both), throwsA(isA<StoreDied>()));

      final next = Phone(store.reopen(), unlockKeys: phone.unlockKeys);
      expect(next.store.getItem(keyConfig), stored);
      expect(next.store.getItem(keyHardwareBio), isNull);
      expect(next.vault.unlockMode(), UnlockMode.password);
      expect(next.vault.hasBiometricUnlock(), isFalse);
      expect((await next.vault.unlockAnyVault('pw', mainVault)).secretKey, session.secretKey);
    });

    test('the commit is the last write: after it the vault is in the new mode, with no biometric entry', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key);
      await vault.enableBiometricUnlock(session, 'Turn it on');
      // The biometric entry is deleted and the config written; a write after that would die
      store.diesAt = store.writes + 3;
      await vault.setUnlockMode(session, proof, UnlockMode.both);

      final next = Phone(store.reopen(), unlockKeys: phone.unlockKeys);
      expect(next.vault.unlockMode(), UnlockMode.both);
      expect(next.store.getItem(keyHardwareBio), isNull);
      expect(next.vault.hasBiometricUnlock(), isFalse);
      final step = await next.vault.beginUnlock('pw', mainVault) as UnlockNeedsKey;
      expect((await next.vault.unlockWithSecurityKey(mainVault, key.reading, pending: step.pending)).secretKey, session.secretKey);
    });

    test('a hardware key that will not go does not stop the change', () async {
      final keys = _StuckKeys();
      final own = Phone(CrashingStore(), unlockKeys: keys);
      final opened = await own.vault.setupVault('pw');
      await own.vault.setRecoveryKey(opened, newKit());
      final key = TestKey();
      final proof = await enrol(
        await own.vault.proveOwner(password: 'pw'),
        key,
        on: own.vault,
        of: opened,
      );
      await own.vault.enableBiometricUnlock(opened, 'Turn it on');
      keys.stuck = true;

      await own.vault.setUnlockMode(opened, proof, UnlockMode.both);

      expect(own.vault.unlockMode(), UnlockMode.both);
      expect(own.store.getItem(keyHardwareBio), isNull);
      expect(keys.calls.last, 'delete main');
    });
  });

  group('the safety net', () {
    test('one key and no kit refuses both modes that need the key', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key, kit: false);
      final stored = rawConfig();

      for (final mode in [UnlockMode.key, UnlockMode.both]) {
        expect(vault.unlockModeRefusal(mode), isA<SafetyNetError>());
        await expectLater(vault.setUnlockMode(session, proof, mode), throwsA(isA<SafetyNetError>()));
      }
      expect(rawConfig(), stored);
      expect(vault.unlockModeRefusal(UnlockMode.password), isNull);
    });

    test('no key at all refuses them too', () async {
      await vault.setRecoveryKey(session, newKit());
      final stored = rawConfig();
      expect(vault.unlockModeRefusal(UnlockMode.both), isA<KeyNotEnrolledError>());
      await expectLater(
        vault.setUnlockMode(session, await vault.proveOwner(password: 'pw'), UnlockMode.both),
        throwsA(isA<KeyNotEnrolledError>()),
      );
      expect(rawConfig(), stored);
    });

    test('a kit allows them', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key);
      expect(vault.unlockModeRefusal(UnlockMode.key), isNull);
      expect(vault.unlockModeRefusal(UnlockMode.both), isNull);
      await vault.setUnlockMode(session, proof, UnlockMode.key);
      expect(vault.unlockMode(), UnlockMode.key);
    });

    test('two keys allow them', () async {
      final first = TestKey();
      var proof = await inMode(UnlockMode.password, first, kit: false);
      proof = await enrol(proof, TestKey());
      expect(vault.unlockModeRefusal(UnlockMode.both), isNull);
      await vault.setUnlockMode(session, proof, UnlockMode.both);
      expect(vault.unlockMode(), UnlockMode.both);
    });

    test('the kit is not deleted while it is the only way back in', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);
      final stored = phone.snapshot;

      expect(vault.recoveryKitIsLastWayBack(), isTrue);
      expect(vault.removeRecoveryKey, throwsA(isA<SafetyNetError>()));
      await expectLater(
        vault.replaceKeyPair(session, '', dropKit: true, proof: await prove(UnlockMode.both, key)),
        throwsA(isA<SafetyNetError>()),
      );
      expect(phone.snapshot, stored);
      expect(vault.recoveryKitInfo(), isNotNull);

      // With a second key the kit may go
      await enrol(await prove(UnlockMode.both, key), TestKey());
      expect(vault.recoveryKitIsLastWayBack(), isFalse);
      vault.removeRecoveryKey();
      expect(vault.recoveryKitInfo(), isNull);
    });

    test('the second key is not removed while there is no kit', () async {
      final first = TestKey();
      final second = TestKey();
      var proof = await inMode(UnlockMode.password, first, kit: false);
      proof = await enrol(proof, second);
      proof = await vault.setUnlockMode(session, proof, UnlockMode.both);
      final ids = [for (final key in vault.enrolledKeys()) key.id];
      final stored = rawConfig();

      for (final id in ids) {
        expect(vault.removeKeyRefusal(id), isA<SafetyNetError>());
        await expectLater(vault.removeKey(session, proof, id), throwsA(isA<SafetyNetError>()));
      }
      expect(rawConfig(), stored);

      // Once a kit is made, or the vault opens with its password again, it can go
      await vault.setRecoveryKey(session, newKit());
      expect(vault.removeKeyRefusal(ids[0]), isNull);
      await vault.removeKey(session, proof, ids[0]);
      expect(vault.enrolledKeys().single.id, ids[1]);
    });

    test('the last key cannot be removed while the vault needs one', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.key, key);
      final id = vault.enrolledKeys().single.id;
      final stored = rawConfig();

      expect(vault.removeKeyRefusal(id), isA<LastKeyError>());
      await expectLater(vault.removeKey(session, proof, id), throwsA(isA<LastKeyError>()));
      expect(rawConfig(), stored);

      // Back to a password, it can
      final back = await vault.setUnlockMode(session, proof, UnlockMode.password, newPassword: 'again');
      await vault.removeKey(session, back, id);
      expect(config().containsKey('keyUnlock'), isFalse);
      expect((await vault.unlockAnyVault('again', mainVault)).secretKey, session.secretKey);
    });

    test('a lost key is removed without it, and then opens nothing', () async {
      final lost = TestKey();
      final kept = TestKey();
      var proof = await inMode(UnlockMode.password, lost);
      proof = await enrol(proof, kept);
      await vault.setUnlockMode(session, proof, UnlockMode.key);
      final lostId = vault.enrolledKeys().first.id;

      // The proof is the key that is left
      await vault.removeKey(session, await vault.proveOwner(key: kept.reading), lostId);

      await expectLater(vault.unlockWithSecurityKey(mainVault, lost.reading), throwsA(isA<KeyNotEnrolledError>()));
      expect((await vault.unlockWithSecurityKey(mainVault, kept.reading)).secretKey, session.secretKey);
    });
  });

  group('unlocking', () {
    test('a vault needing both gives a pending step for the right password and nothing for a wrong one', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);
      phone.vaults.active = mainVault;
      final stored = phone.snapshot;

      final (typed, pending) = await type('pw');
      expect(typed, Typed.needsKey);
      expect(pending!.vault, mainVault);
      expect(pending.passwordKey, hasLength(32));
      expect((await type('nope')).$1, Typed.wrong);
      // Nothing is written by either
      expect(phone.snapshot, stored);
      await expectLater(vault.unlockAnyVault('pw', mainVault), throwsA(isA<SecurityKeyNeededError>()));
    });

    test('the step and an enrolled key’s output open it; either without the other does not', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);
      final (_, pending) = await type('pw');

      await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading), throwsA(isA<ProofIncompleteError>()));
      await expectLater(vault.unlockWithSecurityKey(mainVault, TestKey().reading, pending: pending), throwsA(isA<KeyNotEnrolledError>()));
      await expectLater(vault.unlockWithSecurityKey(mainVault, key.forged, pending: pending), throwsA(isA<KeyNotEnrolledError>()));
      // A step whose password key was dropped opens nothing
      final (_, dropped) = await type('pw');
      dropped!.wipe();
      await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading, pending: dropped), throwsA(isA<KeyNotEnrolledError>()));

      final opened = await vault.unlockWithSecurityKey(mainVault, key.reading, pending: pending);
      expect(opened.secretKey, session.secretKey);
      expect(opened.publicKey, session.publicKey);
    });

    test('another vault’s pending step does not open a vault', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);
      final work = await vault.createVault('Work', 'work', listed: true);
      final workSession = await vault.unlockAnyVault('work', work);
      await vault.setRecoveryKey(workSession, newKit());
      final workProof = await enrol(await vault.proveOwner(password: 'work'), key, of: workSession);
      await vault.setUnlockMode(workSession, workProof, UnlockMode.both);

      final (_, workPending) = await type('work', chosen: work);
      expect(workPending!.vault, work);
      await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading, pending: workPending), throwsA(isA<ProofIncompleteError>()));
      // One key, two vaults: it opens each with that vault's own step
      expect((await vault.unlockWithSecurityKey(work, key.reading, pending: workPending)).secretKey, workSession.secretKey);
      final (_, pending) = await type('pw');
      expect((await vault.unlockWithSecurityKey(mainVault, key.reading, pending: pending)).secretKey, session.secretKey);
    });

    test('a key-only vault opens with the output and with no password', () async {
      final key = TestKey();
      await inMode(UnlockMode.key, key);
      final work = await vault.createVault('Work', 'work', listed: true);
      phone.vaults.active = work;

      expect((await type('pw')).$1, Typed.wrong);
      final opened = await vault.unlockWithSecurityKey(mainVault, key.reading);

      expect(opened.secretKey, session.secretKey);
      expect(phone.vaults.active, mainVault);
      // A key that is not the vault's changes nothing
      phone.vaults.active = work;
      final stored = phone.snapshot;
      await expectLater(vault.unlockWithSecurityKey(mainVault, TestKey().reading), throwsA(isA<KeyNotEnrolledError>()));
      expect(phone.vaults.active, work);
      expect(phone.snapshot, stored);
    });

    test('each of two keys opens the vault on its own', () async {
      final first = TestKey();
      final second = TestKey();
      var proof = await inMode(UnlockMode.password, first);
      proof = await enrol(proof, second);
      await vault.setUnlockMode(session, proof, UnlockMode.both);
      expect(vault.keyChallenge().credentials, [first.credential, second.credential]);

      for (final key in [first, second]) {
        final (_, pending) = await type('pw');
        expect((await vault.unlockWithSecurityKey(mainVault, key.reading, pending: pending)).secretKey, session.secretKey);
      }
    });

    test('a hidden vault needing both is found by its password, and changes the active vault only when it opens', () async {
      final hidden = await vault.createVault('Diary', 'diary', listed: false);
      final hiddenSession = await vault.unlockAnyVault('diary', mainVault);
      await vault.setRecoveryKey(hiddenSession, newKit());
      final key = TestKey();
      final proof = await enrol(await vault.proveOwner(password: 'diary'), key, of: hiddenSession);
      await vault.setUnlockMode(hiddenSession, proof, UnlockMode.both);
      phone.vaults.active = mainVault;

      final (typed, pending) = await type('diary');
      expect(typed, Typed.needsKey);
      expect(pending!.vault, hidden);
      expect(phone.vaults.active, mainVault);

      final opened = await vault.unlockWithSecurityKey(hidden, key.reading, pending: pending);
      expect(opened.secretKey, hiddenSession.secretKey);
      expect(phone.vaults.active, hidden);
    });

    test('a key-pair replacement cut short is finished by a key unlock', () async {
      final key = TestKey();
      await inMode(UnlockMode.key, key);
      await fillVault(vault, phone.store, keyFuture, session);
      final kit = newKit();
      // The replacement's value, the config, one value sealed again, and then the app dies
      store.diesAt = store.writes + 4;
      await expectLater(
        vault.replaceKeyPair(
          session,
          '',
          kit: kit,
          proof: await vault.proveOwner(key: key.reading),
        ),
        throwsA(isA<StoreDied>()),
      );

      final next = Phone(store.reopen());
      expect(next.store.getItem(keyKeyRotation), isNotNull);
      final opened = await next.vault.unlockWithSecurityKey(mainVault, key.reading);

      expect(next.store.getItem(keyKeyRotation), isNull);
      expect(opened.secretKey, isNot(session.secretKey));
      await expectEveryItem(next.vault, opened);
      expect(next.vault.unlockMode(), UnlockMode.key);
    });

    test('a wrong password takes the same number of key derivations whichever way the vault on screen opens', () async {
      Future<int> derivations(UnlockMode mode, {required bool hidden}) async {
        final memory = KeyValueStore.memory();
        final registry = VaultRegistry(memory);
        var count = 0;
        final counting = VaultStore(
          memory,
          registry,
          deriveKey: (password, salt) {
            count++;
            return fastKdf(password, salt);
          },
          unlockKeys: FakeUnlockKeys(),
        );
        final own = await counting.setupVault('pw');
        await counting.setRecoveryKey(own, newKit());
        final key = TestKey();
        final proof = await enrol(
          await counting.proveOwner(password: 'pw'),
          key,
          on: counting,
          of: own,
        );
        if (mode != UnlockMode.password) await counting.setUnlockMode(own, proof, mode);
        if (hidden) {
          await counting.createVault('Diary', 'diary', listed: false);
          await counting.createVault('Journal', 'journal', listed: false);
        }
        count = 0;
        await expectLater(counting.beginUnlock('wrong', mainVault), throwsA(isA<IncorrectPasswordError>()));
        return count;
      }

      for (final hidden in [false, true]) {
        for (final mode in UnlockMode.values) {
          expect(await derivations(mode, hidden: hidden), 1, reason: '${mode.name}, hidden vaults: $hidden');
        }
      }
    });
  });

  group('changing the password and replacing the key pair', () {
    test('changing the password of a vault needing both keeps every enrolled key, and the old password opens nothing', () async {
      final first = TestKey();
      final second = TestKey();
      var proof = await inMode(UnlockMode.password, first);
      proof = await enrol(proof, second);
      await vault.setUnlockMode(session, proof, UnlockMode.both);
      final before = KeyUnlock.of(config())!;

      await vault.changePassword(session, 'a new password', proof: await prove(UnlockMode.both, first));

      final after = KeyUnlock.of(config())!;
      expect(after.mode, UnlockMode.both);
      expect(after.check, isNot(before.check));
      expect(jsonEncode([for (final key in after.keys) key.toJson()]), jsonEncode([for (final key in before.keys) key.toJson()]));
      expect((await type('pw')).$1, Typed.wrong);
      for (final key in [first, second]) {
        final (typed, pending) = await type('a new password');
        expect(typed, Typed.needsKey);
        expect((await vault.unlockWithSecurityKey(mainVault, key.reading, pending: pending)).secretKey, session.secretKey);
      }
      // The new password alone still opens nothing
      await expectLater(vault.unlockVault('a new password'), throwsA(isA<AesGcmAuthError>()));
    });

    test('changing the password of a password vault with its proof keeps its enrolled keys', () async {
      final key = TestKey();
      await inMode(UnlockMode.password, key);
      final before = jsonEncode(config()['keyUnlock']);

      await vault.changePassword(session, 'a new password', proof: await vault.proveOwner(password: 'pw'));

      expect(jsonEncode(config()['keyUnlock']), before);
      expect((await type('a new password')).$1, Typed.opened);
      expect((await type('pw')).$1, Typed.wrong);
    });

    test('a key-only vault has no password to change, and a wrong proof changes nothing', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.key, key);
      final stored = rawConfig();

      await expectLater(vault.changePassword(session, 'a new password', proof: proof), throwsStateError);
      expect(rawConfig(), stored);
    });

    for (final mode in UnlockMode.values) {
      test('replacing the key pair of a vault in mode ${mode.name} keeps every enrolled key and seals every value again', () async {
        final first = TestKey();
        final second = TestKey();
        var proof = await inMode(UnlockMode.password, first);
        proof = await enrol(proof, second);
        if (mode != UnlockMode.password) await vault.setUnlockMode(session, proof, mode);
        await fillVault(vault, phone.store, keyFuture, session);
        final before = jsonEncode(config()['keyUnlock']);

        final next = await vault.replaceKeyPair(session, 'pw', kit: newKit(), proof: mode.needsKey ? await prove(mode, first) : null);

        expect(next.secretKey, isNot(session.secretKey));
        expect(jsonEncode(config()['keyUnlock']), before);
        await expectEveryItem(vault, next);
        for (final key in phone.vault.sealedValueKeys(mainVault)) {
          await expectLater(openRaw(phone.store.getItem(key)!, session.secretKey), throwsA(isA<AesGcmAuthError>()), reason: key);
        }
        expect(phone.store.getItem(keyKeyRotation), isNull);
        // Each key opens the vault as before, to the new key pair
        for (final key in [first, second]) {
          switch (mode) {
            case UnlockMode.password:
              expect((await vault.unlockAnyVault('pw', mainVault)).secretKey, next.secretKey);
              expect((await vault.proveOwner(password: 'pw', key: key.reading)).keySecret, isNotNull);
            case UnlockMode.key:
              expect((await vault.unlockWithSecurityKey(mainVault, key.reading)).secretKey, next.secretKey);
            case UnlockMode.both:
              final (_, pending) = await type('pw');
              expect((await vault.unlockWithSecurityKey(mainVault, key.reading, pending: pending)).secretKey, next.secretKey);
          }
        }
      });
    }

    test('the password alone does not replace the key pair of a vault that needs a key', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);
      final stored = phone.snapshot;

      await expectLater(vault.replaceKeyPair(session, 'pw', kit: newKit()), throwsA(isA<IncorrectPasswordError>()));
      expect(phone.snapshot, stored);
    });

    test('a password that passes another vault’s check is in use', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);

      expect(await vault.passwordOpensAVault('pw'), isTrue);
      expect(await vault.passwordOpensAVault('nope'), isFalse);
      await expectLater(vault.createVault('Work', 'pw', listed: true), throwsA(isA<PasswordInUseError>()));
    });
  });

  group('the Recovery Kit', () {
    for (final mode in [UnlockMode.key, UnlockMode.both]) {
      test('opens a vault in mode ${mode.name}, and the new password then opens it alone', () async {
        final key = TestKey();
        final kit = newKit();
        await vault.setRecoveryKey(session, kit);
        await inMode(mode, key, kit: false);

        final recovered = await vault.unlockWithRecoveryKey(kit.kitId, kit.key);
        expect(recovered.secretKey, session.secretKey);
        // Abandoned before the password: the vault still needs its key
        expect(vault.unlockMode(), mode);
        expect((await type('pw')).$1, mode == UnlockMode.both ? Typed.needsKey : Typed.wrong);

        // The password alone changes nothing of a vault with keys: the kit's way back is its own
        final stored = rawConfig();
        await expectLater(vault.changePassword(recovered, 'after the kit'), throwsA(isA<ProofIncompleteError>()));
        expect(rawConfig(), stored);
        await vault.resetToPassword(recovered, 'after the kit');

        expect(config().containsKey('keyUnlock'), isFalse);
        expect(vault.unlockMode(), UnlockMode.password);
        expect((await vault.unlockAnyVault('after the kit', mainVault)).secretKey, session.secretKey);
        expect((await type('pw')).$1, Typed.wrong);
        // No enrolled key's output opens anything
        await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading), throwsA(isA<KeyNotEnrolledError>()));
        await expectLater(vault.proveOwner(password: 'after the kit', key: key.reading), throwsA(isA<KeyNotEnrolledError>()));
        // The kit itself is kept
        expect(vault.recoveryKitInfo()!.kitId, kit.kitId);
      });
    }

    test('removes the keys of a vault that opens with its password too', () async {
      final key = TestKey();
      final kit = newKit();
      await vault.setRecoveryKey(session, kit);
      await inMode(UnlockMode.password, key, kit: false);

      await vault.resetToPassword(await vault.unlockWithRecoveryKey(kit.kitId, kit.key), 'after the kit');

      expect(config().containsKey('keyUnlock'), isFalse);
    });

    test('writes for a vault without keys what changing its password writes', () async {
      final kit = newKit();
      await vault.setRecoveryKey(session, kit);
      final recovered = await vault.unlockWithRecoveryKey(kit.kitId, kit.key);
      final before = config();

      await vault.resetToPassword(recovered, 'after the kit');

      final after = config();
      expect(after.keys, before.keys);
      for (final key in before.keys.where((key) => !{'salt', 'skNonce', 'skEnc'}.contains(key))) {
        expect(jsonEncode(after[key]), jsonEncode(before[key]), reason: key);
      }
      expect((await vault.unlockAnyVault('after the kit', mainVault)).secretKey, session.secretKey);
    });
  });

  group('biometric unlock', () {
    test('both entries and the hardware key are gone once a mode that needs a key is on', () async {
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key);
      await vault.enableBiometricUnlock(session, 'Turn it on');
      await writeOldBiometricEntry(phone.store, phone.vaults, session);
      expect(vault.hasBiometricUnlock(), isTrue);
      phone.unlockKeys.calls.clear();

      await vault.setUnlockMode(session, proof, UnlockMode.both);

      expect(phone.store.getItem(keyHardwareBio), isNull);
      expect(phone.store.getItem(keyNativeBio), isNull);
      expect(phone.unlockKeys.calls, ['delete main']);
      expect(phone.unlockKeys.keys, isEmpty);
      expect(vault.hasBiometricUnlock(), isFalse);
    });

    test('cannot be turned on, and opens nothing, while the vault needs a key', () async {
      final key = TestKey();
      await inMode(UnlockMode.key, key);

      expect(() => vault.enableBiometricUnlock(session, 'Turn it on'), throwsStateError);
      // An entry found beside such a vault is deleted instead of used
      await writeOldBiometricEntry(phone.store, phone.vaults, session);
      expect(vault.hasBiometricUnlock(), isFalse);
      await expectLater(vault.unlockWithBiometrics('Unlock', _NoPrompt()), throwsA(isA<VaultMissingError>()));
      expect(phone.store.getItem(keyNativeBio), isNull);
    });

    test('stays as it is in mode "password", with or without keys enrolled', () async {
      await vault.enableBiometricUnlock(session, 'Turn it on');
      final key = TestKey();
      final proof = await inMode(UnlockMode.password, key);
      await vault.setUnlockMode(session, proof, UnlockMode.password);

      expect(vault.hasBiometricUnlock(), isTrue);
      expect((await vault.unlockWithBiometrics('Unlock', _NoPrompt())).session!.secretKey, session.secretKey);
    });
  });

  group('an older version', () {
    test('its Recovery Kit reset is honoured: a plain wrap that opens removes keyUnlock', () async {
      final key = TestKey();
      await inMode(UnlockMode.both, key);
      final needing = config();
      // What a version from before security keys writes after its kit unlock: a new password's
      // plain wrap, every other key of the config kept
      final salt = randomBytes(32);
      final wrapped = await aesGcmEncrypt(await fastKdf('older password', salt), session.secretKey);
      phone.store.setItem(keyConfig, jsonEncode({...needing, 'salt': b64(salt), 'skNonce': b64(wrapped.nonce), 'skEnc': b64(wrapped.ct)}));
      expect(vault.unlockMode(), UnlockMode.both);

      final opened = await vault.unlockAnyVault('older password', mainVault);

      expect(opened.secretKey, session.secretKey);
      expect(config().containsKey('keyUnlock'), isFalse);
      // The older version's wrap said nothing of authenticated values: the vault moved over again,
      // its wrap made anew under the same password, and nothing else changed
      Map<String, Object?> wrapless(Map<String, Object?> config) => {...config}
        ..remove('skNonce')
        ..remove('skEnc');
      expect(wrapless(config()), wrapless({...needing, 'salt': b64(salt)}..remove('keyUnlock')));
      expect(isAuthenticatedWrapNonce(config()['skNonce']), isTrue);
      expect(opened.authenticated, isTrue);
      expect((await vault.unlockAnyVault('older password', mainVault)).secretKey, session.secretKey);
      await expectLater(vault.unlockWithSecurityKey(mainVault, key.reading), throwsA(isA<KeyNotEnrolledError>()));
    });

    test('a vault that opens with its password and has keys enrolled is not touched by a password unlock', () async {
      final key = TestKey();
      await inMode(UnlockMode.password, key);
      final stored = rawConfig();
      await vault.unlockAnyVault('pw', mainVault);
      expect(rawConfig(), stored);
    });

    for (final name in ['key', 'both', 'both-two-keys']) {
      test('sees a wrong password for the fixture "$name", and writes nothing', () async {
        final fixture = KeyUnlockFixture(name);
        final memory = KeyValueStore.memory({keyConfig: fixture.rawConfig});
        // The password path as it was before security keys, with the real parameters
        final older = VaultStore(
          memory,
          VaultRegistry(memory),
          deriveKey: (password, salt) async => scrypt(utf8.encode(password), salt, n: scryptN, r: scryptR, p: scryptP),
          unlockKeys: FakeUnlockKeys(),
        );

        await expectLater(older.unlockVault(fixture.password), throwsA(isA<AesGcmAuthError>()));
        expect(memory.getItem(keyConfig), fixture.rawConfig);
        expect(memory.storedKeys(), [keyConfig]);
      });
    }

    test('this version opens the fixtures through the store, with the stated secrets', () async {
      for (final name in ['key', 'both', 'both-two-keys', 'password-with-key']) {
        final fixture = KeyUnlockFixture(name);
        final memory = KeyValueStore.memory({keyConfig: fixture.rawConfig});
        final real = VaultStore(
          memory,
          VaultRegistry(memory),
          deriveKey: (password, salt) async => scrypt(utf8.encode(password), salt, n: scryptN, r: scryptR, p: scryptP),
          unlockKeys: FakeUnlockKeys(),
        );
        final unlock = fixture.keyUnlock;
        for (final (index, entry) in unlock.keys.indexed) {
          final reading = (credential: entry.credential, output: fixture.outputs[index]);
          final VaultSession opened;
          switch (unlock.mode) {
            case UnlockMode.password:
              opened = await real.unlockAnyVault(fixture.password, mainVault);
              expect((await real.proveOwner(password: fixture.password, key: reading)).keySecret, fixture.keySecret);
            case UnlockMode.key:
              await expectLater(real.beginUnlock(fixture.password, mainVault), throwsA(isA<IncorrectPasswordError>()));
              opened = await real.unlockWithSecurityKey(mainVault, reading);
            case UnlockMode.both:
              final step = await real.beginUnlock(fixture.password, mainVault) as UnlockNeedsKey;
              opened = await real.unlockWithSecurityKey(mainVault, reading, pending: step.pending);
          }
          expect(fixture.isTheKey(opened.secretKey), isTrue, reason: name);
        }
      }
    });
  });
}

/// Hardware keys whose delete fails while [stuck].
class _StuckKeys extends FakeUnlockKeys {
  bool stuck = false;

  @override
  Future<void> delete(String vault) async {
    await super.delete(vault);
    if (stuck) throw const UnlockKeyFailed('The key would not go.');
  }
}

class _NoPrompt implements Biometrics {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}
