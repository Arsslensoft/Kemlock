import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/crypto/attachment_core.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/attachment_seal.dart';
import 'package:kemlock/vault/attachment_sealer.dart';
import 'package:kemlock/vault/attachment_store_interface.dart' show newAttachmentId;

/// [sealAttachment] without the background isolate: the same bytes and the same entry, sealed on the spot, so a widget test's fake
/// async can finish it.
Future<SealedAttachment> sealOnTheSpot(Uint8List plain, {required String name, String? type, required int now}) async {
  if (name.isEmpty) {
    throw ArgumentError.value(name, 'name', 'a file has a name');
  }
  if (plain.length > attachmentSizeLimit) {
    throw ArgumentError.value(plain.length, 'plain', 'a file is at most $attachmentSizeLimit bytes');
  }
  final key = randomBytes(32);
  return (
    sealed: kma1EncryptSync(plain, key),
    entry: NoteAttachment(
      id: newAttachmentId(),
      name: name,
      size: plain.length,
      type: type == null || type.isEmpty ? null : type,
      key: b64(key),
      addedAt: now,
      sha256: sha256Hex(plain),
    ),
  );
}

/// Makes the app seal new files on the spot.
final Override sealsOnTheSpot = attachmentSealerProvider.overrideWithValue(sealOnTheSpot);
