import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/ccid.dart';

import 'hex.dart';

/// A CCID interface whose bulk reads come from a script, on a clock that a silent read moves on.
class _Reader {
  final List<String> written = [];
  final Queue<List<String>> reads = Queue();
  DateTime clock = DateTime.utc(2026, 11, 16);
  Duration perRead = Duration.zero;

  Future<void> write(List<Uint8List> packets) async => written.addAll(packets.map(hex));

  Future<List<Uint8List>> read(Duration timeout) async {
    if (reads.isEmpty) {
      clock = clock.add(timeout);
      return const [];
    }
    clock = clock.add(perRead);
    return reads.removeFirst().map(unhex).toList();
  }

  CcidCard card({int maxMessage = 0}) => CcidCard(write: write, read: read, now: () => clock, maxMessage: maxMessage);
}

const _silence = Duration(seconds: 5);
const _longest = Duration(seconds: 60);

void main() {
  test('writes the three messages by hand', () {
    expect(hex(ccidPowerOn(1)), '62000000000001000000');
    expect(hex(ccidPowerOff(2)), '63000000000002000000');
    expect(hex(ccidXfrBlock(3, unhex('00a40400'))), '6f04000000000300000000a40400');
    expect(hex(ccidXfrBlock(4, Uint8List(300), level: 1)).substring(0, 20), '6f2c0100000004000100');
    expect(hex(ccidXfrBlock(5, const [], level: 0x10)), '6f000000000005001000');
  });

  test('powers the card on, then carries an APDU out and its answer back', () async {
    final reader = _Reader()
      ..reads.add(['80 05000000 00 01 00 00 00 3b80800101'])
      ..reads.add(['80 08000000 00 02 00 00 00 5532465f5632 9000']);
    final card = reader.card();

    expect(hex(await card.powerOn(_silence)), '3b80800101');
    final answer = await card.transceive(unhex('00a4040008a0000006472f000100'), silence: _silence, longest: _longest);

    expect(hex(answer), '5532465f56329000');
    expect(reader.written, [
      '62000000000001000000',
      '6f0e00000000020000'
          '00'
          '00a4040008a0000006472f000100',
    ]);
  });

  test('gathers an answer split over several bulk reads', () async {
    final reader = _Reader()
      ..reads.add(['80 0600'])
      ..reads.add(['0000 00 01 00 00 00 0102'])
      ..reads.add(['0304'])
      ..reads.add(['9000']);

    expect(hex(await reader.card().transceive(unhex('00b00000'), silence: _silence, longest: _longest)), '010203049000');
  });

  test('ignores an answer to an earlier message', () async {
    final reader = _Reader()..reads.add(['80 02000000 00 07 00 00 00 6a82', '80 02000000 00 01 00 00 00 9000']);

    expect(hex(await reader.card().transceive(unhex('00b00000'), silence: _silence, longest: _longest)), '9000');
  });

  test('keeps waiting when the card asks for more time', () async {
    final reader = _Reader()..perRead = const Duration(seconds: 4);
    for (var i = 0; i < 3; i++) {
      reader.reads.add(['80 00000000 00 01 80 01 00']);
    }
    reader.reads.add(['80 02000000 00 01 00 00 00 9000']);
    final start = reader.clock;

    expect(hex(await reader.card().transceive(unhex('00200000'), silence: _silence, longest: _longest)), '9000');
    expect(reader.clock.difference(start), const Duration(seconds: 16), reason: 'well past the 5 seconds a silent card gets');
  });

  test('gives up on a card that asks for more time for ever', () async {
    final reader = _Reader()..perRead = const Duration(seconds: 4);
    for (var i = 0; i < 50; i++) {
      reader.reads.add(['80 00000000 00 01 80 01 00']);
    }
    final start = reader.clock;

    await expectLater(
      reader.card().transceive(unhex('00200000'), silence: _silence, longest: _longest),
      throwsA(isA<SecurityKeyTimeout>()),
    );
    expect(reader.clock.difference(start), _longest);
  });

  test('gives up on a silent card after the time limit', () async {
    final reader = _Reader();
    final start = reader.clock;

    await expectLater(
      reader.card().transceive(unhex('00200000'), silence: _silence, longest: _longest),
      throwsA(isA<SecurityKeyTimeout>()),
    );
    expect(reader.clock.difference(start), _silence);
  });

  test('reads a "no card" status as the removed error', () async {
    final reader = _Reader()..reads.add(['80 00000000 00 01 42 fe 00']);

    await expectLater(
      reader.card().transceive(unhex('00200000'), silence: _silence, longest: _longest),
      throwsA(isA<SecurityKeyRemoved>()),
    );
  });

  test('reads a mute card as a time-out and any other failure as a failure', () async {
    final mute = _Reader()..reads.add(['80 00000000 00 01 40 fe 00']);
    await expectLater(mute.card().transceive(unhex('00200000'), silence: _silence, longest: _longest), throwsA(isA<SecurityKeyTimeout>()));

    final refused = _Reader()..reads.add(['80 00000000 00 01 40 07 00']);
    await expectLater(
      refused.card().transceive(unhex('00200000'), silence: _silence, longest: _longest),
      throwsA(isA<SecurityKeyFailed>()),
    );
  });

  test('sends an APDU longer than one message in parts, and asks for the rest of a long answer', () async {
    final reader = _Reader()
      ..reads.add(['80 00000000 00 01 00 00 00'])
      ..reads.add(['80 00000000 00 02 00 00 00'])
      ..reads.add(['80 02000000 00 03 00 00 01 aabb'])
      ..reads.add(['80 02000000 00 04 00 00 02 9000']);
    final apdu = Uint8List.fromList(List.generate(50, (i) => i));

    final answer = await reader.card(maxMessage: 30).transceive(apdu, silence: _silence, longest: _longest);

    expect(hex(answer), 'aabb9000');
    expect(reader.written, [
      '6f140000000001000100${hex(apdu.sublist(0, 20))}',
      '6f140000000002000300${hex(apdu.sublist(20, 40))}',
      '6f0a0000000003000200${hex(apdu.sublist(40))}',
      '6f000000000004001000',
    ]);
  });

  test('stops following a reader that chains its answer past the longest an APDU has', () async {
    var sequence = 0;
    var messages = 0;
    // Each DataBlock carries 256 bytes and says more is to come, whatever it was asked
    final card = CcidCard(
      write: (packets) async {
        sequence = packets.last[6];
      },
      read: (timeout) async {
        messages++;
        return [
          Uint8List.fromList([0x80, 0x00, 0x01, 0x00, 0x00, 0x00, sequence, 0x00, 0x00, messages == 1 ? 1 : 3, ...List.filled(256, 0x66)]),
        ];
      },
      now: () => DateTime.utc(2026, 11, 16),
    );

    await expectLater(card.transceive(unhex('00ca004f00'), silence: _silence, longest: _longest), throwsA(isA<SecurityKeyFailed>()));
    expect(messages * 256, inInclusiveRange(ccidLongestMessage - ccidHeader, ccidLongestMessage + 512));
  });

  test('refuses a message that says it is longer than any answer, without waiting for it', () async {
    final reader = _Reader()..reads.add(['80 ffffffff 00 01 00 00 00 9000']);
    final start = reader.clock;

    await expectLater(reader.card().transceive(unhex('00200000'), silence: _silence, longest: _longest), throwsA(isA<SecurityKeyFailed>()));
    expect(reader.clock, start);
  });

  test('powering off a key that is gone is not an error', () async {
    final reader = _Reader()..reads.add(['81 00000000 00 01 42 fe 00']);

    await reader.card().powerOff(_silence);
    expect(reader.written.single, '63000000000001000000');
  });
}
