/// The smartcard reader protocol a USB key speaks on its CCID interface
/// (USB CCID 1.1): the card is powered on, then each APDU rides out in an
/// `XfrBlock` message and its answer comes back in a `DataBlock`.
///
/// Only the APDU exchange levels are spoken, short and extended, which is
/// what security keys declare. A reader that wants TPDUs is not offered as
/// a link by the phone's side.
library;

import 'dart:typed_data';

import '../platform/security_keys.dart';
import 'apdu.dart' show apduLongestAnswer;

/// The message types of CCID used here.
abstract final class CcidType {
  static const iccPowerOn = 0x62;
  static const iccPowerOff = 0x63;
  static const xfrBlock = 0x6f;
  static const dataBlock = 0x80;
  static const slotStatus = 0x81;
}

/// The length of the header every CCID message starts with.
const ccidHeader = 10;

/// The longest message taken from a reader: one that carries the longest
/// answer an APDU may have, its status word, and the header.
const ccidLongestMessage = ccidHeader + apduLongestAnswer + 2;

/// The longest answer joined from a reader's chained DataBlocks.
const _longestAnswer = apduLongestAnswer + 2;

const _tooLong = SecurityKeyFailed('The key’s smartcard reader sent a longer answer than any command asks for.');

Uint8List _message(int type, int sequence, List<int> data, {int p1 = 0, int p2 = 0, int p3 = 0}) {
  final length = data.length;
  return Uint8List.fromList([
    type,
    length & 0xff,
    length >> 8 & 0xff,
    length >> 16 & 0xff,
    length >> 24 & 0xff,
    0, // the slot: a key has one
    sequence & 0xff,
    p1,
    p2,
    p3,
    ...data,
  ]);
}

/// `PC_to_RDR_IccPowerOn`, letting the reader choose the voltage.
Uint8List ccidPowerOn(int sequence) => _message(CcidType.iccPowerOn, sequence, const []);

/// `PC_to_RDR_IccPowerOff`.
Uint8List ccidPowerOff(int sequence) => _message(CcidType.iccPowerOff, sequence, const []);

/// `PC_to_RDR_XfrBlock` carrying [data]. [level] says, for an APDU longer
/// than one message, which part this is: 0 the whole, 1 the first, 2 the
/// last, 3 one in between, and `0x10` asks for the next part of an answer.
Uint8List ccidXfrBlock(int sequence, List<int> data, {int level = 0}) =>
    _message(CcidType.xfrBlock, sequence, data, p2: level & 0xff, p3: level >> 8 & 0xff);

/// A message from the reader.
class CcidMessage {
  const CcidMessage({
    required this.type,
    required this.sequence,
    required this.status,
    required this.error,
    required this.chain,
    required this.data,
  });

  final int type;
  final int sequence;

  /// `bStatus`: the card's state in its low bits, the command's in its top two.
  final int status;

  /// `bError`: why the command failed, or, in a time extension, by how much to wait longer.
  final int error;

  /// `bChainParameter` of a `DataBlock`: 0 the whole answer, 1 its first
  /// part, 2 its last, 3 one in between.
  final int chain;
  final Uint8List data;

  /// There is no card, as when a key is pulled out.
  bool get noCard => status & 0x03 == 2;

  /// The command failed; [error] says why.
  bool get failed => status >> 6 == 1;

  /// The card asks for more time.
  bool get timeExtension => status >> 6 == 2;

  /// More of the answer is to be asked for.
  bool get moreToCome => chain == 1 || chain == 3;
}

/// Puts the chunks a bulk endpoint gives back together into messages: one
/// message may come over several reads.
class CcidAssembler {
  final BytesBuilder _buffer = BytesBuilder(copy: true);

  /// Takes one [chunk] and returns the messages now whole. Throws
  /// [SecurityKeyFailed] for a message that says it is longer than
  /// [ccidLongestMessage], rather than wait for it.
  List<CcidMessage> add(Uint8List chunk) {
    _buffer.add(chunk);
    final messages = <CcidMessage>[];
    var bytes = _buffer.takeBytes();
    while (bytes.length >= ccidHeader) {
      final length = bytes[1] | bytes[2] << 8 | bytes[3] << 16 | bytes[4] << 24;
      if (ccidHeader + length > ccidLongestMessage) throw _tooLong;
      if (bytes.length < ccidHeader + length) break;
      messages.add(
        CcidMessage(
          type: bytes[0],
          sequence: bytes[6],
          status: bytes[7],
          error: bytes[8],
          chain: bytes[9],
          data: Uint8List.fromList(Uint8List.sublistView(bytes, ccidHeader, ccidHeader + length)),
        ),
      );
      bytes = Uint8List.sublistView(bytes, ccidHeader + length);
    }
    _buffer.add(bytes);
    return messages;
  }
}

/// The card behind a CCID link that writes and reads raw bulk packets.
class CcidCard {
  CcidCard({required this._write, required this._read, required this._now, this.maxMessage = 0});

  final Future<void> Function(List<Uint8List> packets) _write;
  final Future<List<Uint8List>> Function(Duration timeout) _read;
  final DateTime Function() _now;

  /// The longest message the reader takes (`dwMaxCCIDMessageLength`), or 0
  /// when it did not say: an APDU that does not fit goes in several.
  final int maxMessage;

  final CcidAssembler _assembler = CcidAssembler();
  int _sequence = 0;

  /// Powers the card on and returns its answer to reset.
  Future<Uint8List> powerOn(Duration timeout) async {
    final sequence = _next();
    await _write([ccidPowerOn(sequence)]);
    return (await _answer(sequence, timeout, timeout)).data;
  }

  /// Powers the card off. A key that is gone has nothing to power off.
  Future<void> powerOff(Duration timeout) async {
    final sequence = _next();
    try {
      await _write([ccidPowerOff(sequence)]);
      await _answer(sequence, timeout, timeout);
    } on SecurityKeyError {
      // Gone already.
    }
  }

  /// Sends one [apdu] and returns the card's raw answer. The card must
  /// answer within [silence]; each time it asks for more time the wait
  /// starts over, to [longest] at most.
  Future<Uint8List> transceive(Uint8List apdu, {required Duration silence, required Duration longest}) async {
    final room = maxMessage > ccidHeader ? maxMessage - ccidHeader : apdu.length;
    CcidMessage answer;
    if (apdu.length <= room) {
      final sequence = _next();
      await _write([ccidXfrBlock(sequence, apdu)]);
      answer = await _answer(sequence, silence, longest);
    } else {
      // An extended APDU longer than one message: first, in between, last.
      answer = CcidMessage(type: CcidType.dataBlock, sequence: 0, status: 0, error: 0, chain: 0, data: _none);
      for (var offset = 0; offset < apdu.length; offset += room) {
        final last = offset + room >= apdu.length;
        final level = offset == 0 ? 1 : (last ? 2 : 3);
        final sequence = _next();
        await _write([ccidXfrBlock(sequence, Uint8List.sublistView(apdu, offset, last ? apdu.length : offset + room), level: level)]);
        answer = await _answer(sequence, silence, longest);
      }
    }
    if (!answer.moreToCome) return answer.data;
    final whole = BytesBuilder(copy: false)..add(answer.data);
    while (answer.moreToCome) {
      final sequence = _next();
      await _write([ccidXfrBlock(sequence, const [], level: 0x10)]);
      answer = await _answer(sequence, silence, longest);
      whole.add(answer.data);
      // Each part starts a wait of its own: a reader that chains for ever is cut off here
      if (whole.length > _longestAnswer) throw _tooLong;
    }
    return whole.takeBytes();
  }

  static final Uint8List _none = Uint8List(0);

  int _next() => _sequence = (_sequence + 1) & 0xff;

  Future<CcidMessage> _answer(int sequence, Duration silence, Duration longest) async {
    final start = _now();
    var lastSign = start;
    while (true) {
      final now = _now();
      final untilSilent = lastSign.add(silence).difference(now);
      final untilLongest = start.add(longest).difference(now);
      final left = untilSilent < untilLongest ? untilSilent : untilLongest;
      if (left <= Duration.zero) throw const SecurityKeyTimeout();
      for (final chunk in await _read(left)) {
        for (final message in _assembler.add(chunk)) {
          if (message.sequence != sequence) continue;
          if (message.timeExtension) {
            lastSign = _now();
            continue;
          }
          if (message.noCard) throw const SecurityKeyRemoved();
          if (message.failed) {
            // 0xFE: the card did not answer in time.
            if (message.error == 0xfe) throw const SecurityKeyTimeout();
            throw SecurityKeyFailed('The key’s smartcard reader refused the message (${message.error.toRadixString(16)}).');
          }
          return message;
        }
      }
    }
  }
}
