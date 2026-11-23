import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' hide PickedFile;
import 'package:kemlock_ports/kemlock_ports.dart' show PickedFile;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../crypto/bytes.dart';
import '../features/settings/auto_lock.dart';
import 'scratch.dart';

export 'package:kemlock_ports/kemlock_ports.dart' show PickedFile;

/// A file the person picked, left where the picker put it and not read:
/// for files that may be too large to hold, such as one to encrypt.
@immutable
class PickedPath {
  const PickedPath({required this.name, required this.size, required this.path});

  final String name;

  /// In bytes.
  final int size;

  /// Where it is on this phone. Android and iOS pickers give a copy in the
  /// app's cache, which is the caller's to delete when it is done with it.
  final String path;
}

/// Where a saved file ended up.
sealed class SaveResult {
  const SaveResult();
}

/// Saved where the person chose; [location] is the name to show them.
class Saved extends SaveResult {
  const Saved(this.location);

  final String location;
}

/// Handed to the share sheet, which has Save to Files.
class Shared extends SaveResult {
  const Shared();
}

/// The person closed the save dialog or share sheet without saving.
class SaveCancelled extends SaveResult {
  const SaveCancelled();
}

/// [name] as one file name with nothing of a path left in it: the part after
/// the last slash or backslash, without control characters, never `.` or
/// `..`, and cut to its last 120 characters, which keeps its extension.
///
/// A name can come from outside: a note's attached file keeps the name its
/// export or its shared space gave it. Used as it is to build a path, a name
/// such as `../../shared_prefs/…` would write over the app's own files.
String fileNameOnly(String name) {
  final parts = name
      .split(RegExp(r'[/\\]'))
      .map((part) => part.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim())
      .where((part) => part.isNotEmpty && part != '.' && part != '..');
  final runes = (parts.lastOrNull ?? '').runes.toList();
  if (runes.isEmpty) return 'file';
  return String.fromCharCodes(runes.length > 120 ? runes.sublist(runes.length - 120) : runes);
}

/// Picking, photographing, saving and sharing files, as the file inputs,
/// `fileDownload.ts` and `@capacitor/share` did. Every one of them hides the
/// app behind a system screen, so each holds auto-lock while it is open.
abstract interface class FileService {
  /// Lets the person pick one file of the given extensions (any file when
  /// null); null when they cancelled. The file comes read into memory and
  /// without a path: the copy the picker left in the cache is deleted.
  Future<PickedFile?> pickFile({List<String>? extensions});

  /// Lets the person pick one file of any kind without reading it; null
  /// when they cancelled.
  Future<PickedPath?> pickFilePath();

  /// Lets the person pick a picture from their photos; null when they
  /// cancelled. The picker's copy in the cache is deleted once read, so the
  /// picture has no path, unless [keepFile]: then it has one, for a reader
  /// that takes a path, and the caller calls [forget] when done with it.
  Future<PickedFile?> pickImage({bool keepFile = false});

  /// Takes a photo with the camera; null when the person cancelled. The
  /// photo comes read into memory, and its file in the cache is deleted.
  Future<PickedFile?> takePhoto();

  /// Deletes the copy a picker left in the cache for [file], picked with
  /// `keepFile`. A file without a path, or elsewhere, is left alone.
  Future<void> forget(PickedFile file);

  /// Saves [bytes] as [fileName]: through the system's save dialog on
  /// Android, and the share sheet, which has Save to Files, on iOS.
  Future<SaveResult> saveFile(String fileName, Uint8List bytes, {String mimeType = 'application/json'});

  /// Opens the share sheet with [bytes] as a file named [fileName].
  Future<void> shareFile(String fileName, Uint8List bytes, {String mimeType = 'application/octet-stream'});

  /// Opens the share sheet with [text] as plain text, such as an armored
  /// message for a mail app.
  Future<void> shareText(String text);

  /// Saves the file at [path] as [fileName], as [saveFile] does, for files
  /// built on disk, such as an export archive.
  Future<SaveResult> saveFileFrom(String path, String fileName, {String mimeType = 'application/octet-stream'});

  /// Opens the share sheet with the file at [path] as [fileName].
  Future<void> shareFileFrom(String path, String fileName, {String mimeType = 'application/octet-stream'});
}

/// [FileService] on the phone: `file_picker`, `image_picker` and `share_plus`.
class PlatformFileService implements FileService {
  PlatformFileService(this._holds);

  final AutoLockHolds _holds;

  @override
  Future<PickedFile?> pickFile({List<String>? extensions}) => _holds.withHeld(() async {
    final files = await FilePicker.pickFiles(type: extensions == null ? FileType.any : FileType.custom, allowedExtensions: extensions);
    final file = files.firstOrNull;
    if (file == null) return null;
    try {
      return PickedFile(name: file.name, bytes: await file.xFile.readAsBytes(), mimeType: file.xFile.mimeType);
    } finally {
      // Read or not, the picker's plain copy doesn't stay in the cache
      deletePickedCopy(file.path, await scratchRoots());
    }
  });

  @override
  Future<PickedPath?> pickFilePath() => _holds.withHeld(() async {
    final file = (await FilePicker.pickFiles()).firstOrNull;
    final path = file?.path;
    if (file == null || path == null) return null;
    return PickedPath(name: file.name, size: await file.length() ?? await File(path).length(), path: path);
  });

  @override
  Future<void> shareText(String text) => _holds.withHeld(() => SharePlus.instance.share(ShareParams(text: text)));

  @override
  Future<PickedFile?> pickImage({bool keepFile = false}) => _image(ImageSource.gallery, keepFile: keepFile);

  @override
  Future<PickedFile?> takePhoto() => _image(ImageSource.camera);

  @override
  Future<void> forget(PickedFile file) async => deletePickedCopy(file.path, await scratchRoots());

  Future<PickedFile?> _image(ImageSource source, {bool keepFile = false}) => _holds.withHeld(() async {
    final image = await ImagePicker().pickImage(source: source);
    if (image == null) return null;
    var kept = false;
    try {
      final bytes = await image.readAsBytes();
      kept = keepFile;
      return PickedFile(name: image.name, bytes: bytes, mimeType: image.mimeType, path: keepFile ? image.path : null);
    } finally {
      // A picture that was not asked to stay, or that could not be read, leaves no plain copy
      if (!kept) deletePickedCopy(image.path, await scratchRoots());
    }
  });

  @override
  Future<SaveResult> saveFile(String fileName, Uint8List bytes, {String mimeType = 'application/json'}) => _holds.withHeld(() async {
    if (Platform.isAndroid) {
      final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType);
      return uri == null ? const SaveCancelled() : Saved(_displayName(uri, fileName));
    }
    final result = await _share(fileName, bytes, mimeType);
    return result.status == ShareResultStatus.dismissed ? const SaveCancelled() : const Shared();
  });

  @override
  Future<void> shareFile(String fileName, Uint8List bytes, {String mimeType = 'application/octet-stream'}) =>
      _holds.withHeld(() => _share(fileName, bytes, mimeType));

  @override
  Future<SaveResult> saveFileFrom(String path, String fileName, {String mimeType = 'application/octet-stream'}) =>
      _holds.withHeld(() async {
        if (Platform.isAndroid) {
          // The system's save dialog takes the content itself
          final uri = await FilePicker.saveFile(fileName: fileName, bytes: await File(path).readAsBytes(), mimeType: mimeType);
          return uri == null ? const SaveCancelled() : Saved(_displayName(uri, fileName));
        }
        final result = await _sharePath(path, fileName, mimeType);
        return result.status == ShareResultStatus.dismissed ? const SaveCancelled() : const Shared();
      });

  @override
  Future<void> shareFileFrom(String path, String fileName, {String mimeType = 'application/octet-stream'}) =>
      _holds.withHeld(() => _sharePath(path, fileName, mimeType));

  /// The share sheet names a file by its path, so one of another name is
  /// copied to the cache under [fileName] first, and that copy deleted after.
  Future<ShareResult> _sharePath(String path, String fileName, String mimeType) async {
    final name = fileNameOnly(fileName);
    if (path.split(Platform.pathSeparator).last == name) return _open(File(path), name, mimeType);
    final folder = await _shareFolder();
    try {
      return await _open(await File(path).copy('${folder.path}${Platform.pathSeparator}$name'), name, mimeType);
    } finally {
      await _remove(folder);
    }
  }

  /// The file goes through the cache rather than memory, so the share sheet
  /// gets a real file name; it is deleted again once the sheet closes.
  Future<ShareResult> _share(String fileName, Uint8List bytes, String mimeType) async {
    final name = fileNameOnly(fileName);
    final folder = await _shareFolder();
    try {
      final file = File('${folder.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return await _open(file, name, mimeType);
    } finally {
      await _remove(folder);
    }
  }

  Future<ShareResult> _open(File file, String name, String mimeType) => SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: mimeType)],
      title: name,
    ),
  );

  /// A new folder of a random name for one file on its way to the share
  /// sheet, so two files of one name don't meet and nothing is written over.
  Future<Directory> _shareFolder() async {
    final name = [for (final b in randomBytes(8)) b.toRadixString(16).padLeft(2, '0')].join();
    final root = (await getTemporaryDirectory()).path;
    return Directory('$root${Platform.pathSeparator}share${Platform.pathSeparator}$name').create(recursive: true);
  }

  Future<void> _remove(Directory folder) async {
    try {
      await folder.delete(recursive: true);
    } catch (_) {
      // The cache is the system's to clear.
    }
  }

  /// The chosen file's name as the person sees it, from a content URI's last part.
  static String _displayName(Uri uri, String fallback) {
    final last = Uri.decodeComponent(uri.pathSegments.lastOrNull ?? '');
    final name = last.split(RegExp('[:/]')).last;
    return name.isEmpty ? fallback : name;
  }
}

final fileServiceProvider = Provider<FileService>((ref) => PlatformFileService(ref.watch(autoLockHoldsProvider)));
