import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/features/backup/code_readers.dart';
import 'package:kemlock/platform/files.dart';

/// Stands in for ML Kit's text recognition: answers every picture with
/// [text], or fails with [error], and keeps the pictures it was given.
///
/// ```dart
/// final images = FakeImageTextReader('1234 5678  8765 4321');
/// await pumpScreen(tester, screen, overrides: [images.asOverride]);
/// expect(images.read.single.name, 'codes.png');
/// ```
class FakeImageTextReader implements ImageTextReader {
  FakeImageTextReader([this.text = '']);

  String text;

  /// Thrown instead of answering, like a picture ML Kit can't read.
  Object? error;

  /// Holds the answer back until it completes, to see the screen while it reads.
  Future<void>? wait;

  final List<PickedFile> read = [];

  Override get asOverride => imageTextReaderProvider.overrideWithValue(this);

  @override
  Future<String> readImage(PickedFile file) async {
    read.add(file);
    await wait;
    final failure = error;
    if (failure != null) throw failure;
    return text;
  }
}

/// Stands in for PDFium: answers every PDF with [text], or fails with
/// [error], and keeps the bytes it was given.
class FakePdfTextReader implements PdfTextReader {
  FakePdfTextReader([this.text = '']);

  String text;

  /// Thrown instead of answering, like a damaged or password-protected PDF.
  Object? error;

  final List<Uint8List> read = [];

  Override get asOverride => pdfTextReaderProvider.overrideWithValue(this);

  @override
  Future<String> readPdf(Uint8List bytes) async {
    read.add(bytes);
    final failure = error;
    if (failure != null) throw failure;
    return text;
  }
}

/// Both readers, for a screen that reads codes out of files, in a build that reads
/// pictures and PDFs as the store build does, whichever build the tests run on.
class FakeCodeReaders {
  final images = FakeImageTextReader();
  final pdfs = FakePdfTextReader();

  List<Override> get overrides => [
    images.asOverride,
    pdfs.asOverride,
    readsPicturesProvider.overrideWithValue(true),
    readsPdfsProvider.overrideWithValue(true),
  ];
}
