import 'dart:math';

import 'package:flutter/foundation.dart';

import 'files.dart';

/// A PDF of backup codes is a page or two; this bounds a wrong pick of a huge file.
const maxPdfPages = 20;

/// Finds the text in a picture.
abstract interface class ImageTextReader {
  /// The text recognised in [file], a line per line of text, with two spaces where words
  /// on a line are far apart (see [linesToText]).
  Future<String> readImage(PickedFile file);
}

/// Finds the text in a PDF.
abstract interface class PdfTextReader {
  /// The text of the first [maxPdfPages] pages of the PDF in [bytes], a line per line of
  /// text, with two spaces between text runs that are far apart on a line.
  Future<String> readPdf(Uint8List bytes);
}

/// What a reader throws in a build that can't read that kind of file: the free build reads
/// no pictures and no PDFs, as the libraries that do aren't free software.
class NotInThisBuild implements Exception {
  const NotInThisBuild();

  String get message => "This build can't read that kind of file.";

  @override
  String toString() => 'NotInThisBuild: $message';
}

/// A word text recognition found, and where: the edges of its box, in pixels, as ML Kit's
/// `TextElement.boundingBox` gives them.
class OcrWord {
  const OcrWord(this.text, {required this.left, required this.top, required this.right, required this.bottom});

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// A line of recognised words, left to right.
class OcrLine {
  const OcrLine(this.words);

  final List<OcrWord> words;
}

/// Rebuilds lines from recognised words, with two spaces where the gap between words
/// is wide. Codes printed in columns ("1234 5678    8765 4321") then split at the
/// columns instead of at every space.
String linesToText(List<OcrLine> lines) => [
  for (final OcrLine(:words) in lines)
    [
      for (final (i, word) in words.indexed) ...[if (i > 0) _gap(words[i - 1], word), word.text],
    ].join(),
].join('\n');

String _gap(OcrWord prev, OcrWord word) {
  final height = max(1.0, prev.bottom - prev.top);
  return word.left - prev.right > height * 0.9 ? '  ' : ' ';
}
