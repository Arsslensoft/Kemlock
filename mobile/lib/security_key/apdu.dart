/// Smartcard commands and answers (ISO 7816-4 APDUs): their short and
/// extended encodings, SELECT by name, an answer fetched in parts with GET
/// RESPONSE, and a long command sent in chained parts.
library;

import 'dart:typed_data';

import '../platform/security_keys.dart';

/// The most a short APDU carries as data, and asks for back.
const apduShortData = 255;
const apduShortLe = 256;

/// The most an extended APDU carries as data, and asks for back.
const apduExtendedData = 65535;
const apduExtendedLe = 65536;

/// The longest answer joined from the parts a card hands out: what an
/// extended APDU asks for, and room to spare. A card that goes on past it
/// is not followed: nothing a security key holds comes near it.
const apduLongestAnswer = apduExtendedLe + 4096;

/// The status word of a command that went well.
const swOk = 0x9000;

/// SELECT's status word for an application the card does not have.
const swFileNotFound = 0x6a82;

/// A command for a card: the four header bytes, the [data] it carries and
/// [le], how many bytes of answer it asks for (null for none).
class ApduCommand {
  ApduCommand({this.cla = 0, required this.ins, this.p1 = 0, this.p2 = 0, List<int>? data, this.le})
    : data = data == null ? Uint8List(0) : Uint8List.fromList(data) {
    if (this.data.length > apduExtendedData) throw ArgumentError.value(this.data.length, 'data', 'too long for an APDU');
    if (le != null && (le! < 1 || le! > apduExtendedLe)) throw ArgumentError.value(le, 'le', 'not a length an APDU can ask for');
  }

  final int cla;
  final int ins;
  final int p1;
  final int p2;
  final Uint8List data;
  final int? le;

  /// Whether the short encoding can hold it.
  bool get fitsShort => data.length <= apduShortData && (le == null || le! <= apduShortLe);

  /// The short encoding: one byte for each length, 0 standing for 256 bytes
  /// asked back.
  Uint8List encodeShort() {
    if (!fitsShort) throw StateError('The command does not fit a short APDU.');
    return Uint8List.fromList([
      cla,
      ins,
      p1,
      p2,
      if (data.isNotEmpty) ...[data.length, ...data],
      if (le != null) le! & 0xff,
    ]);
  }

  /// The extended encoding: a zero byte, then two bytes for each length, 0
  /// standing for 65,536 bytes asked back. A command with no data and no
  /// answer has no lengths, so it is the same four bytes.
  Uint8List encodeExtended() => Uint8List.fromList([
    cla,
    ins,
    p1,
    p2,
    if (data.isNotEmpty || le != null) 0,
    if (data.isNotEmpty) ...[data.length >> 8, data.length & 0xff, ...data],
    if (le != null) ...[le! >> 8 & 0xff, le! & 0xff],
  ]);

  /// The command as short parts of at most [partSize] bytes of data, each
  /// but the last with the chaining bit (`0x10`) in its class byte. Only
  /// the last asks for an answer, and for 256 bytes at most.
  List<ApduCommand> chained({int partSize = apduShortData}) {
    final lastLe = le == null ? null : (le! > apduShortLe ? apduShortLe : le);
    if (data.length <= partSize) return [ApduCommand(cla: cla, ins: ins, p1: p1, p2: p2, data: data, le: lastLe)];
    return [
      for (var offset = 0; offset < data.length; offset += partSize)
        if (offset + partSize < data.length)
          ApduCommand(cla: cla | 0x10, ins: ins, p1: p1, p2: p2, data: Uint8List.sublistView(data, offset, offset + partSize))
        else
          ApduCommand(cla: cla, ins: ins, p1: p1, p2: p2, data: Uint8List.sublistView(data, offset), le: lastLe),
    ];
  }
}

/// A card's answer: its [data] and the status word [sw].
class ApduResponse {
  ApduResponse(List<int> data, this.sw) : data = Uint8List.fromList(data);

  /// The answer in [raw] bytes as they came: the data, then the two status bytes.
  factory ApduResponse.parse(List<int> raw) {
    if (raw.length < 2) throw const SecurityKeyFailed('The key sent an answer too short to be one.');
    return ApduResponse(raw.sublist(0, raw.length - 2), raw[raw.length - 2] << 8 | raw[raw.length - 1]);
  }

  final Uint8List data;
  final int sw;

  int get sw1 => sw >> 8;
  int get sw2 => sw & 0xff;

  /// Whether the card says the command went well.
  bool get ok => sw == swOk;

  @override
  String toString() => 'ApduResponse(${data.length} bytes, ${sw.toRadixString(16).padLeft(4, '0')})';
}

/// SELECT by name of the application [aid], asking for what it says of itself.
ApduCommand selectByName(List<int> aid) => ApduCommand(ins: 0xa4, p1: 0x04, data: aid, le: apduShortLe);

/// The instruction of ISO 7816's GET RESPONSE.
const insGetResponse = 0xc0;

/// GET RESPONSE for the next [length] bytes of an answer (256 when the
/// card says 0).
ApduCommand getResponse(int length) => ApduCommand(ins: insGetResponse, le: length == 0 ? apduShortLe : length);

/// Carries one encoded APDU to the card and returns its raw answer.
typedef ApduTransport = Future<Uint8List> Function(Uint8List apdu);

/// Sends [command] over [send] and returns the whole answer with its
/// status word, whatever that is: a status other than `9000` is returned,
/// not thrown.
///
/// A command the short encoding cannot hold goes as one extended APDU
/// where the link takes them ([extendedLength]) and in chained parts
/// where it does not. An answer the card hands out in parts (`61xx`) is
/// fetched with GET RESPONSE and joined; a card that names the length it
/// wants asked for (`6Cxx`) is asked again with it. An application that
/// hands out the rest of an answer under an instruction of its own, as
/// Yubico's OATH application does with `A5`, names it in [remainingIns].
/// An answer joined past [apduLongestAnswer] throws [SecurityKeyFailed].
Future<ApduResponse> transmitApdu(
  ApduTransport send,
  ApduCommand command, {
  required bool extendedLength,
  int remainingIns = insGetResponse,
}) async {
  ApduResponse response;
  if (command.fitsShort) {
    response = ApduResponse.parse(await send(command.encodeShort()));
  } else if (extendedLength) {
    response = ApduResponse.parse(await send(command.encodeExtended()));
  } else {
    final parts = command.chained();
    response = ApduResponse(const [], swOk);
    for (final part in parts) {
      response = ApduResponse.parse(await send(part.encodeShort()));
      // A card that refuses a part will not take the rest.
      if (!response.ok && response.sw1 != 0x61) return response;
    }
  }
  if (response.sw1 == 0x6c && command.fitsShort) {
    final again = ApduCommand(
      cla: command.cla,
      ins: command.ins,
      p1: command.p1,
      p2: command.p2,
      data: command.data,
      le: getResponse(response.sw2).le,
    );
    response = ApduResponse.parse(await send(again.encodeShort()));
  }
  if (response.sw1 != 0x61) return response;
  final data = BytesBuilder(copy: false)..add(response.data);
  while (response.sw1 == 0x61) {
    final more = remainingIns == insGetResponse ? getResponse(response.sw2) : ApduCommand(ins: remainingIns, le: apduShortLe);
    response = ApduResponse.parse(await send(more.encodeShort()));
    data.add(response.data);
    // A card that says more is to come for ever would be read for ever
    if (data.length > apduLongestAnswer) throw const SecurityKeyFailed('The key sent a longer answer than any command asks for.');
  }
  return ApduResponse(data.takeBytes(), response.sw);
}

/// Opens the application [aid] and returns what it says of itself. Throws
/// [SecurityKeyNoApplication] when the card has none with that name, and
/// [SecurityKeyFailed] for any other refusal.
Future<Uint8List> selectApplication(ApduTransport send, List<int> aid, {required bool extendedLength}) async =>
    (await selectApplicationAnswer(send, aid, extendedLength: extendedLength)).data;

/// [selectApplication], giving the whole answer. A status in
/// [alsoSelected] counts as opened too: a card in its termination state
/// answers `6285` and still takes the command that activates it again
/// (openspec: add-openpgp-card).
Future<ApduResponse> selectApplicationAnswer(
  ApduTransport send,
  List<int> aid, {
  required bool extendedLength,
  Set<int> alsoSelected = const {},
}) async {
  final response = await transmitApdu(send, selectByName(aid), extendedLength: extendedLength);
  if (response.ok || alsoSelected.contains(response.sw)) return response;
  if (response.sw == swFileNotFound) throw const SecurityKeyNoApplication();
  throw SecurityKeyFailed('The key refused to open the application (${response.sw.toRadixString(16).padLeft(4, '0')}).');
}
