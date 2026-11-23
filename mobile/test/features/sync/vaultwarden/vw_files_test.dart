// Files attached to notes, synced as attachments of the notes' Vaultwarden
// items, sealed and plain: each sent once and never replaced, deleted once
// removed here, fetched where missing and kept only once it opens, and
// left on the phone when the server takes none or keeps them elsewhere.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_attachments.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_file_sync.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_formats.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/secure_note.dart';

import '../../../fakes/fake_attachments.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

const _vault = 'main';

/// One phone, with its own attached files, syncing with the home.
class _Phone {
  _Phone(this.server, this.target) : reader = VwReader(server.userKey);

  final FakeVaultwarden server;
  final VaultwardenTarget target;
  final VwReader reader;
  final store = FakeAttachmentStore();
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);
  late VwCredentials credentials = server.credentials();

  Future<VwSyncResult> sync() async {
    final at = server.revision + 500;
    final result = await VaultwardenScopeSync(
      connection: VwConnection(
        api: VwApi(server.client),
        server: FakeVaultwarden.url,
        credentials: credentials,
        onCredentials: (next) async => credentials = next,
      ),
      reader: reader,
      target: target,
      files: VwFiles(store: store, vaultId: _vault),
    ).sync(lists, state, now: at);
    lists = applyScope(lists, null, result.doc);
    state = ScopeState(known: result.known, lastSyncAt: at, extra: result.state);
    return result;
  }

  /// Attaches [content] as a file of its own, as the note page does.
  Future<NoteAttachment> attach(String name, String content) async {
    final key = randomBytes(32);
    final bytes = Uint8List.fromList(utf8.encode(content));
    final id = b64url(randomBytes(16));
    await store.write(_vault, id, bytes, key);
    return NoteAttachment(id: id, name: name, size: bytes.length, type: 'application/pdf', key: b64(key), addedAt: 1);
  }

  Future<String> open(NoteAttachment file) async => utf8.decode(await store.read(_vault, file.id, unb64(file.key)));
}

SecureNote _note(List<NoteAttachment> files, {String text = 'In the drawer', int? updatedAt}) =>
    SecureNote(id: 'n1', title: 'Passport', text: text, attachments: files, addedAt: 1, updatedAt: updatedAt);

/// The item holding the note.
Future<Map<String, Object?>> _noteItem(FakeVaultwarden server) async {
  for (final cipher in server.ciphers.values) {
    if (cipher['deletedDate'] != null) continue;
    for (final field in (cipher['fields'] as List<Object?>? ?? const []).cast<Map<String, Object?>>()) {
      if (await bwDecryptString(field['name']! as String, server.userKey) != fieldName) continue;
      final value = await bwDecryptString(field['value']! as String, server.userKey);
      if ((sealedHeader(value) ?? plainHeader(value))?.id == 'n1') return cipher;
    }
  }
  throw StateError('No item holds the note');
}

int _calls(FakeVaultwarden server, String method, String ending) =>
    server.requests.where((request) => request.method == method && request.url.path.endsWith(ending)).length;

void main() {
  for (final mode in VaultwardenMode.values) {
    group('${mode.name}:', () {
      late FakeVaultwarden server;
      late VaultwardenTarget target;

      setUp(() async {
        server = FakeVaultwarden();
        target = await makeHome(server, mode, plainKinds: agreedToAll);
      });

      test("a note's file goes with it, and another phone opens it", () async {
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', '%PDF-1.7 the passport scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );

        await a.sync();

        final item = await _noteItem(server);
        final attachment = server.attachmentsOf(item['id']! as String).single;
        final data = await bwDecryptAttachment(server.attachmentData[attachment['id']]!, attachmentKey(file));
        final name = await bwDecryptString(attachment['fileName']! as String, server.userKey);
        if (mode == VaultwardenMode.sealed) {
          // Only ciphertext, under a name that says nothing of the file
          expect(name, file.id);
          expect(data.sublist(0, 4), kma1Magic);
          expect(data, (await a.store.readSealed(_vault, file.id))!);
          expect(kma1DecryptSync(data, unb64(file.key)), utf8.encode('%PDF-1.7 the passport scan'));
        } else {
          // What Bitwarden's apps download and open
          expect(name, 'passport.pdf');
          expect(utf8.decode(data), '%PDF-1.7 the passport scan');
        }

        final b = _Phone(server, target);
        await b.sync();
        expect(b.lists.notes.single.files.single.id, file.id);
        expect(await b.open(file), '%PDF-1.7 the passport scan');
      });

      test('a file is sent once and never replaced', () async {
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );
        await a.sync();
        await a.sync();

        // An edit of the note's text leaves its file as it is
        a.lists = Lists(
          notes: [
            _note([file], text: 'Renewed', updatedAt: server.revision + 100),
          ],
        );
        await a.sync();
        await a.sync();
        final b = _Phone(server, target);
        await b.sync();
        await b.sync();

        expect(_calls(server, 'POST', '/attachment/v2'), 1);
        expect(server.attachmentsOf((await _noteItem(server))['id']! as String), hasLength(1));
        expect(b.lists.notes.single.text, 'Renewed');
      });

      test('a file removed here is deleted there, and the other phone drops it', () async {
        final a = _Phone(server, target);
        final kept = await a.attach('kept.pdf', 'kept');
        final gone = await a.attach('gone.pdf', 'gone');
        a.lists = Lists(
          notes: [
            _note([kept, gone]),
          ],
        );
        await a.sync();
        final b = _Phone(server, target);
        await b.sync();

        a.lists = Lists(
          notes: [
            _note([kept], updatedAt: server.revision + 100),
          ],
        );
        await a.sync();
        await b.sync();

        final item = (await _noteItem(server))['id']! as String;
        expect(server.attachmentsOf(item), hasLength(1));
        expect(await bwDecryptAttachment(server.attachmentData[server.attachmentsOf(item).single['id']]!, attachmentKey(kept)), isNotEmpty);
        expect(b.lists.notes.single.files.map((file) => file.id), [kept.id]);
        expect(_calls(server, 'DELETE', ''), 1, reason: 'only the phone that removed it deletes it');
      });

      test("a phone deletes no file it didn't remove, nor one added in Bitwarden", () async {
        final a = _Phone(server, target);
        final first = await a.attach('first.pdf', 'first');
        a.lists = Lists(
          notes: [
            _note([first]),
          ],
        );
        await a.sync();
        final b = _Phone(server, target);
        await b.sync();
        final item = (await _noteItem(server))['id']! as String;
        final key = await cipherKey(VwCipher(server.ciphers[item]!), server.userKey);
        final theirs = server.putAttachment(
          item,
          fileName: await bwEncryptString('from-bitwarden.txt', key),
          key: (await bwEncrypt(BwKey.random().bytes, key)).toString(),
          data: Uint8List(80),
        );

        // A adds a second file; B, which removed nothing, syncs in between
        final second = await a.attach('second.pdf', 'second');
        a.lists = Lists(
          notes: [
            _note([first, second], updatedAt: server.revision + 100),
          ],
        );
        await a.sync();
        await b.sync();
        await a.sync();

        expect(server.attachmentsOf(item).map((attachment) => attachment['id']), contains(theirs));
        expect(server.attachmentsOf(item), hasLength(3));
        expect(_calls(server, 'DELETE', ''), 0);
        expect(await b.open(second), 'second');
      });

      test('a file the server lost is sent again by a phone that has it', () async {
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );
        await a.sync();
        final item = (await _noteItem(server))['id']! as String;

        server.removeAttachment(item, server.attachmentsOf(item).single['id']! as String);
        await a.sync();

        expect(server.attachmentsOf(item), hasLength(1));
        final b = _Phone(server, target);
        await b.sync();
        expect(await b.open(file), 'scan');
      });

      test('a phone without the file waits for one that has it', () async {
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );
        // The note arrived on another phone before its file did
        await a.store.delete(_vault, file.id);
        await a.sync();

        final item = (await _noteItem(server))['id']! as String;
        expect(server.attachmentsOf(item), isEmpty);
        expect(a.lists.notes.single.files.single.id, file.id, reason: 'the note keeps naming it');
      });

      test('the items sync without their files when the server takes none', () async {
        server.takesFiles = false;
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );

        final result = await a.sync();

        expect(result.state[vwNoFilesKey], 'none');
        expect(await a.open(file), 'scan', reason: 'the file stays on the phone');
        final b = _Phone(server, target);
        await b.sync();
        expect(b.lists.notes.single.files.single.id, file.id);
        expect(await b.store.exists(_vault, file.id), isFalse);
      });

      test('a server that keeps its files on another host is never sent nor asked for one', () async {
        server.filesHost = 'files.example.net';
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );
        await a.sync();

        final b = _Phone(server, target);
        final result = await b.sync();

        expect(result.state[vwNoFilesKey], 'elsewhere');
        expect(await b.store.exists(_vault, file.id), isFalse);
        expect(server.requests.where((request) => request.url.host != FakeVaultwarden.url.host), isEmpty);
      });

      test('an upload meant for elsewhere sends nothing, and its record goes', () async {
        server.uploadType = 1;
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );

        final result = await a.sync();

        expect(result.state[vwNoFilesKey], 'elsewhere');
        expect(server.attachmentsOf((await _noteItem(server))['id']! as String), isEmpty);
        expect(server.attachmentData, isEmpty);
        expect(server.requests.where((request) => request.url.host != FakeVaultwarden.url.host), isEmpty);
      });

      test('a damaged download is dropped, and fetched again on the next run', () async {
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan of the passport');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );
        await a.sync();
        final item = (await _noteItem(server))['id']! as String;
        final id = server.attachmentsOf(item).single['id']! as String;
        final good = server.attachmentData[id]!;
        server.attachmentData[id] = Uint8List.fromList(good)..[good.length - 1] ^= 1;

        final b = _Phone(server, target);
        final first = await b.sync();
        expect(await b.store.exists(_vault, file.id), isFalse);
        expect(first.state[vwFetchKey], isTrue);

        // Nothing else changed, yet the next run reads the vault and fetches it
        server.attachmentData[id] = good;
        await b.sync();
        expect(await b.open(file), 'scan of the passport');
        expect(b.state.extra[vwFetchKey], isNull);
      });

      test('downloads go smallest first', () async {
        final a = _Phone(server, target);
        final big = await a.attach('big.pdf', 'b' * 5000);
        final small = await a.attach('small.pdf', 's');
        final middle = await a.attach('middle.pdf', 'm' * 300);
        a.lists = Lists(
          notes: [
            _note([big, small, middle]),
          ],
        );
        await a.sync();
        final item = (await _noteItem(server))['id']! as String;
        final byAttachment = <String, String>{};
        for (final attachment in server.attachmentsOf(item)) {
          final key = BwKey.fromBytes(await bwDecrypt(EncString.parse(attachment['key']! as String), server.userKey));
          for (final file in [big, small, middle]) {
            if (sameKey(key, attachmentKey(file))) byAttachment[attachment['id']! as String] = file.name;
          }
        }
        server.requests.clear();

        await _Phone(server, target).sync();

        final fetched = [
          for (final request in server.requests)
            if (request.url.path.startsWith('/attachments/')) byAttachment[request.url.pathSegments.last],
        ];
        expect(fetched, ['small.pdf', 'middle.pdf', 'big.pdf']);
      });

      test('a deletion that failed is tried again on the next run', () async {
        final a = _Phone(server, target);
        final file = await a.attach('passport.pdf', 'scan');
        a.lists = Lists(
          notes: [
            _note([file]),
          ],
        );
        await a.sync();
        a.lists = Lists(notes: [_note(const [], updatedAt: server.revision + 100)]);
        server.respond = (request) async => request.method == 'DELETE' ? http.Response('{"message":"busy"}', 503) : server.handle(request);
        final first = await a.sync();
        expect(pendingDeletes(first.state), hasLength(1));
        server.respond = null;

        await a.sync();

        expect(server.attachmentsOf((await _noteItem(server))['id']! as String), isEmpty);
        expect(pendingDeletes(a.state.extra), isEmpty);
      });
    });
  }

  test('a sync without the files leaves attachments alone', () async {
    final server = FakeVaultwarden();
    final target = await makeHome(server, VaultwardenMode.sealed);
    final a = _Phone(server, target);
    final file = await a.attach('passport.pdf', 'scan');
    a.lists = Lists(
      notes: [
        _note([file]),
      ],
    );
    await a.sync();
    final item = (await _noteItem(server))['id']! as String;

    final result =
        await VaultwardenScopeSync(
          connection: VwConnection(
            api: VwApi(server.client),
            server: FakeVaultwarden.url,
            credentials: a.credentials,
            onCredentials: (_) async {},
          ),
          reader: VwReader(server.userKey),
          target: target,
        ).sync(
          Lists(notes: [_note(const [], updatedAt: server.revision + 100)]),
          a.state,
          now: server.revision + 500,
        );

    expect(result.state[vwFileIdsKey], isNull);
    expect(server.attachmentsOf(item), hasLength(1));
  });
}
