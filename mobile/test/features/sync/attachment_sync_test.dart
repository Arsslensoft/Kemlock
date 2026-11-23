import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_attachments.dart';
import '../../vault/fast_kdf.dart';
import 'fake_webdav.dart';

const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const folder = '/files/me/Kemlock/';
const docPath = '$folder$syncFile';
String blobPath(String id) => '$folder${syncedFileName(id)}';

/// One phone whose vault syncs with the fake folder, files and all.
class _Phone {
  _Phone._(this.container, this.scheduler, this.attachments, this.key);

  final ProviderContainer container;
  final SyncScheduler scheduler;
  final FakeAttachmentStore attachments;
  final String key;
  Lists lists = const Lists();
  final fetched = <List<String>>[];

  SyncSnapshot get snapshot => container.read(syncProvider);

  Future<void> run() async {
    await scheduler.run();
    await scheduler.idle;
  }

  /// Attaches [content] as [id] to a note, as the note page does.
  Future<NoteAttachment> attach(String id, String content) async {
    final key = randomBytes(32);
    final bytes = Uint8List.fromList(utf8.encode(content));
    await attachments.write('main', id, bytes, key);
    return NoteAttachment(id: id, name: '$id.txt', size: bytes.length, key: b64(key), addedAt: 1);
  }
}

Future<_Phone> _phone(FakeWebDav server, {String? key}) async {
  final kv = KeyValueStore.memory();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(WebDav(server.client))],
  );
  addTearDown(container.dispose);
  final vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  final session = await vault.setupVault('pw');
  final syncKey = key ?? b64(randomBytes(32));
  await vault.saveEncryptedValue(
    'backmycodes_sync',
    SyncSettings(
      personal: SyncTarget(dav: dav, file: syncFile, key: syncKey),
    ).toJson(),
    session,
  );
  final attachments = FakeAttachmentStore();
  late _Phone phone;
  final scheduler = SyncScheduler(
    store: container.read(syncProvider.notifier),
    webDav: container.read(webDavProvider),
    session: session,
    getLists: () => phone.lists,
    applySynced: (lists) async => phone.lists = lists,
    files: AttachmentSync(webDav: container.read(webDavProvider), store: attachments, vaultId: 'main'),
    fetchFiles: (_, files) => phone.fetched.add([for (final file in files) file.id]),
    startTimer: (_, _) => _NoTimer(),
    startPeriodicTimer: (_, _) => _NoTimer(),
  );
  addTearDown(scheduler.dispose);
  phone = _Phone._(container, scheduler, attachments, syncKey);
  await scheduler.start();
  await scheduler.idle;
  return phone;
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

void main() {
  late FakeWebDav server;
  setUp(() => server = FakeWebDav());

  Future<SyncDoc> remote(_Phone phone) async => decryptSyncFile(server.files[docPath]!.text, unb64(phone.key));

  test('uploads an attached file before the document that names it, as it is stored', () async {
    final phone = await _phone(server);
    final file = await phone.attach('f1', 'passport scan');
    phone.lists = Lists(
      notes: [
        SecureNote(id: 'n1', title: 'Passport', addedAt: 1, attachments: [file]),
      ],
    );

    await phone.run();

    expect(server.blobs[blobPath('f1')], phone.attachments.files['main']!['f1']!.sealed);
    expect((await remote(phone)).notes.single.files.single.id, 'f1');
    final puts = [for (final request in server.requests.where((r) => r.method == 'PUT')) request.url.path];
    expect(puts.indexOf(blobPath('f1')), lessThan(puts.lastIndexOf(docPath)));
    // The server holds ciphertext under a name that says nothing of the file
    expect(utf8.decode(server.blobs[blobPath('f1')]!, allowMalformed: true), isNot(contains('passport')));
  });

  test('holds the document back when an upload fails, and tries again next run', () async {
    final phone = await _phone(server);
    final file = await phone.attach('f1', 'scan');
    phone.lists = Lists(
      notes: [
        SecureNote(id: 'n1', title: 'Passport', addedAt: 1, attachments: [file]),
      ],
    );
    server.respond = (request) async =>
        request.method == 'PUT' && request.url.path == blobPath('f1') ? http.Response('', 507) : server.handle(request);

    await phone.run();

    // The document written at unlock, before the note, is all the server has
    expect((await remote(phone)).notes, isEmpty);
    expect(server.blobs, isEmpty);
    expect(phone.snapshot.status[personalScope]?.problem, SyncProblem.server);
    expect(phone.lists.notes.single.files.single.id, 'f1');

    server.respond = null;
    await phone.run();
    expect(server.blobs.keys, [blobPath('f1')]);
    expect((await remote(phone)).notes, hasLength(1));
  });

  test('sends a file again when the server lost it', () async {
    final phone = await _phone(server);
    final file = await phone.attach('f1', 'scan');
    phone.lists = Lists(
      notes: [
        SecureNote(id: 'n1', title: 'Passport', addedAt: 1, attachments: [file]),
      ],
    );
    await phone.run();

    server.blobs.clear();
    await phone.run();

    expect(server.blobs[blobPath('f1')], phone.attachments.files['main']!['f1']!.sealed);
  });

  test('deletes the files of attachments this phone removed, and only those', () async {
    final phone = await _phone(server);
    final kept = await phone.attach('kept', 'kept');
    final gone = await phone.attach('gone', 'gone');
    phone.lists = Lists(
      notes: [
        SecureNote(id: 'n1', title: 'Passport', addedAt: 1, attachments: [kept, gone]),
      ],
    );
    await phone.run();
    // Another phone uploaded a file its document doesn't name yet
    server.blobs[blobPath('theirs')] = Uint8List.fromList([1, 2, 3]);

    phone.lists = Lists(
      notes: [
        phone.lists.notes.single.copyWith(attachments: [kept], updatedAt: 99),
      ],
    );
    await phone.run();

    expect(server.blobs.keys.toSet(), {blobPath('kept'), blobPath('theirs')});
    expect([for (final file in (await remote(phone)).notes.single.files) file.id], ['kept']);
  });

  test('deletes the files of a note this phone deleted', () async {
    final phone = await _phone(server);
    final file = await phone.attach('f1', 'scan');
    phone.lists = Lists(
      notes: [
        SecureNote(id: 'n1', title: 'Passport', addedAt: 1, attachments: [file]),
      ],
    );
    await phone.run();

    phone.lists = const Lists();
    await phone.run();

    expect(server.blobs, isEmpty);
    expect((await remote(phone)).notes, isEmpty);
  });

  test("hands over the files another phone's notes name that this one lacks", () async {
    final first = await _phone(server);
    final file = await first.attach('f1', 'scan');
    first.lists = Lists(
      notes: [
        SecureNote(id: 'n1', title: 'Passport', addedAt: 1, attachments: [file]),
      ],
    );
    await first.run();

    final second = await _phone(server, key: first.key);
    await second.run();

    expect(second.lists.notes.single.files.single.id, 'f1');
    // At unlock and again on this run: the downloads take each file once
    expect(second.fetched, isNotEmpty);
    expect(second.fetched.every((ids) => ids.length == 1 && ids.single == 'f1'), isTrue);
    // It never uploads or deletes what it doesn't have
    expect(server.blobs.keys, [blobPath('f1')]);
  });

  test('lists nothing and uploads nothing for a vault without files', () async {
    final phone = await _phone(server);
    phone.lists = const Lists(
      notes: [SecureNote(id: 'n1', title: 'Wi-Fi', addedAt: 1)],
    );

    await phone.run();

    expect(server.requests.where((r) => r.method == 'PROPFIND'), isEmpty);
    expect(server.blobs, isEmpty);
  });

  test('keeps the ids it removed in the scope state until their deletion goes through', () {
    final state = {
      fileIdsKey: ['a', 'b'],
      removedFilesKey: ['c'],
      'other': 1,
    };
    final local = Lists(
      notes: [
        SecureNote(
          id: 'n',
          title: 't',
          addedAt: 1,
          attachments: [NoteAttachment(id: 'a', name: 'a', size: 1, key: 'k', addedAt: 1)],
        ),
      ],
    );

    expect(removedFiles(state, local), {'b', 'c'});
  });
}
