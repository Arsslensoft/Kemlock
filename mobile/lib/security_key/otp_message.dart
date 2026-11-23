/// A YubiKey's one-time password, read from the key over NFC
/// (openspec: add-vaultwarden-security-key). A YubiKey offers the
/// password of its first slot as a link in a standard NFC message: the
/// NDEF application of an NFC Forum Type 4 tag, whose message file holds
/// one URI record ending in the password.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../platform/security_keys.dart';
import 'apdu.dart';
import 'connection.dart';

/// The identifier of the NFC message (NDEF) application.
const ndefAid = [0xd2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01];

/// The identifier of the application's message file.
const _messageFile = [0xe1, 0x04];

/// The longest message read. A key's link is well under a hundred bytes.
const _longest = 1024;

/// How many bytes one READ BINARY asks for.
const _chunk = 0xf0;

/// The alphabet of a Yubico one-time password ("modhex").
final _modhex = RegExp(r'^[cbdefghijklnrtuv]{32,64}$');

/// Reads the one-time password the key on [connection] offers over NFC.
/// Null, "no code", when the key has no message application, the
/// application refuses a command, or its message holds no link ending in
/// a one-time password. Losing the key is the connection's own error.
///
/// ```dart
/// final code = await runOnKey(keys, readOtpMessage, viaNfc: true);
/// ```
Future<String?> readOtpMessage(SecurityKeyConnection connection) async {
  final SmartCardSession card;
  try {
    card = await connection.selectApplication(ndefAid);
  } on SecurityKeyNoApplication {
    return null;
  } on SecurityKeyNotDeclared {
    return null;
  }
  // SELECT by file identifier, first or only occurrence, no answer wanted.
  final selected = await card.transmit(ApduCommand(ins: 0xa4, p1: 0x00, p2: 0x0c, data: _messageFile));
  if (!selected.ok) return null;
  // The file starts with the message's length, in two bytes.
  final head = await card.transmit(ApduCommand(ins: 0xb0, le: 2));
  if (!head.ok || head.data.length < 2) return null;
  final length = head.data[0] << 8 | head.data[1];
  if (length == 0 || length > _longest) return null;
  final message = BytesBuilder(copy: false);
  while (message.length < length) {
    final offset = 2 + message.length;
    final want = length - message.length > _chunk ? _chunk : length - message.length;
    final part = await card.transmit(ApduCommand(ins: 0xb0, p1: offset >> 8, p2: offset & 0xff, le: want));
    if (!part.ok || part.data.isEmpty) return null;
    message.add(part.data.length > want ? Uint8List.sublistView(part.data, 0, want) : part.data);
  }
  return otpFromNdef(message.takeBytes());
}

/// The one-time password in the NDEF [message]: the last part of its first
/// record when that is a link (a well-known URI record) and the part is 32
/// to 64 characters of the one-time password's alphabet. Null otherwise.
String? otpFromNdef(Uint8List message) {
  if (message.length < 3) return null;
  final flags = message[0];
  // A chunked record is not what a key sends.
  if (flags & 0x20 != 0) return null;
  final typeLength = message[1];
  var at = 2;
  final int payloadLength;
  if (flags & 0x10 != 0) {
    payloadLength = message[at++];
  } else {
    if (message.length < at + 4) return null;
    payloadLength = message[at] << 24 | message[at + 1] << 16 | message[at + 2] << 8 | message[at + 3];
    at += 4;
  }
  var idLength = 0;
  if (flags & 0x08 != 0) {
    if (message.length <= at) return null;
    idLength = message[at++];
  }
  final payloadStart = at + typeLength + idLength;
  if (payloadLength < 2 || message.length < payloadStart + payloadLength) return null;
  // Type name format 1, "well-known", and the type "U": a URI record.
  if (flags & 0x07 != 0x01 || typeLength != 1 || message[at] != 0x55) return null;
  // The payload's first byte abbreviates the link's start; the password is at its end.
  final String link;
  try {
    link = utf8.decode(Uint8List.sublistView(message, payloadStart + 1, payloadStart + payloadLength));
  } on FormatException {
    return null;
  }
  final cut = link.lastIndexOf(RegExp('[/#?=]'));
  final tail = link.substring(cut + 1);
  return _modhex.hasMatch(tail) ? tail : null;
}
