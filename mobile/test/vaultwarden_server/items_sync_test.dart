// Keys, notes with files and passkeys through a real Vaultwarden (see
// server_kit.dart), sealed and plain, from two phones through the real
// engine: a note with an attached file, an SSH key and a passkey go up from
// one phone and come down on the other, the file opens there, and a file
// removed on the second phone leaves the server.
//
// With WRITE_VAULTWARDEN_ITEM_FIXTURES=1, each run also writes
// test/fixtures/vaultwarden/server-items-<mode>.json: the items as the
// server gave them back, with the throwaway account's user key and the
// home's seal key, so tests can open what a real server kept without one.
// Write them once, against the version docs/plans/vaultwarden.md names.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as keys;
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_file_sync.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_items.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_store.dart' show deriveVaultKey;

import '../fakes/fake_attachments.dart';
import 'server_kit.dart';

const _vault = 'main';

/// A phone with its own files, syncing with [target].
class _Phone {
  _Phone(this.client, this.credentials, this.target);

  final http.Client client;
  VwCredentials credentials;
  final VaultwardenTarget target;
  final store = FakeAttachmentStore();
  late final reader = VwReader(credentials.key);
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);

  Future<VwSyncResult> sync() async {
    final connection = VwConnection(
      api: VwApi(client),
      server: serverUrl!,
      credentials: credentials,
      onCredentials: (next) async => credentials = next,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = await VaultwardenScopeSync(
      connection: connection,
      reader: reader,
      target: target,
      files: VwFiles(store: store, vaultId: _vault),
    ).sync(lists, state, now: now);
    lists = applyScope(lists, null, result.doc);
    state = ScopeState(known: result.known, lastSyncAt: now, extra: result.state);
    return result;
  }
}

Future<(VwAccountSetup, VwCredentials)> _signIn(http.Client client, TestAccount account) async {
  final setup = VwAccountSetup(VwApi(client));
  await setup.connect(serverUrl.toString(), account.email);
  final done = await setup.signIn(account.password, deviceId: testDevice().id) as VwSignInDone;
  return (setup, done.credentials);
}

void main() {
  late http.Client client;
  setUp(() => client = serverClient());
  tearDown(() => client.close());

  for (final mode in VaultwardenMode.values) {
    test(
      '${mode.name}: a note with a file, an SSH key and a passkey between two phones',
      () async {
        final account = await registerAccount(client, kdf: cheapArgon2id);
        final (setup, credentials) = await _signIn(client, account);
        final passphrase = mode == VaultwardenMode.sealed ? 'a long sealing phrase' : null;
        var target = await setup.createHome(setup.connection(credentials), mode: mode, passphrase: passphrase, derive: deriveVaultKey);
        if (mode == VaultwardenMode.plain) target = target.copyWith(plainKinds: {'key', 'note', 'passkey'});

        final ssh = await keys.makeKey(const keys.NewKeyRequest(keys.KeyKind.ssh, keys.GeneratedAlgorithm.ed25519));
        final key = VaultKey(
          id: 'k1',
          name: 'laptop',
          kind: KeyKind.ssh,
          algorithm: ssh.algorithm,
          privateKey: b64(ssh.private),
          publicKey: b64(ssh.public!),
          origin: KeyOrigin.generated,
          addedAt: 1,
        );
        final p256 = await keys.makeKey(const keys.NewKeyRequest(keys.KeyKind.signing, keys.GeneratedAlgorithm.ecdsaP256));
        final passkey = Passkey(
          id: 'p1',
          credentialId: b64url(randomBytes(16)),
          rpId: 'webauthn.io',
          rpName: 'WebAuthn.io',
          userHandle: b64url(randomBytes(16)),
          userName: 'kemlock-test',
          privateKey: b64(p256.private),
          addedAt: DateTime.now().millisecondsSinceEpoch,
        );
        final a = _Phone(client, credentials, target);
        final fileKey = randomBytes(32);
        final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 a scan of the passport'));
        await a.store.write(_vault, 'f1', pdf, fileKey);
        final file = NoteAttachment(
          id: 'f1',
          name: 'passport.pdf',
          size: pdf.length,
          type: 'application/pdf',
          key: b64(fileKey),
          addedAt: 1,
        );
        final note = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', attachments: [file], addedAt: 1);
        a.lists = Lists(keys: [key], notes: [note], passkeys: [passkey]);

        final first = await a.sync();
        expect(first.state[vwNoFilesKey], isNull, reason: 'the server keeps the file');

        // The second phone joins the home with the passphrase
        final (setup2, credentials2) = await _signIn(client, account);
        final info = await setup2.readVault(setup2.connection(credentials2));
        expect(info.homes.single.entries, 3);
        final joined = await setup2.joinHome(info.homes.single, passphrase: passphrase, derive: deriveVaultKey);
        final b = _Phone(client, credentials2, mode == VaultwardenMode.plain ? joined.copyWith(plainKinds: target.plainKinds) : joined);
        await b.sync();

        expect(b.lists.keys.single.privateKey, key.privateKey);
        expect(b.lists.passkeys.single.credentialId, passkey.credentialId);
        expect(b.lists.notes.single.files.single.id, 'f1');
        expect(await b.store.read(_vault, 'f1', fileKey), pdf);

        // What the server kept, as Bitwarden's apps get it
        final ciphers = await VwConnection(
          api: VwApi(client),
          server: serverUrl!,
          credentials: credentials,
          onCredentials: (_) async {},
        ).ciphers();
        final read = await VwReader(credentials.key)
            .read(ciphers, home: target.home, sealKey: target.seal == null ? null : unb64(target.seal!.key));
        final types = {for (final claim in read.entries) claim.id: claim.cipher.type};
        if (mode == VaultwardenMode.plain) {
          final config = await VwApi(client).config(serverUrl!);
          expect(types, {
            'k1': keepsSshKeyItems(config) ? CipherType.sshKey : CipherType.secureNote,
            'n1': CipherType.secureNote,
            'p1': CipherType.login,
          });
        } else {
          expect(types.values.toSet(), {CipherType.secureNote});
        }

        // The second phone removes the file; it leaves the server
        b.lists = Lists(
          keys: b.lists.keys,
          notes: [b.lists.notes.single.copyWith(attachments: const <NoteAttachment>[], updatedAt: DateTime.now().millisecondsSinceEpoch)],
          passkeys: b.lists.passkeys,
        );
        await b.sync();
        await a.sync();
        expect(a.lists.notes.single.files, isEmpty);
        final after = await VwConnection(
          api: VwApi(client),
          server: serverUrl!,
          credentials: credentials,
          onCredentials: (_) async {},
        ).ciphers();
        final noteItem = after.firstWhere((cipher) => cipher.id == read.entries.firstWhere((claim) => claim.id == 'n1').cipher.id);
        expect(noteItem.json['attachments'], anyOf(isNull, isEmpty));

        if (Platform.environment['WRITE_VAULTWARDEN_ITEM_FIXTURES'] == '1') {
          final config = await VwApi(client).config(serverUrl!);
          await File('test/fixtures/vaultwarden/server-items-${mode.name}.json').writeAsString(
            '${const JsonEncoder.withIndent('  ').convert({
              'about': 'Ciphers a real Vaultwarden kept for keys, notes with a file and passkeys, written by test/vaultwarden_server/items_sync_test.dart. Never regenerate.',
              'server': config['version'],
              'userKey': b64(credentials.key.bytes),
              'sealKey': target.seal?.key,
              'home': target.home,
              'fileKey': b64(fileKey),
              'ciphers': [for (final cipher in ciphers) cipher.json],
            })}\n',
          );
        }
      },
      skip: skipServer,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
