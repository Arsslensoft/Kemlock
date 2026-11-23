import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/attachment_downloads.dart';
import 'package:kemlock/features/sync/attachment_sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/vault/attachment_store.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_attachments.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import 'fake_webdav.dart';

const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const folder = '/files/me/Kemlock/';

void main() {
  late FakeWebDav server;
  late FakeAttachmentStore store;
  late ProviderContainer container;

  setUp(() {
    server = FakeWebDav();
    store = FakeAttachmentStore();
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(KeyValueStore.memory()),
        webDavProvider.overrideWithValue(WebDav(server.client)),
        attachmentStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
  });

  /// A file on the server under its key, and its record.
  NoteAttachment upload(String id, String content) {
    final key = randomBytes(32);
    final plain = Uint8List.fromList(utf8.encode(content));
    server.blobs['$folder${syncedFileName(id)}'] = kma1EncryptSync(plain, key);
    return NoteAttachment(id: id, name: '$id.txt', size: plain.length, key: b64(key), addedAt: 1);
  }

  AttachmentDownloads downloads() => container.read(attachmentDownloadsProvider.notifier);
  Map<String, AttachmentStatus> statuses() => container.read(attachmentDownloadsProvider);

  Future<void> idle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('fetches what sync named, the smallest first, checks it opens, and stores it as it was', () async {
    final big = upload('big', 'x' * 5000);
    final small = upload('small', 'tiny');

    downloads().want('main', dav, [big, small]);
    await idle();

    final gets = [for (final request in server.requests.where((r) => r.method == 'GET')) request.url.path.split('-').last];
    expect(gets, ['small', 'big']);
    expect(statuses(), {'big': AttachmentStatus.here, 'small': AttachmentStatus.here});
    expect(store.files['main']!['big']!.sealed, server.blobs['$folder${syncedFileName('big')}']);
    expect(utf8.decode(await store.read('main', 'small', unb64(small.key))), 'tiny');
  });

  test('a file the folder lacks is missing', () async {
    final gone = NoteAttachment(id: 'gone', name: 'gone.txt', size: 1, key: b64(randomBytes(32)), addedAt: 1);

    downloads().want('main', dav, [gone]);
    await idle();

    expect(statuses()['gone'], AttachmentStatus.missing);
  });

  test('without a connection a file waits, and comes once asked for again', () async {
    final file = upload('f1', 'scan');
    server.respond = (request) async => throw http.ClientException('offline');

    downloads().want('main', dav, [file]);
    await idle();
    expect(statuses()['f1'], AttachmentStatus.waiting);
    expect(await store.exists('main', 'f1'), isFalse);

    server.respond = null;
    expect(downloads().fetchNow('f1'), isTrue);
    await idle();
    expect(statuses()['f1'], AttachmentStatus.here);
  });

  test('a download that does not open is thrown away, and fetched again', () async {
    final file = upload('f1', 'scan');
    final good = server.blobs['$folder${syncedFileName('f1')}']!;
    server.blobs['$folder${syncedFileName('f1')}'] = Uint8List.fromList([...good]..[20] ^= 1);

    downloads().want('main', dav, [file]);
    await idle();
    expect(statuses()['f1'], AttachmentStatus.waiting);
    expect(await store.exists('main', 'f1'), isFalse);

    server.blobs['$folder${syncedFileName('f1')}'] = good;
    downloads().want('main', dav, [file]);
    await idle();
    expect(statuses()['f1'], AttachmentStatus.here);
  });

  test('fetches a file opened before the others', () async {
    final a = upload('a', 'a' * 10);
    final b = upload('b', 'b' * 20);
    final c = upload('c', 'c' * 30);
    server.respond = (request) async => throw http.ClientException('offline');
    downloads().want('main', dav, [a, b, c]);
    await idle();
    server.requests.clear();
    server.respond = null;

    downloads().fetchNow('c');
    await idle();

    final gets = [for (final request in server.requests.where((r) => r.method == 'GET')) request.url.path.split('-').last];
    expect(gets.first, 'c');
    expect(downloads().fetchNow('nothing-known'), isFalse);
  });

  // openspec: add-offline-mode, "Sync is paused"
  test('while offline mode is on a file waits and nothing is asked for, even when it is opened', () async {
    final file = upload('f1', 'scan');
    container.read(offlineProvider.notifier).set(true);

    downloads().want('main', dav, [file]);
    await idle();
    expect(downloads().fetchNow('f1'), isTrue);
    await idle();

    expect(server.requests, isEmpty);
    expect(statuses()['f1'], AttachmentStatus.waiting);
    expect(await store.exists('main', 'f1'), isFalse);
  });

  test('turning offline mode off fetches the files that waited', () async {
    final file = upload('f1', 'scan');
    container.read(offlineProvider.notifier).set(true);
    downloads().want('main', dav, [file]);
    await idle();

    container.read(offlineProvider.notifier).set(false);
    await idle();

    expect(statuses()['f1'], AttachmentStatus.here);
    expect(utf8.decode(await store.read('main', 'f1', unb64(file.key))), 'scan');
  });

  test('turning offline mode on stops after the file being fetched', () async {
    final small = upload('small', 'tiny');
    final big = upload('big', 'x' * 5000);
    server.beforeNextRequest(() => container.read(offlineProvider.notifier).set(true));

    downloads().want('main', dav, [big, small]);
    await idle();

    expect(server.requests, hasLength(1));
    expect(statuses(), {'small': AttachmentStatus.here, 'big': AttachmentStatus.waiting});
  });

  testWidgets('the note page shows each file as it stands', (tester) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    final here = randomBytes(32);
    await app.attachments.write(vaultId, 'here', Uint8List.fromList(utf8.encode('x')), here);
    NoteAttachment record(String id) => NoteAttachment(id: id, name: '$id.pdf', size: 1, key: b64(here), addedAt: 1);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(SecureNote(id: 'n1', title: 'Files', addedAt: 0, attachments: [record('here'), record('coming'), record('gone')]));
    // Sync named "coming" and is fetching it
    app.container.read(attachmentDownloadsProvider.notifier).state = {'coming': AttachmentStatus.fetching};
    await tester.pump(const Duration(seconds: 10));
    await goTo(tester, app, '/vault/notes/n1');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text(t('notes.file.bytes', {'count': 1})), findsOneWidget);
    expect(find.text(t('notes.file.fetching')), findsOneWidget);
    expect(find.text(t('notes.file.notHere')), findsOneWidget);

    app.container.read(attachmentDownloadsProvider.notifier).state = {'coming': AttachmentStatus.waiting};
    await tester.pumpAndSettle();
    expect(find.text(t('notes.file.waiting')), findsOneWidget);

    // While offline mode is on, that is why it waits (openspec: add-offline-mode)
    app.container.read(offlineProvider.notifier).set(true);
    await tester.pumpAndSettle();
    expect(find.text(t('notes.file.offline')), findsOneWidget);
    expect(find.text(t('notes.file.waiting')), findsNothing);
    app.container.read(offlineProvider.notifier).set(false);
    await tester.pumpAndSettle();

    // Opening one no folder is known to have says it isn't on this phone
    await tapOn(tester, find.text('gone.pdf'));
    expect(find.text(t('notes.file.missing')), findsOneWidget);
  });
}
