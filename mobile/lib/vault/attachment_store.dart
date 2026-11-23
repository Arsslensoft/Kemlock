import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../crypto/attachment_format.dart';
import '../crypto/bytes.dart';
import 'attachment_store_interface.dart';

export 'attachment_store_interface.dart';

/// The attachment store, in the app's support folder. Tests override it with one in memory.
final attachmentStoreProvider = Provider<AttachmentStore>(
  (ref) => FileAttachmentStore(() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'attachments'))),
);

final _safeName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// [AttachmentStore] on the file system, under the folder [root] gives.
class FileAttachmentStore implements AttachmentStore {
  FileAttachmentStore(this._root);

  final Future<Directory> Function() _root;
  Directory? _resolved;

  Future<Directory> _base() async => _resolved ??= await _root();

  Future<Directory> _folder(String vaultId) async => Directory(p.join((await _base()).path, _checked(vaultId)));

  Future<File> _file(String vaultId, String id) async => File(p.join((await _folder(vaultId)).path, _checked(id)));

  /// Ids become file names, so only ones that can't climb out of the folder pass.
  static String _checked(String name) {
    if (!_safeName.hasMatch(name)) throw ArgumentError.value(name, 'name', 'not a vault or attachment id');
    return name;
  }

  Future<void> _place(String vaultId, String id, Future<void> Function(String temp) fill) async {
    final target = await _file(vaultId, id);
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.${b64url(randomBytes(6))}.part');
    try {
      await fill(temp.path);
      await temp.rename(target.path);
    } catch (_) {
      if (temp.existsSync()) await temp.delete();
      rethrow;
    }
  }

  @override
  Future<void> write(String vaultId, String id, Uint8List plain, Uint8List key) =>
      _place(vaultId, id, (temp) => kma1EncryptToFile(plain, key, temp));

  @override
  Future<void> writeSealed(String vaultId, String id, Uint8List sealed) =>
      _place(vaultId, id, (temp) async => File(temp).writeAsBytes(sealed, flush: true));

  @override
  Future<Uint8List> read(String vaultId, String id, Uint8List key) async {
    final sealed = await readSealed(vaultId, id);
    if (sealed == null) throw AttachmentMissingError(id);
    return kma1Decrypt(sealed, key);
  }

  @override
  Future<Uint8List?> readSealed(String vaultId, String id) async {
    final file = await _file(vaultId, id);
    return file.existsSync() ? file.readAsBytes() : null;
  }

  @override
  Future<void> decryptTo(String vaultId, String id, Uint8List key, String path) async {
    final file = await _file(vaultId, id);
    if (!file.existsSync()) throw AttachmentMissingError(id);
    await kma1DecryptFile(file.path, path, key);
  }

  @override
  Future<bool> exists(String vaultId, String id) async => (await _file(vaultId, id)).existsSync();

  @override
  Future<void> delete(String vaultId, String id) async {
    final file = await _file(vaultId, id);
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<List<StoredAttachment>> list(String vaultId) async {
    final folder = await _folder(vaultId);
    if (!folder.existsSync()) return const [];
    return [
      await for (final entry in folder.list())
        if (entry is File && _safeName.hasMatch(p.basename(entry.path)))
          (id: p.basename(entry.path), size: await entry.length(), modified: await entry.lastModified()),
    ];
  }

  @override
  Future<void> deleteVault(String vaultId) async {
    final folder = await _folder(vaultId);
    if (folder.existsSync()) await folder.delete(recursive: true);
  }

  @override
  Future<void> deleteAll() async {
    final base = await _base();
    if (base.existsSync()) await base.delete(recursive: true);
  }
}
