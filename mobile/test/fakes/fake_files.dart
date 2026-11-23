import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/files.dart';

/// Stands in for the system's pickers, save dialog and share sheet.
///
/// ```dart
/// final files = FakeFiles()..nextPick = FakeFiles.text('aegis.json', json);
/// await pumpScreen(tester, const MyScreen(), overrides: [files.asOverride]);
/// // … tap Import …
/// expect(files.saved.single.name, 'kemlock-export.json');
/// ```
class FakeFiles implements FileService {
  /// What the next pickFile, pickImage or takePhoto returns; null as if the person cancelled.
  PickedFile? nextPick;

  /// What the next pickFilePath returns; null as if the person cancelled.
  PickedPath? nextPath;

  /// Every text handed to the share sheet, in order.
  final List<String> sharedTexts = [];

  /// What the next save returns; a save to `Downloads/<name>` when null.
  SaveResult? nextSave;

  /// Every file saved or shared, in order.
  final List<({String name, Uint8List bytes, String mimeType, bool shared})> saved = [];

  /// The names of files saved or shared from a path rather than from bytes.
  final List<String> fromPath = [];

  /// The extensions each pickFile call asked for, and which picker was opened.
  final List<String> opened = [];

  /// A picked text file.
  static PickedFile text(String name, String content, {String? mimeType}) =>
      PickedFile(name: name, bytes: Uint8List.fromList(utf8.encode(content)), mimeType: mimeType, path: '/picked/$name');

  /// A file the picker left on disk: [bytes] written as [name] in a new
  /// directory under the system's temporary one, as a phone's picker
  /// leaves a copy in the app's cache. The caller deletes it, or the code
  /// under test does.
  static PickedPath onDisk(String name, List<int> bytes) {
    final directory = Directory.systemTemp.createTempSync('picked');
    final file = File('${directory.path}${Platform.pathSeparator}$name')..writeAsBytesSync(bytes);
    return PickedPath(name: name, size: bytes.length, path: file.path);
  }

  /// A picked picture; its bytes don't matter to the fakes that read it.
  static PickedFile image(String name) => PickedFile(name: name, bytes: Uint8List(4), mimeType: 'image/png', path: '/picked/$name');

  Override get asOverride => fileServiceProvider.overrideWithValue(this);

  /// The text of the last file saved or shared.
  String get lastSavedText => utf8.decode(saved.last.bytes);

  /// The paths of the picker's copies the code under test asked to delete, in order.
  final List<String?> forgotten = [];

  /// The next pick, without its path unless [keepFile]: as on a phone, the
  /// picker's copy is gone once the file is read into memory.
  PickedFile? _takePick({bool keepFile = false}) {
    final pick = nextPick;
    nextPick = null;
    if (pick == null || keepFile) return pick;
    return PickedFile(name: pick.name, bytes: pick.bytes, mimeType: pick.mimeType);
  }

  @override
  Future<PickedFile?> pickFile({List<String>? extensions}) async {
    opened.add('file ${extensions?.join(',') ?? '*'}');
    return _takePick();
  }

  @override
  Future<void> forget(PickedFile file) async => forgotten.add(file.path);

  @override
  Future<PickedPath?> pickFilePath() async {
    opened.add('path');
    final pick = nextPath;
    nextPath = null;
    return pick;
  }

  @override
  Future<void> shareText(String text) async => sharedTexts.add(text);

  @override
  Future<PickedFile?> pickImage({bool keepFile = false}) async {
    opened.add('photos');
    return _takePick(keepFile: keepFile);
  }

  @override
  Future<PickedFile?> takePhoto() async {
    opened.add('camera');
    return _takePick();
  }

  @override
  Future<SaveResult> saveFile(String fileName, Uint8List bytes, {String mimeType = 'application/json'}) async {
    final result = nextSave ?? Saved('Downloads/$fileName');
    nextSave = null;
    if (result is! SaveCancelled) saved.add((name: fileName, bytes: bytes, mimeType: mimeType, shared: false));
    return result;
  }

  @override
  Future<void> shareFile(String fileName, Uint8List bytes, {String mimeType = 'application/octet-stream'}) async {
    saved.add((name: fileName, bytes: bytes, mimeType: mimeType, shared: true));
  }

  @override
  Future<SaveResult> saveFileFrom(String path, String fileName, {String mimeType = 'application/octet-stream'}) async {
    final result = await saveFile(fileName, File(path).readAsBytesSync(), mimeType: mimeType);
    if (result is! SaveCancelled) fromPath.add(fileName);
    return result;
  }

  @override
  Future<void> shareFileFrom(String path, String fileName, {String mimeType = 'application/octet-stream'}) async {
    await shareFile(fileName, File(path).readAsBytesSync(), mimeType: mimeType);
    fromPath.add(fileName);
  }
}
