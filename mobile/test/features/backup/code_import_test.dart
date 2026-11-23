import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/code_import.dart';

/// A recognised word from [left] to [right] on a line 20px high.
OcrWord word(String text, double left, double right) => OcrWord(text, left: left, top: 0, right: right, bottom: 20);

void main() {
  group('pickCodes', () {
    test('keeps code-like tokens and drops the words around them', () {
      const text = '''
Your GitHub recovery codes
Keep these somewhere safe. You have 10 codes.
1a2b3-4c5d6   7e8f9-0a1b2
abcde-12345''';
      expect(pickCodes(text), ['1a2b3-4c5d6', '7e8f9-0a1b2', 'abcde-12345']);
    });

    test('keeps Google’s "1234 5678" codes whole', () {
      expect(pickCodes('1234 5678  8765 4321\n2468 1357'), ['1234 5678', '8765 4321', '2468 1357']);
    });

    test('keeps codes in other scripts, which are letters and digits too', () {
      expect(pickCodes('Ключ: абвг-1234'), ['абвг-1234']);
    });
  });

  group('linesToText', () {
    test('puts two spaces at wide gaps, so columns of codes split apart', () {
      final lines = [
        OcrLine([word('1234', 0, 40), word('5678', 48, 88), word('8765', 140, 180), word('4321', 188, 228)]),
      ];
      expect(linesToText(lines), '1234 5678  8765 4321');
      expect(pickCodes(linesToText(lines)), ['1234 5678', '8765 4321']);
    });

    test('puts each recognised line on a line of its own, for pickCodes to read', () {
      final lines = [
        OcrLine([word('Codes:', 0, 60)]),
        OcrLine([word('9f8e7-d6c5b', 0, 110)]),
      ];
      expect(linesToText(lines), 'Codes:\n9f8e7-d6c5b');
      expect(pickCodes(linesToText(lines)), ['9f8e7-d6c5b']);
    });

    test('treats a word box less than a pixel high as one pixel high', () {
      final lines = [
        OcrLine([
          const OcrWord('a', left: 0, top: 0, right: 10, bottom: 0),
          const OcrWord('b', left: 10.8, top: 0, right: 20, bottom: 0),
          const OcrWord('c', left: 21, top: 0, right: 30, bottom: 0),
        ]),
      ];
      expect(linesToText(lines), 'a b  c');
    });
  });

  group('reading a file', () {
    test('tells pictures, PDFs and text files apart', () {
      expect(importKind(name: 'shot.png', mimeType: 'image/png'), ImportKind.image);
      expect(importKind(name: 'codes.pdf', mimeType: ''), ImportKind.pdf);
      expect(importKind(name: 'codes.txt', mimeType: ''), ImportKind.text);
      expect(importKind(name: 'vault.json', mimeType: 'application/json'), isNull);
    });

    test('goes by the name when the picker gives no type', () {
      expect(importKind(name: 'Shot.JPG'), ImportKind.image);
      expect(importKind(name: 'codes.PDF'), ImportKind.pdf);
      expect(importKind(name: 'codes.md'), ImportKind.text);
      expect(importKind(name: 'vault.json'), isNull);
      expect(importKind(name: 'shot.png', mimeType: 'application/octet-stream'), isNull);
    });

    test('reads a text file as if it were pasted', () {
      expect(codesFromText(ImportKind.text, 'aaaa-bbbb\ncccc-dddd'), ['aaaa-bbbb', 'cccc-dddd']);
      expect(codesFromText(ImportKind.text, 'Codes\nab'), ['Codes', 'ab']);
    });

    test('keeps only the codes of a PDF’s or a picture’s text', () {
      const text = 'Recovery codes for Example\n1111-2222  3333-4444\n5555-6666';
      expect(codesFromText(ImportKind.pdf, text), ['1111-2222', '3333-4444', '5555-6666']);
      expect(codesFromText(ImportKind.image, text), ['1111-2222', '3333-4444', '5555-6666']);
    });

    test('asks for another file when it is none of these', () {
      expect(const UnsupportedFileError().message, 'Choose a picture, a PDF or a text file.');
    });
  });
}
