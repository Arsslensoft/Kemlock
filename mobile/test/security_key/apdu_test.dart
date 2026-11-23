import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/apdu.dart';

import 'hex.dart';

/// A card that answers from a script and keeps what it was sent.
class _Card {
  _Card(List<String> answers) : _answers = Queue.of(answers);

  final Queue<String> _answers;
  final List<String> sent = [];

  Future<Uint8List> send(Uint8List apdu) async {
    sent.add(hex(apdu));
    return unhex(_answers.removeFirst());
  }
}

void main() {
  test('encodes each of the four cases, short and extended', () {
    final none = ApduCommand(ins: 0x0e);
    expect(hex(none.encodeShort()), '000e0000');
    expect(hex(none.encodeExtended()), '000e0000');

    final answerOnly = ApduCommand(ins: 0xb0, p1: 0x01, p2: 0x02, le: 5);
    expect(hex(answerOnly.encodeShort()), '00b0010205');
    expect(hex(answerOnly.encodeExtended()), '00b00102000005');
    expect(hex(ApduCommand(ins: 0xb0, le: 256).encodeShort()), '00b0000000', reason: '0 stands for 256');
    expect(hex(ApduCommand(ins: 0xb0, le: 300).encodeExtended()), '00b0000000012c');
    expect(hex(ApduCommand(ins: 0xb0, le: 65536).encodeExtended()), '00b00000000000', reason: '0 stands for 65,536');

    final dataOnly = ApduCommand(cla: 0x80, ins: 0xd6, data: [1, 2, 3]);
    expect(hex(dataOnly.encodeShort()), '80d6000003010203');
    expect(hex(dataOnly.encodeExtended()), '80d60000000003010203');

    final both = ApduCommand(ins: 0xa4, p1: 0x04, data: [0xa0, 0x00], le: 256);
    expect(hex(both.encodeShort()), '00a4040002a00000');
    expect(hex(both.encodeExtended()), '00a40400000002a0000100');
  });

  test('knows what the short encoding cannot hold', () {
    expect(ApduCommand(ins: 1, data: Uint8List(255), le: 256).fitsShort, isTrue);
    expect(ApduCommand(ins: 1, data: Uint8List(256)).fitsShort, isFalse);
    expect(ApduCommand(ins: 1, le: 257).fitsShort, isFalse);
    expect(() => ApduCommand(ins: 1, data: Uint8List(256)).encodeShort(), throwsStateError);
    expect(() => ApduCommand(ins: 1, data: Uint8List(65536)), throwsArgumentError);
    expect(() => ApduCommand(ins: 1, le: 0), throwsArgumentError);
    expect(() => ApduCommand(ins: 1, le: 65537), throwsArgumentError);
  });

  test('selects an application by name', () async {
    final card = _Card(['5532465f5632 9000']);

    final answer = await selectApplication(card.send, unhex('a0000006472f0001'), extendedLength: true);

    expect(card.sent, ['00a4040008a0000006472f000100']);
    expect(String.fromCharCodes(answer), 'U2F_V2');
  });

  test('reports 6A82 on SELECT as no such application, and any other refusal as a failure', () async {
    await expectLater(
      selectApplication(_Card(['6a82']).send, unhex('a000000308'), extendedLength: false),
      throwsA(isA<SecurityKeyNoApplication>()),
    );
    await expectLater(
      selectApplication(_Card(['6985']).send, unhex('a000000308'), extendedLength: false),
      throwsA(isA<SecurityKeyFailed>().having((e) => e.message, 'message', contains('6985'))),
    );
  });

  test('returns a status word other than 9000, and does not throw it', () async {
    final card = _Card(['0102 6982']);

    final response = await transmitApdu(card.send, ApduCommand(ins: 0x20, data: [1]), extendedLength: true);

    expect(response.sw, 0x6982);
    expect(response.sw1, 0x69);
    expect(response.sw2, 0x82);
    expect(response.ok, isFalse);
    expect(response.data, [1, 2]);
  });

  test('sends a 1,000-byte command as one extended APDU where the link takes them', () async {
    final card = _Card(['9000']);
    final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));

    final response = await transmitApdu(card.send, ApduCommand(cla: 0x80, ins: 0x10, data: data, le: 65536), extendedLength: true);

    expect(response.ok, isTrue);
    expect(card.sent.single, '801000000003e8${hex(data)}0000');
  });

  test('chains a 1,000-byte command into parts, the chaining bit on all but the last', () async {
    final card = _Card(['9000', '9000', '9000', 'aabb 9000']);
    final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));

    final response = await transmitApdu(card.send, ApduCommand(cla: 0x80, ins: 0x10, data: data, le: 65536), extendedLength: false);

    expect(response.data, [0xaa, 0xbb]);
    expect(card.sent, [
      '90100000ff${hex(data.sublist(0, 255))}',
      '90100000ff${hex(data.sublist(255, 510))}',
      '90100000ff${hex(data.sublist(510, 765))}',
      '80100000eb${hex(data.sublist(765))}00',
    ]);
  });

  test('stops chaining when the card refuses a part', () async {
    final card = _Card(['9000', '6700']);

    final response = await transmitApdu(card.send, ApduCommand(ins: 0x10, data: Uint8List(1000)), extendedLength: false);

    expect(response.sw, 0x6700);
    expect(card.sent, hasLength(2));
  });

  test('joins an answer the card hands out in three parts', () async {
    final card = _Card(['${'11' * 256} 6100', '${'22' * 256} 6110', '${'33' * 16} 9000']);

    final response = await transmitApdu(card.send, ApduCommand(cla: 0x80, ins: 0x10, data: [4], le: 256), extendedLength: false);

    expect(card.sent, ['80100000010400', '00c0000000', '00c0000010']);
    expect(response.ok, isTrue);
    expect(hex(response.data), '11' * 256 + '22' * 256 + '33' * 16);
  });

  test('stops following a card that says more is to come past the longest answer', () async {
    var asked = 0;
    // 256 bytes and "more to come", every time
    Future<Uint8List> endless(Uint8List apdu) async {
      asked++;
      return Uint8List.fromList([...List.filled(256, 0x44), 0x61, 0x00]);
    }

    await expectLater(
      transmitApdu(endless, ApduCommand(ins: 0xca, p2: 0x4f, le: 256), extendedLength: false),
      throwsA(isA<SecurityKeyFailed>()),
    );
    expect(asked * 256, inInclusiveRange(apduLongestAnswer, apduLongestAnswer + 512));
  });

  test('joins an answer as long as the longest an extended command asks for', () async {
    final card = _Card([for (var i = 0; i < 255; i++) '${'55' * 256} 6100', '${'55' * 256} 9000']);

    final response = await transmitApdu(card.send, ApduCommand(ins: 0xca, p2: 0x4f, le: 256), extendedLength: false);

    expect(response.data, hasLength(apduExtendedLe));
  });

  test('asks again with the length the card names', () async {
    final card = _Card(['6c05', '0102030405 9000']);

    final response = await transmitApdu(card.send, ApduCommand(ins: 0xca, p2: 0x4f, le: 256), extendedLength: false);

    expect(card.sent, ['00ca004f00', '00ca004f05']);
    expect(response.data, [1, 2, 3, 4, 5]);
  });

  test('refuses an answer too short to hold a status word', () async {
    await expectLater(transmitApdu(_Card(['90']).send, ApduCommand(ins: 1), extendedLength: false), throwsA(isA<SecurityKeyFailed>()));
  });
}
