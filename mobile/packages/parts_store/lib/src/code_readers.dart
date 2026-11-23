// Reads backup codes out of pictures and PDFs, on the phone: a screenshot or photo through ML
// Kit's text recognition, a PDF's text through pdfrx (PDFium). Moved from the app's
// code_readers.dart (openspec: add-fdroid-release); the app reads them through ImageTextReader
// and PdfTextReader.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

final _random = Random.secure();

/// A random name for a file of the moment, as the app's `newUuid` made one.
String _newId() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// Reads pictures with ML Kit's Latin text recognition, on Android and iOS alike.
class MlKitImageTextReader implements ImageTextReader {
  const MlKitImageTextReader();

  @override
  Future<String> readImage(PickedFile file) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    File? copy;
    try {
      var path = file.path;
      // ML Kit reads encoded pictures only from a file.
      if (path == null) {
        final dir = await getTemporaryDirectory();
        copy = File('${dir.path}${Platform.pathSeparator}code-import-${_newId()}');
        await copy.writeAsBytes(file.bytes, flush: true);
        path = copy.path;
      }
      return linesToText(ocrLinesOf(await recognizer.processImage(InputImage.fromFilePath(path))));
    } finally {
      await recognizer.close();
      try {
        await copy?.delete();
      } on FileSystemException {
        // Already gone; the system empties the cache anyway.
      }
    }
  }
}

/// ML Kit's lines as [OcrLine]s for [linesToText]: each line's elements, which are its
/// words, with their boxes. A line without elements is one word in the line's box.
List<OcrLine> ocrLinesOf(RecognizedText text) => [
  for (final block in text.blocks)
    for (final line in block.lines)
      OcrLine([
        if (line.elements.isEmpty)
          _word(line.text, line.boundingBox)
        else
          for (final element in line.elements) _word(element.text, element.boundingBox),
      ]),
];

OcrWord _word(String text, Rect box) => OcrWord(text, left: box.left, top: box.top, right: box.right, bottom: box.bottom);

/// Reads PDFs with PDFium, through pdfrx.
class PdfrxTextReader implements PdfTextReader {
  /// [initialize] sets pdfrx up; a test that has PDFium at hand passes pdfrx's own for Dart.
  const PdfrxTextReader({this.initialize = pdfrxFlutterInitialize});

  final Future<void> Function() initialize;

  @override
  Future<String> readPdf(Uint8List bytes) async {
    await initialize();
    final document = await PdfDocument.openData(bytes, sourceName: 'code-import-${_newId()}');
    try {
      final pages = <String>[];
      for (final page in document.pages.take(maxPdfPages)) {
        final raw = await page.loadText();
        if (raw != null) pages.add(pdfPageText(raw.fullText, raw.charRects));
      }
      return pages.where((text) => text.isNotEmpty).join('\n');
    } finally {
      await document.dispose();
    }
  }
}

final _whitespace = RegExp(r'\s');

/// A PDF page's text, from PDFium's characters and their boxes, as `codeImport.ts` built
/// it from pdf.js's text runs: a line per line of the page, and two spaces between runs of
/// text that are far apart on a line, so codes printed in columns don't merge into one.
///
/// pdf.js hands over runs; PDFium hands over characters, with the line breaks and the
/// spaces between text objects it makes up itself. So the page is split into lines at
/// the breaks and into words at any space, and a gap wider than the words are tall is a
/// gap between runs, the rule [linesToText] applies to recognised words.
String pdfPageText(String text, List<PdfRect> charRects) {
  final lines = <OcrLine>[];
  var words = <OcrWord>[];
  final word = StringBuffer();
  PdfRect? box;
  var lastBreak = '';

  void endWord() {
    if (word.isEmpty) return;
    final edges = box;
    final previous = words.lastOrNull;
    // PDF coordinates grow upwards, so top and bottom swap sides; a word without a box
    // (only made-up characters) sits right after the one before it.
    words.add(
      edges != null
          ? OcrWord(word.toString(), left: edges.left, top: -edges.top, right: edges.right, bottom: -edges.bottom)
          : OcrWord(
              word.toString(),
              left: previous?.right ?? 0,
              top: previous?.top ?? 0,
              right: previous?.right ?? 0,
              bottom: previous?.bottom ?? 0,
            ),
    );
    word.clear();
    box = null;
  }

  void endLine() {
    endWord();
    lines.add(OcrLine(words));
    words = [];
  }

  var i = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final rect = i < charRects.length ? charRects[i] : null;
    i++;
    if (char == '\n' || char == '\r') {
      // "\r\n" is one break.
      if (!(char == '\n' && lastBreak == '\r')) endLine();
      lastBreak = char;
      continue;
    }
    lastBreak = '';
    if (_whitespace.hasMatch(char)) {
      endWord();
      continue;
    }
    word.write(char);
    if (rect != null && (rect.width > 0 || rect.height > 0)) box = box?.merge(rect) ?? rect;
  }
  endLine();
  while (lines.isNotEmpty && lines.last.words.isEmpty) {
    lines.removeLast();
  }
  return linesToText(lines);
}
