import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/attachment_sync.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_attachments.dart';
import '../../vault/fast_kdf.dart';
import 'fake_webdav.dart';

/// Alice's own folder; Bob has none, only the space.
const _personal = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const _shared = DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'app-pw');
const _personalFolder = '/files/me/Kemlock/';
const _sharedFolder = '/files/me/Shared/';
const _spaceId = 'fam';
final _spaceKey = b64(Uint8List.fromList(List.filled(32, 7)));

/// One member's phone: its vault's lists, its stored files, and what its
/// sync handed over to fetch, with the folder each file was to come from.
class _Member {
  _Member._(this.scheduler, this.attachments);

  final SyncScheduler scheduler;
  final FakeAttachmentStore attachments;
  Lists lists = const Lists();
  final fetched = <({DavAccount dav, List<String> ids})>[];

  Future<void> run() async {
    await scheduler.run();
    await scheduler.idle;
  }
}

Future<_Member> _member(FakeWebDav server, {bool personal = false}) async {
  final kv = KeyValueStore.memory();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(WebDav(server.client))],
  );
  addTearDown(container.dispose);
  final vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  final session = await vault.setupVault('pw');
  await vault.saveEncryptedValue(
    'backmycodes_sync',
    SyncSettings(
      personal: personal ? SyncTarget(dav: _personal, file: syncFile, key: b64(randomBytes(32))) : null,
      spaces: [
        Space(
          id: _spaceId,
          name: 'Family',
          target: SyncTarget(dav: _shared, file: spaceFile(_spaceId), key: _spaceKey),
          joinedAt: 1,
        ),
      ],
    ).toJson(),
    session,
  );
  final attachments = FakeAttachmentStore();
  late _Member member;
  final scheduler = SyncScheduler(
    store: container.read(syncProvider.notifier),
    webDav: container.read(webDavProvider),
    session: session,
    getLists: () => member.lists,
    applySynced: (lists) async => member.lists = lists,
    files: AttachmentSync(webDav: container.read(webDavProvider), store: attachments, vaultId: 'main'),
    fetchFiles: (dav, files) => member.fetched.add((dav: dav, ids: [for (final file in files) file.id])),
    startTimer: (_, _) => _NoTimer(),
    startPeriodicTimer: (_, _) => _NoTimer(),
  );
  addTearDown(scheduler.dispose);
  member = _Member._(scheduler, attachments);
  await scheduler.start();
  await scheduler.idle;
  return member;
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

VaultKey _key(String id, {String? spaceId}) => VaultKey(
  id: id,
  name: 'deploy',
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: 'cHJpdmF0ZQ',
  publicKey: 'cHVibGlj',
  origin: KeyOrigin.generated,
  spaceId: spaceId,
  addedAt: 1,
);

const _passkey = Passkey(
  id: 'pk1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  userHandle: 'dXNlcg',
  userName: 'alice@example.com',
  privateKey: 'AA==',
  addedAt: 1,
);

void main() {
  late FakeWebDav server;
  setUp(() => server = FakeWebDav());

  Future<SyncDoc> spaceDoc() async => decryptSyncFile(server.files['$_sharedFolder${spaceFile(_spaceId)}']!.text, unb64(_spaceKey));

  test("a note with a file and a key in a space reach the other member through the space's folder", () async {
    final alice = await _member(server, personal: true);
    final bob = await _member(server);
    final fileKey = randomBytes(32);
    final scan = Uint8List.fromList(utf8.encode('the lease, signed'));
    await alice.attachments.write('main', 'lease', scan, fileKey);
    alice.lists = Lists(
      notes: [
        SecureNote(
          id: 'n1',
          title: 'Flat',
          text: 'Keys with the neighbour',
          spaceId: _spaceId,
          addedAt: 1,
          attachments: [NoteAttachment(id: 'lease', name: 'lease.pdf', size: scan.length, key: b64(fileKey), addedAt: 1)],
        ),
        const SecureNote(id: 'n2', title: 'Mine alone', addedAt: 1),
      ],
      keys: [_key('k1', spaceId: _spaceId)],
      passkeys: [_passkey],
    );

    await alice.run();

    // The space's document holds what is in the space and nothing else; its file is beside it
    final shared = await spaceDoc();
    expect([for (final note in shared.notes) note.id], ['n1']);
    expect([for (final key in shared.keys) key.id], ['k1']);
    expect(shared.passkeys, isEmpty);
    expect(server.blobs['$_sharedFolder${syncedFileName('lease')}'], alice.attachments.files['main']!['lease']!.sealed);
    expect(server.blobs.containsKey('$_personalFolder${syncedFileName('lease')}'), isFalse);

    await bob.run();

    expect([for (final note in bob.lists.notes) (note.id, note.spaceId)], [('n1', _spaceId)]);
    expect(bob.lists.notes.single.files.single.key, b64(fileKey));
    expect([for (final key in bob.lists.keys) (key.id, key.spaceId)], [('k1', _spaceId)]);
    expect(bob.lists.passkeys, isEmpty);
    // Bob's phone is to fetch the file from the space's folder
    expect(bob.fetched.single.dav.url, _shared.url);
    expect(bob.fetched.single.ids, ['lease']);
  });

  test('a passkey never goes to a space, even one marked with it', () async {
    final alice = await _member(server);
    // Passkeys stay the vault's own: one carrying a space id is still not shared
    alice.lists = Lists(passkeys: [_passkey.inSpace(_spaceId)]);

    await alice.run();

    expect((await spaceDoc()).passkeys, isEmpty);
    expect(alice.lists.passkeys.single.id, 'pk1');
  });

  test('a note taken out of the space leaves its document, and stays on the phone', () async {
    final alice = await _member(server, personal: true);
    final bob = await _member(server);
    alice.lists = const Lists(
      notes: [SecureNote(id: 'n1', title: 'Flat', spaceId: _spaceId, addedAt: 1)],
    );
    await alice.run();
    await bob.run();
    expect(bob.lists.notes, hasLength(1));

    alice.lists = Lists(notes: [alice.lists.notes.single.inSpace(null).stamped(5)]);
    await alice.run();

    expect((await spaceDoc()).notes, isEmpty);
    expect(alice.lists.notes.single.spaceId, isNull);
  });
}
