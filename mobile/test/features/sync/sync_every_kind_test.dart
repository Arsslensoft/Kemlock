// The sync files of test/fixtures/vault-items/sync-every-kind.json, written
// once when keys, notes and passkeys joined sync: a vault's own file with an
// entry of every kind and a deletion of each, and a space's file with a key
// and a note with a file. Phones already sync these, so this version, and
// the merge from before these items (pinned in test/compat), must both
// keep every entry and deletion in them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart' show vaultKeyOf;
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/vault_key.dart';

import '../../compat/before_vault_items/sync_merge.dart' as old;
import '../keys/pgp_kit.dart';
import 'fake_webdav.dart';
import 'sync_test.dart' show dav;

typedef _Json = Map<String, Object?>;

final _fixture = jsonDecode(File('test/fixtures/vault-items/sync-every-kind.json').readAsStringSync()) as _Json;

/// A minute after the last change in the files.
const _now = 1763200071000;

_Json _part(String which) => _fixture[which]! as _Json;

/// The document in [which]'s file, decrypted as plain JSON, without the code under test.
Future<_Json> _document(String which) async {
  final file = jsonDecode(_part(which)['file']! as String) as _Json;
  final plain = await aesGcmDecrypt(unb64(_part(which)['key']! as String), unb64(file['nonce']! as String), unb64(file['ct']! as String));
  return jsonDecode(utf8.decode(plain)) as _Json;
}

Future<SyncDoc> _open(String which) => decryptSyncFile(_part(which)['file']! as String, unb64(_part(which)['key']! as String));

Object? _plain(Object? json) => jsonDecode(jsonEncode(json));

void main() {
  group('this version', () {
    test("opens the vault's own file, every kind in it", () async {
      final doc = await _open('own');

      expect(
        (doc.accounts.length, doc.backupServices.length, doc.keys.single.name, doc.notes.single.files.length, doc.passkeys.single.rpId),
        (1, 1, 'laptop', 2, 'github.com'),
      );
      expect([for (final tomb in doc.deleted) tomb.id], ['a-gone', 'k-gone', 'n-gone', 'p-gone']);
      expect(doc.extra, isEmpty);
      expect(canonical(doc.toJson()), canonical(await _document('own')));
    });

    test("opens the space's file, which holds no passkeys", () async {
      final doc = await _open('space');

      expect((doc.keys.single.spaceId, doc.notes.single.spaceId, doc.notes.single.files.single.name), ('fam', 'fam', 'passport-scan.pdf'));
      expect(doc.passkeys, isEmpty);
      expect((await _document('space')).containsKey('passkeys'), isFalse);
      expect(canonical(doc.toJson()), canonical(await _document('space')));
    });

    for (final which in ['own', 'space']) {
      test('a merge with nothing changed here writes the $which file back as it was', () async {
        final remote = await _open(which);

        final merged = mergeScope(remote, remote.ids.toList(), remote, now: _now);

        expect(canonical(merged.doc.toJson()), canonical(await _document(which)));
        expect(merged.known.toSet(), remote.ids.toSet());
      });

      test('the $which file encrypted again opens to the same document', () async {
        final key = unb64(_part(which)['key']! as String);

        final again = await decryptSyncFile(await encryptSyncFile(await _open(which), key), key);

        expect(canonical(again.toJson()), canonical(await _document(which)));
      });
    }

    test("a passkey in the vault never goes into the space's file", () async {
      final own = await _open('own');
      final space = await _open('space');
      final all = Lists(keys: [...own.keys, ...space.keys], notes: [...own.notes, ...space.notes], passkeys: own.passkeys);

      final merged = mergeScope(scopeLists(all, 'fam'), space.ids.toList(), space, now: _now);

      expect(merged.doc.passkeys, isEmpty);
      expect(canonical(merged.doc.toJson()), canonical(await _document('space')));
    });

    // openspec: add-security-key-codes, task 8.4
    test("an account on a security key rides in the vault's own file and never in the space's", () async {
      final own = await _open('own');
      final space = await _open('space');
      const onKey = KeyAccount(id: 'ka1', device: '0102030405060708', name: 'Bank:ada', issuer: 'Bank', label: 'ada', addedAt: 1);
      final all = Lists(
        keys: [...own.keys, ...space.keys],
        notes: [...own.notes, ...space.notes],
        passkeys: own.passkeys,
        keyAccounts: [onKey],
      );

      final toSpace = mergeScope(scopeLists(all, 'fam'), space.ids.toList(), space, now: _now);
      final toOwn = mergeScope(
        scopeLists(Lists(accounts: own.accounts, backupServices: own.backupServices, keyAccounts: [onKey]), null),
        own.ids.toList(),
        own,
        now: _now,
      );

      expect(toSpace.doc.keyAccounts, isEmpty);
      expect(canonical(toSpace.doc.toJson()), canonical(await _document('space')));
      expect(toOwn.doc.keyAccounts, [onKey]);
      final key = unb64(_part('own')['key']! as String);
      final again = await decryptSyncFile(await encryptSyncFile(toOwn.doc, key), key);
      expect(again.keyAccounts, [onKey]);
    });

    // openspec: add-post-quantum-pgp, task 8.6
    test('a PGP key of each type, post-quantum ones locked or not, goes from one phone to the other as it was', () async {
      final keys = [
        for (final name in [
          'pgp-pq-standard.unprotected',
          'pgp-pq-standard.secret',
          'pgp-pq-gnupg.unprotected',
          'pgp-pq-gnupg.secret',
          'pgp-ed25519.unprotected',
          'pgp-rsa4096.secret',
        ])
          vaultKeyOf(
            await crypto.readPrivateKey(File('test/fixtures/keys/kemlock/$name.asc').readAsStringSync()),
            id: name,
            name: name,
            origin: KeyOrigin.generated,
          ),
      ];
      final key = unb64(_part('own')['key']! as String);

      // The first phone writes its file; the second, empty, takes it
      final first = mergeScope(Lists(keys: keys), [], null, now: _now);
      final file = await encryptSyncFile(first.doc, key);
      final second = mergeScope(const Lists(), [], await decryptSyncFile(file, key), now: _now);

      final held = {for (final key in second.doc.keys) key.id: key};
      expect(held.keys, unorderedEquals([for (final key in keys) key.id]));
      for (final key in keys) {
        expect(canonical(held[key.id]!.toJson()), canonical(key.toJson()), reason: key.id);
        final parsed = await crypto.readPrivateKey(unb64(held[key.id]!.privateKey));
        expect(parsed.pgp?.fingerprint, (await crypto.readPrivateKey(unb64(key.privateKey))).pgp?.fingerprint, reason: key.id);
        expect(held[key.id]!.protected, key.id.endsWith('.secret') ? isTrue : isNull, reason: key.id);
      }
    });
  });

  group('a phone from before keys, notes and passkeys', () {
    for (final which in ['own', 'space']) {
      test('reads the $which file and writes it back as it was', () async {
        final document = await _document(which);

        final doc = old.SyncDoc.fromJson(_plain(document)! as _Json);

        expect(old.canonical(doc.toJson()), old.canonical(document));
      });
    }

    test('adds a code and keeps every key, note, passkey and deletion, which this version then takes', () async {
      final document = await _document('own');
      final remote = old.SyncDoc.fromJson(_plain(document)! as _Json);
      const code = OtpAccount(id: 'a-new', issuer: 'GitLab', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1763200070000);

      final merged = old.mergeScope(
        old.Lists(accounts: [...remote.accounts, code], backupServices: remote.backupServices),
        [for (final account in remote.accounts) account.id, for (final service in remote.backupServices) service.id],
        remote,
        now: _now,
      );

      final written = _plain(merged.doc.toJson())! as _Json;
      for (final key in ['keys', 'notes', 'passkeys', 'deleted', 'backupServices']) {
        expect(written[key], document[key], reason: key);
      }
      expect(
        {for (final account in written['accounts']! as List<Object?>) (account! as _Json)['id']},
        {for (final account in document['accounts']! as List<Object?>) (account! as _Json)['id'], 'a-new'},
      );

      // A phone on this version, which holds what the file held before
      final before = await _open('own');
      final now = mergeScope(before, before.ids.toList(), SyncDoc.fromJson(written), now: _now);
      expect(now.doc.accounts.map((account) => account.id), contains('a-new'));
      expect(
        canonical([
          for (final key in ['keys', 'notes', 'passkeys']) now.doc.toJson()[key],
        ]),
        canonical([
          for (final key in ['keys', 'notes', 'passkeys']) document[key],
        ]),
      );
    });
  });

  // openspec: add-pgp-key-editing, design decision 6
  test('two phones that each changed one PGP key end with both changes, and a second round uploads nothing', () async {
    final server = FakeWebDav();
    final webDav = WebDav(server.client);
    final target = SyncTarget(dav: dav, file: syncFile, key: b64(randomBytes(32)));
    final key = await pgpVaultKey(updatedAt: 1000);
    Future<VaultKey> changed(crypto.PgpChange change, int at) async {
      final made = await crypto.makeKey(crypto.PgpChangeRequest(unb64(key.privateKey), change, now: DateTime.utc(2026, 11, 20, 12)));
      return key.withHalves(privateKey: b64(made.private), publicKey: b64(made.public!), protected: false).copyWith(updatedAt: at);
    }

    var phone = Lists(keys: [key]);
    var tablet = Lists(keys: [key]);
    var phoneKnown = <String>[];
    var tabletKnown = <String>[];
    Future<void> syncPhone(int at) async {
      final result = await syncScope(webDav, target, phone, phoneKnown, now: at);
      (phone, phoneKnown) = (applyScope(phone, null, result.doc), result.known);
    }

    Future<void> syncTablet(int at) async {
      final result = await syncScope(webDav, target, tablet, tabletKnown, now: at);
      (tablet, tabletKnown) = (applyScope(tablet, null, result.doc), result.known);
    }

    await syncPhone(2000);
    await syncTablet(2001);
    // Each changes the key before it syncs again
    phone = Lists(
      keys: [await changed(const crypto.AddPgpSubkey(type: crypto.PgpKeyType.ed25519, use: crypto.PgpSubkeyUse.encrypt), 3000)],
    );
    tablet = Lists(
      keys: [await changed(const crypto.AddPgpUserId(name: 'Ada', email: 'ada@work.example'), 3500)],
    );

    int puts() => server.requests.where((request) => request.method == 'PUT').length;
    await syncPhone(4000);
    await syncTablet(4001);
    final afterFirst = puts();
    // The second round: the phone takes what the tablet combined, and nobody uploads
    await syncPhone(4010);
    await syncTablet(4011);
    expect(puts(), afterFirst);
    expect(phone.keys.single, tablet.keys.single);
    expect(phone.keys.single.privateKey, tablet.keys.single.privateKey);
    final info = crypto.readPgpKeyInfo(unb64(phone.keys.single.privateKey));
    expect((info.userIds.length, info.subkeys.length), (2, 3));
  });
}
