import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/vault/attachment_store.dart';

void main() {
  late Directory root;
  late FileAttachmentStore store;
  final key = randomBytes(32);
  final scan = Uint8List.fromList(utf8.encode('%PDF-1.7 passport scan'));

  setUp(() {
    root = Directory.systemTemp.createTempSync('attachments');
    store = FileAttachmentStore(() async => Directory('${root.path}/attachments'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> names(String folder) =>
      [for (final entry in Directory(folder).listSync()) entry.path.split(Platform.pathSeparator).last]..sort();

  test('stores a file encrypted, in its vault folder, under its id', () async {
    final id = newAttachmentId();

    await store.write('main', id, scan, key);

    final stored = File('${root.path}/attachments/main/$id').readAsBytesSync();
    expect(stored.sublist(0, 4), kma1Magic);
    expect(utf8.decode(stored, allowMalformed: true), isNot(contains('passport')));
    expect(await store.read('main', id, key), scan);
    expect(await store.readSealed('main', id), stored);
    expect(await store.exists('main', id), isTrue);
    expect(names('${root.path}/attachments/main'), [id]);
  });

  test('gives new attachments random ids that are safe as file names', () {
    final ids = {for (var i = 0; i < 50; i++) newAttachmentId()};

    expect(ids, hasLength(50));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    }
  });

  test('a failed write leaves no file, finished or not', () async {
    // A key of the wrong length makes encryption fail after the folder exists
    await expectLater(store.write('main', 'f1', scan, Uint8List(3)), throwsArgumentError);

    expect(await store.exists('main', 'f1'), isFalse);
    expect(names('${root.path}/attachments/main'), isEmpty);
  });

  test('stores a sealed file as it is, and reads it with its key', () async {
    final sealed = kma1EncryptSync(scan, key);

    await store.writeSealed('main', 'f1', sealed);

    expect(await store.readSealed('main', 'f1'), sealed);
    expect(await store.read('main', 'f1', key), scan);
  });

  test('says when a file is missing or damaged', () async {
    await expectLater(store.read('main', 'nope', key), throwsA(isA<AttachmentMissingError>()));

    await store.write('main', 'f1', scan, key);
    final file = File('${root.path}/attachments/main/f1');
    final bytes = file.readAsBytesSync();
    bytes[bytes.length - 1] ^= 1;
    file.writeAsBytesSync(bytes);
    await expectLater(store.read('main', 'f1', key), throwsA(isA<AttachmentDamagedError>()));
  });

  test('decrypts to a path, and leaves nothing there for a damaged file', () async {
    await store.write('main', 'f1', scan, key);

    await store.decryptTo('main', 'f1', key, '${root.path}/out');
    expect(File('${root.path}/out').readAsBytesSync(), scan);

    await expectLater(store.decryptTo('main', 'f1', randomBytes(32), '${root.path}/bad'), throwsA(isA<AttachmentDamagedError>()));
    expect(File('${root.path}/bad').existsSync(), isFalse);
  });

  test('lists, deletes, and keeps each vault apart', () async {
    await store.write('main', 'f1', scan, key);
    await store.write('main', 'f2', scan, key);
    await store.write('a1b2c3d4e5f6', 'f3', scan, key);

    expect([for (final file in await store.list('main')) file.id]..sort(), ['f1', 'f2']);
    expect((await store.list('main')).first.size, kma1Length(scan.length));
    expect(await store.list('nothing'), isEmpty);

    await store.delete('main', 'f1');
    await store.delete('main', 'never-there');
    expect([for (final file in await store.list('main')) file.id], ['f2']);

    await store.deleteVault('main');
    expect(Directory('${root.path}/attachments/main').existsSync(), isFalse);
    expect(await store.exists('a1b2c3d4e5f6', 'f3'), isTrue);

    await store.deleteAll();
    expect(Directory('${root.path}/attachments').existsSync(), isFalse);
    expect(await store.list('a1b2c3d4e5f6'), isEmpty);
  });

  test('refuses ids that could leave the folder', () async {
    for (final id in ['../escape', 'a/b', '', '.', 'x' * 65]) {
      await expectLater(store.write('main', id, scan, key), throwsArgumentError, reason: id);
    }
    await expectLater(store.list('../main'), throwsArgumentError);
  });
}
