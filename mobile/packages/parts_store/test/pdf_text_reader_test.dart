import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/code_readers.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

/// Where a PDFium library for this machine is. Flutter's test runner has
/// none, so these tests run only when one is given, as in the container:
///
///     tool/docker/flutter.sh 'mkdir -p /tmp/pdfium && curl -sSL \
///       https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-linux-x64.tgz \
///       | tar -xz -C /tmp/pdfium && cd packages/parts_store && flutter pub get && \
///       PDFIUM_PATH=/tmp/pdfium/lib/libpdfium.so flutter test test/pdf_text_reader_test.dart'
///
/// chromium/7811 is the PDFium build pdfrx's `pdfium_dart` ships.
final pdfium = Platform.environment['PDFIUM_PATH'];

final reader = PdfrxTextReader(initialize: () => pdfrxInitialize(tmpPath: '${Directory.systemTemp.path}/pdfrx'));

/// A PDF made with the `pdf` package, one page per entry of [pages].
Future<Uint8List> makePdf(List<List<pw.Widget>> pages) async {
  final doc = pw.Document();
  for (final children in pages) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: children),
      ),
    );
  }
  return doc.save();
}

/// Two codes side by side, as a table of codes prints them.
pw.Widget columns(String left, String right) => pw.Row(
  children: [
    pw.SizedBox(width: 160, child: pw.Text(left)),
    pw.Text(right),
  ],
);

void main() {
  group('PdfrxTextReader with PDFium', skip: pdfium == null ? 'Set PDFIUM_PATH to a PDFium library to run these.' : null, () {
    test('splits codes printed in columns, which PDFium joins with one space', () async {
      final pdf = await makePdf([
        [
          pw.Text('Backup codes for GitHub'),
          columns('1234 5678', '8765 4321'),
          columns('abcde-12345', 'fghij-67890'),
          pw.Text('Keep these somewhere safe. abcde-11111 fghij-22222'),
        ],
      ]);

      final text = await reader.readPdf(pdf);

      expect(text, contains('1234 5678  8765 4321'));
      // The app's pickCodes splits the codes at the double spaces (test/features/backup/code_readers_test.dart).
      expect(text, contains('abcde-12345  fghij-67890'));
      expect(text, contains('abcde-11111 fghij-22222'));
    });

    test('reads the first 20 pages only', () async {
      final pdf = await makePdf([
        for (var page = 1; page <= 25; page++) [pw.Text('page${page.toString().padLeft(2, '0')}-code')],
      ]);

      final text = await reader.readPdf(pdf);

      expect(text.split('\n'), [for (var page = 1; page <= maxPdfPages; page++) 'page${page.toString().padLeft(2, '0')}-code']);
    });

    test('fails on a file that isn’t a PDF', () async {
      await expectLater(reader.readPdf(Uint8List.fromList('not a pdf'.codeUnits)), throwsA(anything));
    });
  });
}
