// Reads backup codes out of a file on this phone, as `codeImport.ts` did: a text
// file as it is, and a PDF's text and a screenshot's or photo's through this build's readers
// (`kemlock_parts`: pdfrx and ML Kit in the store build, none in the free build; openspec:
// add-fdroid-release). They run on the phone, so nothing leaves it. The readers sit behind
// providers, so tests put fakes in their place (test/fakes/fake_code_readers.dart).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart' show ImageTextReader, PdfTextReader;

import '../../core/build_kind.dart';
import '../../platform/files.dart';
import 'code_import.dart';

export 'package:kemlock_ports/kemlock_ports.dart' show ImageTextReader, NotInThisBuild, PdfTextReader, maxPdfPages;

/// Reads backup codes out of a picked file.
class CodeFileReader {
  const CodeFileReader({required this.images, required this.pdfs});

  final ImageTextReader images;
  final PdfTextReader pdfs;

  /// The codes in [file], for the user to check before they're saved: every code of a
  /// text file, and the code-like tokens of a PDF's or a picture's text. [kind] says what
  /// the file is when the picker knows better than its name, as for a photo. Throws
  /// [UnsupportedFileError] for a file that is neither a picture, a PDF nor a text file,
  /// and whatever the reader throws when it can't read the file.
  Future<List<String>> codesFromFile(PickedFile file, {ImportKind? kind}) async {
    final as = kind ?? importKind(name: file.name, mimeType: file.mimeType);
    if (as == null) throw const UnsupportedFileError();
    final text = switch (as) {
      ImportKind.text => _decode(file.bytes),
      ImportKind.pdf => await pdfs.readPdf(file.bytes),
      ImportKind.image => await images.readImage(file),
    };
    return codesFromText(as, text);
  }

  /// A text file's text, read as UTF-8 the way a browser's `File.text()` does: without
  /// the byte order mark, and with a stand-in for bytes that aren't UTF-8.
  static String _decode(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('\u{FEFF}') ? text.substring(1) : text;
  }
}

/// Whether this build reads backup codes out of screenshots and photos: the store build
/// does, through ML Kit, and the free build doesn't (openspec: add-fdroid-release, design
/// decision 4). Tests whose fake readers read them say so.
final readsPicturesProvider = Provider<bool>((ref) => canReadPictures);

/// Whether this build reads backup codes out of PDFs: the store build does, through
/// PDFium, and the free build doesn't.
final readsPdfsProvider = Provider<bool>((ref) => canReadPdfs);

/// Text recognition for pictures; tests put a fake in its place.
final imageTextReaderProvider = Provider<ImageTextReader>((ref) => parts.imageTextReader);

/// Text extraction for PDFs; tests put a fake in its place.
final pdfTextReaderProvider = Provider<PdfTextReader>((ref) => parts.pdfTextReader);

/// Reads codes out of files with the readers above.
final codeFileReaderProvider = Provider<CodeFileReader>(
  (ref) => CodeFileReader(images: ref.watch(imageTextReaderProvider), pdfs: ref.watch(pdfTextReaderProvider)),
);
