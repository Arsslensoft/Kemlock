import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/pgp/pgp_controller.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../pgp/pgp_kit.dart';

/// A file of test/fixtures/mail (see its README).
Uint8List mailFixture(String name) => File('test/fixtures/mail/$name').readAsBytesSync();

/// A test key of test/fixtures/keys/gnupg, binary.
Uint8List gnupgKey(String name) => File('test/fixtures/keys/gnupg/$name.gpg').readAsBytesSync();

/// The fingerprints of the two GnuPG test keys.
const edFingerprint = '1FCDA135EE42400EC2B77CE677249ABE661CF8DB';
const rsaFingerprint = 'EA29C79D1C6570277907BB485D49D28C8EFC2F98';
const edProtectedFingerprint = '1BB5EC3961E61EE44F919AB63FCD57EBA0308CA9';

/// The key ID of a v4 fingerprint, as the OpenPGP API passes it: the low
/// 64 bits, as a signed long.
int keyIdOf(String fingerprint) =>
    (int.parse(fingerprint.substring(24, 32), radix: 16) << 32) | int.parse(fingerprint.substring(32), radix: 16);

/// A job that runs on the test's own isolate.
PgpJob inlineJob(PgpRequest request, {Directory? directory}) => ImmediateJob(request, directory);

/// A phone with one vault, open, in a provider container: real storage in
/// memory, real sealing, a fixed clock and PGP jobs run on the test's
/// isolate. The password of the first vault is `pw`.
class MailPhone {
  MailPhone._(this.store, this.vaults, this.vaultStore, this.container);

  final KeyValueStore store;
  final VaultRegistry vaults;
  final VaultStore vaultStore;
  final ProviderContainer container;

  static Future<MailPhone> open({DateTime? now, List<Override> overrides = const [], KeyValueStore? store}) async {
    final kv = store ?? KeyValueStore.memory();
    final vaults = VaultRegistry(kv);
    final vaultStore = VaultStore(kv, vaults, deriveKey: fastKdf);
    final container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        messageCatalogProvider.overrideWithValue(testCatalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        FakeUnlockKeys(available: false).asOverride,
        clockProvider.overrideWithValue(() => now ?? testNow),
        pgpJobStarterProvider.overrideWithValue(inlineJob),
        ...overrides,
      ],
    );
    final phone = MailPhone._(kv, vaults, vaultStore, container);
    if (!vaultStore.isVaultSetup()) await vaultStore.setupVault('pw');
    await phone.unlock('pw');
    return phone;
  }

  VaultController get vault => container.read(vaultControllerProvider.notifier);

  VaultState get state => container.read(vaultControllerProvider);

  /// Opens the vault [password] opens, as the lock screen does: the first
  /// vault, or a hidden one.
  Future<void> unlock(String password) async {
    final session = await vaultStore.unlockAnyVault(password, mainVault);
    await vault.open(session);
  }

  void lock() => vault.lock();

  /// Adds a hidden vault with [password] and returns its id; the open vault stays open.
  Future<String> addHiddenVault(String password) => vaultStore.createVault('Hidden', password, listed: false);

  /// Puts a fixture key of `fixtureKeys` in the open vault, under the id `pgp-<name>`.
  Future<VaultKey> addKey(String name) async {
    final (path, title) = fixtureKeys[name]!;
    final parsed = await crypto.readPrivateKey(fixtureBytes(path));
    final key = vaultKeyOf(parsed, id: 'pgp-$name', name: title, origin: KeyOrigin.imported);
    await vault.addKey(key);
    return key;
  }

  /// Puts the public key at [path] (under test/fixtures, armored or not)
  /// among the open vault's contacts, checked when [checked].
  Future<Contact> addContact(String id, String path, {required String name, required String fingerprint, bool checked = false}) async {
    final key = await pgp.readPgpPublicKey(fixtureBytes(path));
    final contact = Contact(
      id: id,
      name: name,
      publicKey: b64(key.transferableKey),
      source: ContactSource.file,
      checkedAt: checked ? testNow.millisecondsSinceEpoch : null,
      checkedFingerprint: checked ? fingerprint : null,
      addedAt: 0,
    );
    await vault.addContact(contact);
    return state.contacts.firstWhere((c) => c.id == id);
  }

  void dispose() => container.dispose();
}
