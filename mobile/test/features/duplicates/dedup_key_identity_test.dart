import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/duplicates/dedup_store.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/vault_key.dart';

import '../keys/pgp_kit.dart';

// What tells a key or a contact when its `key` tag is made: crypto.md "Normalisation" has the
// fingerprint, an SSH key's `SHA256:` one or a PGP key's upper-case hex
void main() {
  const pgpFingerprint = 'E770227F48E661EAF271EAA7F92D39E6751913DD';

  Future<VaultKey> sshKey(String name) async {
    final parsed = await crypto.readPrivateKey(File('test/fixtures/keys/openssh/$name').readAsBytesSync());
    return vaultKeyOf(parsed, id: name, name: name, origin: KeyOrigin.imported);
  }

  test('an SSH key is its OpenSSH SHA256 fingerprint, as ssh-keygen -l prints it', () async {
    // From test/fixtures/keys/openssh/fingerprints.txt, which ssh-keygen wrote
    expect(dedupKeyIdentity(await sshKey('ed25519')), 'SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4');
  });

  test('a PGP key is its primary fingerprint in upper-case hex, whatever it holds besides', () async {
    final before = await pgpVaultKey();
    final after = await pgpVaultKey(path: 'gnupg/editing/signing-subkey.after.secret.asc', id: 'other-id');

    expect(dedupKeyIdentity(before), pgpFingerprint);
    expect(dedupKeyIdentity(after), pgpFingerprint);
  });

  test('a contact is its key\'s fingerprint in the same form, so it matches a key by it', () async {
    final key = await pgpVaultKey();
    final contact = Contact(id: 'c', name: 'Fixture', publicKey: key.publicKey!, source: ContactSource.file, addedAt: 0);

    expect(dedupKeyIdentity(contact), pgpFingerprint);
    expect(dedupKeyIdentity(Contact(id: 'd', name: 'Damaged', publicKey: 'AAAA', source: ContactSource.file, addedAt: 0)), isNull);
    expect(
      dedupKeyIdentity(Contact(id: 'e', name: 'Not base64', publicKey: 'not base64!', source: ContactSource.file, addedAt: 0)),
      isNull,
    );
  });

  test('a key whose public half will not read, or that is of another kind, is told by its bytes', () async {
    final key = await pgpVaultKey();
    final damaged = VaultKey.fromJson({...key.toJson(), 'public': 'AAAA'});
    final noPublic = VaultKey.fromJson({...key.toJson()}..remove('public'));
    const other = VaultKey(
      id: 'k',
      name: 'n',
      kind: KeyKind.exchange,
      algorithm: 'x25519',
      privateKey: 'PRIV',
      publicKey: 'PUB',
      origin: KeyOrigin.generated,
      addedAt: 1,
    );

    expect(dedupKeyIdentity(damaged), 'AAAA');
    expect(dedupKeyIdentity(noPublic), key.privateKey);
    expect(dedupKeyIdentity(other), 'PUB');
  });

  test('an item that is no key or contact has none', () {
    expect(dedupKeyIdentity('not an item'), isNull);
  });

  test('the key tag uses the fingerprint as it is, and none for an empty one', () {
    expect(keyTagInput('SHA256:abcdef')!.array, ['key', 'SHA256:abcdef']);
    expect(keyTagInput(pgpFingerprint)!.array, ['key', pgpFingerprint]);
    expect(keyTagInput(' SHA256:abcdef ')!.values, [' SHA256:abcdef ']);
    expect(keyTagInput(''), isNull);
    expect(keyTagInput(null), isNull);
  });
}
