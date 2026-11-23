/// What a shared item is, from its content and never from a file's name
/// (openspec: add-share-extension, decision 7): an encrypted PGP message,
/// a signed one, a detached signature, or anything else.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../crypto/keys/pgp.dart' as pgp;
import '../../platform/shared_items.dart';

enum SharedKind {
  /// Opened for decrypting.
  encrypted,

  /// A signed message, clear-signed or not: opened for verifying.
  signed,

  /// Signature packets alone: opened for verifying, with the file they
  /// sign still to choose.
  detachedSignature,

  /// Offered for encrypting or signing.
  other,
}

/// How much of a shared file is read to tell what it is.
const sharedHeadLength = 64 * 1024;

/// What [head] is, the start of a shared item: a text's bytes, or the
/// first [sharedHeadLength] bytes of a file. An armor block is recognised
/// with text before it, as a pasted mail has, and binary data by its first
/// packet. A text that only mentions an armor header, and what cannot be
/// read as PGP data at all, is [SharedKind.other].
///
/// The work is [pgp.inspectMessage]'s, the Decrypt sheet's own look at a
/// message. On binary data it also checks that a first packet said to be a
/// signature reads as one: a PNG file's first byte is the header of a
/// signature packet, and a photo is no signed message.
SharedKind sharedKind(Uint8List head) {
  if (head.isEmpty) return SharedKind.other;
  final pgp.PgpMessageInfo info;
  try {
    info = pgp.inspectMessage(pgp.PgpData.bytes(head));
  } on Object {
    // Whatever is not PGP data is offered as anything else is
    return SharedKind.other;
  }
  final kind = switch (info.kind) {
    pgp.PgpMessageKind.encrypted => SharedKind.encrypted,
    pgp.PgpMessageKind.signed || pgp.PgpMessageKind.cleartextSigned => SharedKind.signed,
    pgp.PgpMessageKind.detachedSignature => SharedKind.detachedSignature,
    pgp.PgpMessageKind.plain || pgp.PgpMessageKind.publicKey || pgp.PgpMessageKind.secretKey => SharedKind.other,
  };
  if (kind == SharedKind.other || kind == SharedKind.encrypted || _armored(head)) return kind;
  return _startsLikeASignature(head) ? kind : SharedKind.other;
}

/// [sharedKind] of [item]: a text whole, a file by its first bytes. A file
/// that cannot be read is [SharedKind.other], for the sheet to say so.
SharedKind sharedKindOf(SharedItem item) => switch (item) {
  SharedText(:final text) => sharedKind(Uint8List.fromList(utf8.encode(text))),
  SharedFile(:final path) => sharedKind(_head(path)),
};

Uint8List _head(String path) {
  try {
    final file = File(path).openSync();
    try {
      return file.readSync(sharedHeadLength);
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return Uint8List(0);
  }
}

final _beginLine = RegExp(r'^-----BEGIN PGP [A-Z0-9 ,/]+-----', multiLine: true);
final _controlCharacter = RegExp(r'[\x00-\x08\x0e-\x1f]');

/// Whether [head] is text holding an armor block, read as the OpenPGP code
/// reads it: a BEGIN line with nothing but text before it.
bool _armored(Uint8List head) {
  final text = latin1.decode(head.length > sharedHeadLength ? Uint8List.sublistView(head, 0, sharedHeadLength) : head);
  final match = _beginLine.firstMatch(text);
  return match != null && !text.substring(0, match.start).contains(_controlCharacter);
}

/// Whether the first packet of binary [data], read as a signature or a
/// one-pass signature, has a version and a signature type such packets
/// have: of binary data or of text (RFC 9580, sections 5.2 and 5.4).
bool _startsLikeASignature(Uint8List data) {
  final ctb = data[0];
  final int tag;
  final int bodyAt;
  if (ctb & 0x40 == 0) {
    tag = (ctb >> 2) & 0x0f;
    bodyAt =
        1 +
        switch (ctb & 3) {
          0 => 1,
          1 => 2,
          2 => 4,
          _ => 0,
        };
  } else {
    tag = ctb & 0x3f;
    if (data.length < 2) return false;
    final first = data[1];
    bodyAt =
        1 +
        (first < 192
            ? 1
            : first < 224
            ? 2
            : first == 255
            ? 5
            : 1);
  }
  if (data.length < bodyAt + 3) return false;
  final version = data[bodyAt];
  final next = data[bodyAt + 1];
  bool ofDataOrText(int type) => type == 0x00 || type == 0x01;
  return switch (tag) {
    // A signature packet: version 3 has a length of 5 before its type
    2 => version == 3 ? next == 5 && ofDataOrText(data[bodyAt + 2]) : (version >= 4 && version <= 6) && ofDataOrText(next),
    // A one-pass signature packet leads a signed message
    4 => (version == 3 || version == 6) && ofDataOrText(next),
    // A compressed packet, which inspectMessage looked inside
    _ => true,
  };
}
