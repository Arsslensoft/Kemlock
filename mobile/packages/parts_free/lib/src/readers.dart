import 'package:flutter/foundation.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

/// Text recognition in pictures, which the free build leaves out (openspec:
/// add-fdroid-release, design decision 4): ML Kit's is closed, and the free
/// engines need a native build F-Droid would have to make from source.
class NoImageTextReader implements ImageTextReader {
  const NoImageTextReader();

  @override
  Future<String> readImage(PickedFile file) async => throw const NotInThisBuild();
}

/// Text in PDFs, which the free build leaves out: pdfrx's PDFium is a
/// prebuilt library fetched while the app is built.
class NoPdfTextReader implements PdfTextReader {
  const NoPdfTextReader();

  @override
  Future<String> readPdf(Uint8List bytes) async => throw const NotInThisBuild();
}
