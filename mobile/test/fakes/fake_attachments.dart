import 'dart:io';
import 'dart:typed_data';

import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/vault/attachment_store.dart';

/// [AttachmentStore] in memory, encrypting with the real `KMA1` format, so
/// tests see what the phone would store. [failWrites] makes writes fail as
/// a full disk would.
class FakeAttachmentStore implements AttachmentStore {
  /// Each vault's files, `KMA1` as stored, and when each was written.
  final files = <String, Map<String, ({Uint8List sealed, DateTime modified})>>{};

  bool failWrites = false;

  /// The time a write is stamped with.
  DateTime now = DateTime.utc(2026, 11, 15, 12);

  Map<String, ({Uint8List sealed, DateTime modified})> _vault(String vaultId) => files[vaultId] ??= {};

  @override
  Future<void> write(String vaultId, String id, Uint8List plain, Uint8List key) async {
    if (failWrites) throw const FileSystemException('No space left on device');
    _vault(vaultId)[id] = (sealed: kma1EncryptSync(plain, key), modified: now);
  }

  @override
  Future<void> writeSealed(String vaultId, String id, Uint8List sealed) async {
    if (failWrites) throw const FileSystemException('No space left on device');
    _vault(vaultId)[id] = (sealed: Uint8List.fromList(sealed), modified: now);
  }

  @override
  Future<Uint8List> read(String vaultId, String id, Uint8List key) async {
    final file = files[vaultId]?[id];
    if (file == null) throw AttachmentMissingError(id);
    return kma1DecryptSync(file.sealed, key);
  }

  @override
  Future<Uint8List?> readSealed(String vaultId, String id) async => files[vaultId]?[id]?.sealed;

  @override
  Future<void> decryptTo(String vaultId, String id, Uint8List key, String path) async =>
      File(path).writeAsBytesSync(await read(vaultId, id, key));

  @override
  Future<bool> exists(String vaultId, String id) async => files[vaultId]?.containsKey(id) ?? false;

  @override
  Future<void> delete(String vaultId, String id) async => files[vaultId]?.remove(id);

  @override
  Future<List<StoredAttachment>> list(String vaultId) async => [
    for (final MapEntry(key: id, value: file) in (files[vaultId] ?? const {}).entries)
      (id: id, size: file.sealed.length, modified: file.modified),
  ];

  @override
  Future<void> deleteVault(String vaultId) async => files.remove(vaultId);

  @override
  Future<void> deleteAll() async => files.clear();
}
