import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/scratch.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory cache;
  late Directory elsewhere;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('cache');
    elsewhere = Directory.systemTemp.createTempSync('documents');
  });

  tearDown(() {
    for (final directory in [cache, elsewhere]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  File put(Directory root, String path) => File('${root.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync('secret');

  group('deletePickedCopy', () {
    test('deletes the copy a picker left in the cache, and the folder made for it', () {
      // Where Android's file picker and photo picker put what was picked
      final export = put(cache, 'file_picker/1700000000000/aegis.json');
      final photo = put(cache, '0b1c2d3e-0000-4000-8000-000000000000/IMG_0001.jpg');

      deletePickedCopy(export.path, [cache]);
      deletePickedCopy(photo.path, [cache]);

      expect(export.existsSync(), isFalse);
      expect(export.parent.existsSync(), isFalse);
      expect(photo.parent.existsSync(), isFalse);
      expect(cache.existsSync(), isTrue);
    });

    test('keeps a folder that holds something else, and never deletes the cache itself', () {
      final picked = put(cache, 'file_picker/1/a.json');
      final other = put(cache, 'file_picker/1/b.json');
      // A photo the camera wrote straight into the cache
      final photo = put(cache, 'photo.jpg');

      deletePickedCopy(picked.path, [cache]);
      deletePickedCopy(photo.path, [cache]);

      expect(picked.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(photo.existsSync(), isFalse);
      expect(cache.existsSync(), isTrue);
    });

    test('leaves a file outside the cache alone: it is the person’s own', () {
      final document = put(elsewhere, 'keys/id_ed25519');

      deletePickedCopy(document.path, [cache]);
      deletePickedCopy(document.path, const []);
      // A path that climbs out of the cache names a file outside it
      deletePickedCopy('${cache.path}/../${p.basename(elsewhere.path)}/keys/id_ed25519', [cache]);

      expect(document.readAsStringSync(), 'secret');
    });

    test('does nothing for no path, and for a file that is gone', () {
      deletePickedCopy(null, [cache]);
      deletePickedCopy('', [cache]);
      deletePickedCopy('${cache.path}/gone.json', [cache]);
      deletePickedCopy('${cache.path}/a.json', [Directory('${cache.path}/no-such-root')]);

      expect(cache.listSync(), isEmpty);
    });
  });

  group('sweepScratch', () {
    Set<String> left(Directory root) => {for (final entry in root.listSync()) p.basename(entry.path)};

    test('deletes what picking, sharing and exporting left, and nothing else', () {
      // An export archive of a killed app, the share sheet's copy, the file picker's copies
      put(cache, 'export/kemlock-export-2026-11-21T10-00-00.zip');
      put(cache, 'share_plus/kemlock-recovery-kit.pdf');
      put(cache, 'file_picker/1700000000000/aegis.json');
      // The photo picker's folder, a photo the camera took, and the photo picker's file on iOS
      put(cache, '0b1c2d3e-0000-4000-8000-000000000000/IMG_0001.jpg');
      put(cache, '0b1c2d3e-0000-4000-8000-0000000000001234567890.jpg');
      put(cache, 'image_picker_3F2504E0-4F89-11D3-9A0C-0305E82C3301.jpg');
      // What other sweeps own, and what is none of the app's plain copies
      put(cache, 'share/0011223344556677/shared.txt');
      put(cache, 'pgp/8899aabbccddeeff/letter.txt');
      put(cache, 'flutter_engine/shader.bin');
      put(cache, 'notes.txt');
      put(cache, '0b1c2d3e-0000-4000-8000-000000000000-and-more/kept.txt');

      sweepScratch([cache, Directory('${cache.path}/no-such-root')]);

      expect(left(cache), {'share', 'pgp', 'flutter_engine', 'notes.txt', '0b1c2d3e-0000-4000-8000-000000000000-and-more'});
      expect(File('${cache.path}/share/0011223344556677/shared.txt').existsSync(), isTrue);
    });

    test('deletes what a credential transfer left in its cache folder', () {
      // The providerevents library's FileProvider folder (import_export_filepaths.xml): a killed import's plain copy
      put(cache, 'import_export_temp/transfer-1700000000000.json');
      put(cache, 'import_export_temp/nested/part.json');
      put(cache, 'notes.txt');

      sweepScratch([cache]);

      expect(left(cache), {'notes.txt'});
      expect(isScratchEntry(Directory('${cache.path}/import_export_temp')), isTrue);
    });

    test('leaves folders of those names deeper down alone', () {
      put(cache, 'pgp/export/kept.txt');

      sweepScratch([cache]);

      expect(File('${cache.path}/pgp/export/kept.txt').existsSync(), isTrue);
    });
  });

  test('there is no cache to sweep off a phone', () async {
    expect(await scratchRoots(), isEmpty);
    await sweepPhoneScratch();
  });
}
