// Reads backup codes out of a file on this device: a text file as it is, and the
// text a PDF holds or that text recognition finds in a screenshot or photo. This is the part
// that works on the text; the readers that get it out of PDFs (pdfrx) and pictures (ML Kit)
// run on the device too, so nothing leaves it.

import 'backup_codes.dart';

export 'package:kemlock_ports/kemlock_ports.dart' show OcrLine, OcrWord, linesToText;

/// What a file is read as.
enum ImportKind { text, pdf, image }

final _pdfName = RegExp(r'\.pdf$', caseSensitive: false);
final _textName = RegExp(r'\.(txt|csv|md)$', caseSensitive: false);
final _imageName = RegExp(r'\.(png|jpe?g|gif|webp|bmp|heic|heif)$', caseSensitive: false);

/// How to read a file, from its MIME type and else its name; null for a file the app can't
/// read codes from. A browser always knows a picture's type, but a phone's file picker may not
/// give one, so without a type a picture's name stands in for it.
ImportKind? importKind({required String name, String? mimeType}) {
  final type = mimeType ?? '';
  if (type.startsWith('image/') || (type.isEmpty && _imageName.hasMatch(name))) return ImportKind.image;
  if (type == 'application/pdf' || _pdfName.hasMatch(name)) return ImportKind.pdf;
  if (type.startsWith('text/') || _textName.hasMatch(name)) return ImportKind.text;
  return null;
}

final _separators = RegExp(r'[\s-]');
final _digit = RegExp(r'\d');
final _lettersAndDigits = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);

/// The codes in text read from a document. Unlike pasted text, a document also holds
/// headings and instructions, so only tokens that look like codes are kept: four or
/// more letters and digits, at least one of them a digit.
List<String> pickCodes(String text) => [
  for (final code in parseCodes(text))
    if (_looksLikeCode(code.replaceAll(_separators, ''))) code,
];

bool _looksLikeCode(String bare) => bare.length >= 4 && _digit.hasMatch(bare) && _lettersAndDigits.hasMatch(bare);

/// The codes in a file's text, for the user to check before they're saved: all of a text
/// file's, as if it were pasted, and only the code-like tokens of a PDF's or a picture's.
List<String> codesFromText(ImportKind kind, String text) => kind == ImportKind.text ? parseCodes(text) : pickCodes(text);

/// A file that is neither a picture, a PDF nor a text file.
class UnsupportedFileError implements Exception {
  const UnsupportedFileError();

  String get message => 'Choose a picture, a PDF or a text file.';

  @override
  String toString() => 'UnsupportedFileError: $message';
}
