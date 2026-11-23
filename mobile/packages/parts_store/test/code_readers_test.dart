import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:kemlock_parts/src/code_readers.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:pdfrx/pdfrx.dart';

/// PDFium's characters for [line], one box per character, on a line whose baseline is at
/// [y] with glyphs 10pt tall: [columns] places each run of the line at its x.
({String text, List<PdfRect> rects}) pdfLine(List<(double, String)> columns, {double y = 700, double charWidth = 6}) {
  final text = StringBuffer();
  final rects = <PdfRect>[];
  for (final (i, (x, run)) in columns.indexed) {
    if (i > 0) {
      // The space PDFium makes up between two text objects: a point, not a box.
      text.write(' ');
      rects.add(PdfRect(x, y, x, y));
    }
    for (final (j, char) in run.split('').indexed) {
      text.write(char);
      final left = x + j * charWidth;
      rects.add(char == ' ' ? PdfRect(left, y + 10, left + charWidth, y) : PdfRect(left + 0.5, y + 10, left + charWidth - 0.5, y));
    }
  }
  return (text: text.toString(), rects: rects);
}

/// Lines joined by PDFium's "\r\n", whose characters have no box.
({String text, List<PdfRect> rects}) pdfPage(List<({String text, List<PdfRect> rects})> lines) {
  final text = StringBuffer();
  final rects = <PdfRect>[];
  for (final (i, line) in lines.indexed) {
    if (i > 0) {
      text.write('\r\n');
      rects.addAll(const [PdfRect.empty, PdfRect.empty]);
    }
    text.write(line.text);
    rects.addAll(line.rects);
  }
  return (text: text.toString(), rects: rects);
}

TextElement element(String text, Rect box) => TextElement(
  text: text,
  symbols: const [],
  boundingBox: box,
  recognizedLanguages: const [],
  cornerPoints: const [],
  confidence: null,
  angle: null,
);

TextLine textLine(List<TextElement> elements, {String? text, Rect box = Rect.zero}) => TextLine(
  text: text ?? elements.map((e) => e.text).join(' '),
  elements: elements,
  boundingBox: box,
  recognizedLanguages: const [],
  cornerPoints: const [],
  confidence: null,
  angle: null,
);

TextBlock block(List<TextLine> lines) => TextBlock(
  text: lines.map((l) => l.text).join('\n'),
  lines: lines,
  boundingBox: Rect.zero,
  recognizedLanguages: const [],
  cornerPoints: const [],
);

void main() {
  group('pdfPageText', () {
    test('joins runs far apart with two spaces, so columns of codes split apart', () {
      final page = pdfPage([
        pdfLine([(72, 'Backup codes for GitHub')]),
        pdfLine([(72, '1234 5678'), (300, '8765 4321')]),
        pdfLine([(72, '2468 1357'), (300, '9753 8642')]),
      ]);

      final text = pdfPageText(page.text, page.rects);

      expect(text, 'Backup codes for GitHub\n1234 5678  8765 4321\n2468 1357  9753 8642');
    });

    test('keeps one space between runs that sit close together', () {
      final page = pdfLine([(72, 'abcde-12345'), (72 + 12 * 6, 'fghij-67890')]);
      expect(pdfPageText(page.text, page.rects), 'abcde-12345 fghij-67890');
    });

    test('reads a lone "\\n" as a break too, and drops trailing empty lines', () {
      final first = pdfLine([(72, 'abcd-1234')]);
      final second = pdfLine([(72, 'efgh-5678')], y: 680);
      final text = '${first.text}\n${second.text}\r\n\r\n';
      final rects = [...first.rects, PdfRect.empty, ...second.rects, for (var i = 0; i < 4; i++) PdfRect.empty];

      expect(pdfPageText(text, rects), 'abcd-1234\nefgh-5678');
    });

    test('keeps a word whose characters have no box', () {
      final text = 'abcd-1234 ****';
      final rects = [
        ...pdfLine([(72, 'abcd-1234')]).rects,
        PdfRect.empty,
        for (var i = 0; i < 4; i++) PdfRect.empty,
      ];

      expect(pdfPageText(text, rects), 'abcd-1234 ****');
    });

    test('reads an empty page as no text', () {
      expect(pdfPageText('', const []), '');
    });
  });

  group('ocrLinesOf', () {
    test('turns ML Kit’s elements and their boxes into words for linesToText', () {
      final text = RecognizedText(
        text: '',
        blocks: [
          block([
            textLine([element('Codes:', const Rect.fromLTRB(0, 0, 60, 20))]),
          ]),
          block([
            textLine([
              element('1234', const Rect.fromLTRB(0, 40, 40, 60)),
              element('5678', const Rect.fromLTRB(48, 40, 88, 60)),
              element('8765', const Rect.fromLTRB(140, 40, 180, 60)),
              element('4321', const Rect.fromLTRB(188, 40, 228, 60)),
            ]),
          ]),
        ],
      );

      final lines = ocrLinesOf(text);

      expect(
        [for (final line in lines) line.words.map((w) => w.text).toList()],
        [
          ['Codes:'],
          ['1234', '5678', '8765', '4321'],
        ],
      );
      final word = lines[1].words[2];
      expect((word.left, word.top, word.right, word.bottom), (140, 40, 180, 60));
      expect(linesToText(lines), 'Codes:\n1234 5678  8765 4321');
    });

    test('reads a line without elements as one word', () {
      final text = RecognizedText(
        text: '',
        blocks: [
          block([textLine(const [], text: 'abcde-12345', box: const Rect.fromLTRB(0, 0, 110, 20))]),
        ],
      );
      expect(linesToText(ocrLinesOf(text)), 'abcde-12345');
    });
  });
}
