import 'package:flutter/foundation.dart';

/// A file the person picked or photographed, read into memory.
@immutable
class PickedFile {
  const PickedFile({required this.name, required this.bytes, this.mimeType, this.path});

  final String name;
  final Uint8List bytes;

  /// The MIME type the picker gave, when it gave one.
  final String? mimeType;

  /// Where the picker's copy of the file is on this phone, for the one use
  /// that needs it: the QR reader reads a picture from a path. Null
  /// otherwise: the copy is deleted once the file is read into memory.
  final String? path;
}
