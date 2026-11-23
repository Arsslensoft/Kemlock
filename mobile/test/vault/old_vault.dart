import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/vault/sealed_value.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import 'fast_kdf.dart';
import 'rotation_helpers.dart';

/// Turns [vault] of [phone], open in [session] with [password], into a
/// vault as versions before authenticated values left it: see [makeVaultOld].
Future<void> makeOld(Phone phone, VaultSession session, String password, {RecoveryKey? kit, String vault = mainVault}) =>
    makeVaultOld(phone.store, phone.vaults, phone.vault, session, password, kit: kit, id: vault);

/// Turns the vault [id] in [store], open in [session] with [password], into
/// a vault as versions before authenticated values left it: the private key
/// wrapped under the password with a random nonce, the Recovery Kit's wrap
/// too when [kit] is given, and every value sealed with the public key
/// alone. Nothing in it then says its values are authenticated.
Future<void> makeVaultOld(
  KeyValueStore store,
  VaultRegistry vaults,
  VaultStore vault,
  VaultSession session,
  String password, {
  RecoveryKey? kit,
  String id = mainVault,
}) async {
  final key = vaults.vaultKey(keyConfig, id);
  final config = jsonDecode(store.getItem(key)!) as Map<String, Object?>;
  final kek = await fastKdf(password, unb64(config['salt']! as String));
  final wrapped = await aesGcmEncrypt(kek, session.secretKey);
  final old = {...config, 'skNonce': b64(wrapped.nonce), 'skEnc': b64(wrapped.ct)};
  if (kit != null) old['recovery'] = await wrapForKit(kit, session.secretKey);
  store.setItem(key, jsonEncode(old));
  for (final sealed in vault.sealedValueKeys(id)) {
    final plain = await openRaw(store.getItem(sealed)!, session.secretKey);
    store.setItem(sealed, await sealRaw(plain, session.publicKey));
  }
}

/// [vault]'s config on [phone].
Map<String, Object?> configOf(Phone phone, [String vault = mainVault]) =>
    jsonDecode(phone.store.getItem(phone.vaults.vaultKey(keyConfig, vault))!) as Map<String, Object?>;

/// Whether [vault]'s config says its values are authenticated.
bool saysAuthenticated(Phone phone, [String vault = mainVault]) => isAuthenticatedWrapNonce(configOf(phone, vault)['skNonce']);

/// Whether [vault]'s Recovery Kit wrap says its values are authenticated.
bool kitSaysAuthenticated(Phone phone, [String vault = mainVault]) =>
    isAuthenticatedWrapNonce((configOf(phone, vault)['recovery']! as Map<String, Object?>)['nonce']);

/// Checks that every sealed value of [vault] is authenticated for the key
/// it sits under, by [session]'s private key.
Future<void> expectEveryValueAuthenticated(Phone phone, VaultSession session, {String vault = mainVault}) async {
  final keys = phone.vault.sealedValueKeys(vault);
  expect(keys, isNotEmpty);
  for (final key in keys) {
    final opened = await openSealedValue(jsonDecode(phone.store.getItem(key)!) as Map<String, Object?>, session.secretKey, storageKey: key);
    expect(opened.verified, isTrue, reason: key);
  }
}
