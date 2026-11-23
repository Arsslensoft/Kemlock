import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/code_import.dart';
import 'package:kemlock/features/backup/code_readers.dart';
import 'package:kemlock/platform/files.dart';

import '../../fakes/fake_code_readers.dart';
import '../../fakes/fake_files.dart';

PickedFile file(String name, String content, {String? mimeType}) =>
    PickedFile(name: name, bytes: Uint8List.fromList(utf8.encode(content)), mimeType: mimeType);

void main() {
  group('codesFromFile', () {
    late FakeImageTextReader images;
    late FakePdfTextReader pdfs;
    late CodeFileReader reader;

    setUp(() {
      images = FakeImageTextReader();
      pdfs = FakePdfTextReader();
      reader = CodeFileReader(images: images, pdfs: pdfs);
    });

    test('reads every code of a text file, as if pasted', () async {
      expect(await reader.codesFromFile(file('codes.txt', 'abc\n1234 5678\nefgh-ijkl')), ['abc', '1234 5678', 'efgh-ijkl']);
      expect(images.read, isEmpty);
      expect(pdfs.read, isEmpty);
    });

    test('drops a text file’s byte order mark, as a browser does', () async {
      expect(await reader.codesFromFile(file('codes.txt', '\u{FEFF}abcd-1234\nefgh-5678')), ['abcd-1234', 'efgh-5678']);
    });

    test('keeps only the code-like tokens of a PDF', () async {
      pdfs.text = 'Your GitHub recovery codes\n1a2b3-4c5d6  7e8f9-0a1b2';
      final pdf = file('github-recovery-codes.pdf', '%PDF-1.7', mimeType: 'application/pdf');

      expect(await reader.codesFromFile(pdf), ['1a2b3-4c5d6', '7e8f9-0a1b2']);
      expect(pdfs.read.single, pdf.bytes);
    });

    test('keeps only the code-like tokens of a picture', () async {
      images.text = 'Backup codes\n1234 5678  8765 4321';
      final picture = FakeFiles.image('IMG_0001.png');

      expect(await reader.codesFromFile(picture), ['1234 5678', '8765 4321']);
      expect(images.read.single, same(picture));
    });

    test('reads a photo as a picture, whatever its name says', () async {
      images.text = 'abcd-1234';
      final photo = PickedFile(name: 'photo', bytes: Uint8List(4));

      expect(await reader.codesFromFile(photo, kind: ImportKind.image), ['abcd-1234']);
    });

    test('refuses a file that is neither a picture, a PDF nor a text file', () async {
      await expectLater(reader.codesFromFile(file('vault.json', '{}', mimeType: 'application/json')), throwsA(isA<UnsupportedFileError>()));
    });

    test('passes on what a reader throws', () async {
      pdfs.error = Exception('damaged');
      await expectLater(reader.codesFromFile(file('codes.pdf', '')), throwsA(isA<Exception>()));
    });
  });
}
