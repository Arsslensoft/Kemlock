import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/files.dart';

void main() {
  group('fileNameOnly', () {
    test('leaves an ordinary name as it is', () {
      expect(fileNameOnly('report.pdf'), 'report.pdf');
      expect(fileNameOnly('kemlock-export-2026-11-21.zip'), 'kemlock-export-2026-11-21.zip');
      expect(fileNameOnly('Relevé de compte (mars).pdf'), 'Relevé de compte (mars).pdf');
      expect(fileNameOnly('.gitignore'), '.gitignore');
    });

    test('keeps nothing of a path, so a name from an import cannot leave its folder', () {
      // What a note's attached file could be called in an export someone else made
      expect(fileNameOnly('../../shared_prefs/CapacitorStorage.xml'), 'CapacitorStorage.xml');
      expect(fileNameOnly(r'..\..\files\attachments\main\a1'), 'a1');
      expect(fileNameOnly('/data/data/com.kemlock.app/files/x'), 'x');
      expect(fileNameOnly(r'C:\Users\me\x.txt'), 'x.txt');
      expect(fileNameOnly('a/b/'), 'b');
      for (final name in ['', '.', '..', '../..', '/', r'\', '../', ' ', '\u0000', './.']) {
        expect(fileNameOnly(name), 'file', reason: '"$name"');
      }
    });

    test('drops control characters', () {
      expect(fileNameOnly('a\u0000b\nc\u007f.txt'), 'abc.txt');
      expect(fileNameOnly('..\u0000'), 'file');
      expect(fileNameOnly('.\u0001.'), 'file');
    });

    test('cuts a long name from the front, keeping its extension and whole characters', () {
      final name = fileNameOnly('${'a' * 300}.pdf');
      expect(name, hasLength(120));
      expect(name, endsWith('.pdf'));
      final faces = fileNameOnly('😀' * 200);
      expect(faces.runes, hasLength(120));
      expect(faces.runes.toSet(), {'😀'.runes.single});
    });
  });
}
