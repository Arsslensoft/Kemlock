import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/ctap_hid.dart';

import 'hex.dart';

const _cid = 0x00010203;

Uint8List _padded(String start) => Uint8List(64)..setAll(0, unhex(start));

/// A raw link whose reads come from a script, on a clock that a silent read moves on.
class _Wire {
  final List<String> written = [];
  final Queue<List<Uint8List>> reads = Queue();
  DateTime clock = DateTime.utc(2026, 11, 16);
  Duration perRead = Duration.zero;

  Future<void> write(List<Uint8List> reports) async => written.addAll(reports.map(hex));

  Future<List<Uint8List>> read(Duration timeout) async {
    if (reads.isEmpty) {
      clock = clock.add(timeout);
      return const [];
    }
    clock = clock.add(perRead);
    return reads.removeFirst();
  }

  CtapHidChannel channel() => CtapHidChannel(write: write, read: read, now: () => clock, nonce: () => unhex('0102030405060708'));

  /// Answers `INIT` with the channel [_cid] and the [capabilities].
  void answerInit({int capabilities = 0x05, String nonce = '0102030405060708'}) =>
      reads.add([_padded('ffffffff 86 0011 $nonce 00010203 02 05 04 03 ${capabilities.toRadixString(16).padLeft(2, '0')}')]);
}

const _silence = Duration(seconds: 10);
const _longest = Duration(seconds: 60);

void main() {
  test('packs a 1-byte message into one report, by hand', () {
    final reports = ctapHidPack(_cid, CtapHidCommand.cbor, [0x04]);

    expect(reports, hasLength(1));
    expect(hex(reports.single), '0001020390000104${'00' * 56}');
  });

  test('packs 57 bytes into one report and 58 into two', () {
    final fits = List.generate(57, (i) => i + 1);
    expect(ctapHidPack(_cid, CtapHidCommand.cbor, fits), hasLength(1));
    expect(hex(ctapHidPack(_cid, CtapHidCommand.cbor, fits).single), '00010203900039${hex(fits)}');

    final spills = List.generate(58, (i) => i + 1);
    final reports = ctapHidPack(_cid, CtapHidCommand.cbor, spills);
    expect(reports, hasLength(2));
    expect(hex(reports[0]), '0001020390003a${hex(spills.sublist(0, 57))}');
    expect(hex(reports[1]), '00010203003a${'00' * 58}');
  });

  test('packs and unpacks messages of 1, 57, 58 and 7,609 bytes to the same bytes', () {
    for (final length in [0, 1, 57, 58, 116, 117, 7609]) {
      final message = Uint8List.fromList(List.generate(length, (i) => (i * 7 + 3) & 0xff));
      final reports = ctapHidPack(_cid, CtapHidCommand.cbor, message);
      expect(reports.every((report) => report.length == 64), isTrue);
      expect(reports.length, length <= 57 ? 1 : 1 + ((length - 57) / 59).ceil(), reason: '$length bytes');

      final assembler = CtapHidAssembler(_cid);
      CtapHidMessage? whole;
      for (final report in reports) {
        expect(whole, isNull, reason: 'no message before its last report');
        whole = assembler.add(report);
      }
      expect(whole!.command, CtapHidCommand.cbor);
      expect(whole.payload, message, reason: '$length bytes');
    }
    expect(ctapHidPack(_cid, CtapHidCommand.cbor, Uint8List(7609)), hasLength(129));
    expect(ctapHidPack(_cid, CtapHidCommand.cbor, Uint8List(7609)).last[4], 127, reason: 'the last sequence number');
  });

  test('refuses a message over the limit', () {
    expect(ctapHidMaxMessage(), 7609);
    expect(() => ctapHidPack(_cid, CtapHidCommand.cbor, Uint8List(7610)), throwsArgumentError);
  });

  test('ignores a report for another channel', () {
    final assembler = CtapHidAssembler(_cid);
    final reports = ctapHidPack(_cid, CtapHidCommand.cbor, List.filled(60, 9));

    expect(assembler.add(reports[0]), isNull);
    expect(assembler.add(ctapHidPack(0x0a0b0c0d, CtapHidCommand.cbor, [1, 2, 3]).single), isNull);
    expect(assembler.add(_padded('0a0b0c0d 00 ffff')), isNull);
    expect(assembler.add(reports[1])!.payload, List.filled(60, 9));
  });

  test('fails on sequence numbers out of order, and on a continuation nothing announced', () {
    final reports = ctapHidPack(_cid, CtapHidCommand.cbor, Uint8List(200));
    final assembler = CtapHidAssembler(_cid);
    assembler.add(reports[0]);

    expect(() => assembler.add(reports[2]), throwsA(isA<CtapHidError>().having((e) => e.kind, 'kind', CtapHidErrorKind.invalidSequence)));
    expect(() => CtapHidAssembler(_cid).add(reports[1]), throwsA(isA<CtapHidError>()));
  });

  test('maps each ERROR code to its error', () async {
    final codes = {
      0x01: CtapHidErrorKind.invalidCommand,
      0x02: CtapHidErrorKind.invalidParameter,
      0x03: CtapHidErrorKind.invalidLength,
      0x04: CtapHidErrorKind.invalidSequence,
      0x05: CtapHidErrorKind.messageTimeout,
      0x06: CtapHidErrorKind.channelBusy,
      0x0a: CtapHidErrorKind.lockRequired,
      0x0b: CtapHidErrorKind.invalidChannel,
      0x7f: CtapHidErrorKind.other,
      0x55: CtapHidErrorKind.other,
    };
    for (final MapEntry(key: code, value: kind) in codes.entries) {
      expect(CtapHidErrorKind.fromCode(code), kind);
      final wire = _Wire()..answerInit();
      final channel = wire.channel();
      await channel.init(_silence);
      wire.reads.add([_padded('00010203 bf 0001 ${code.toRadixString(16).padLeft(2, '0')}')]);

      await expectLater(
        channel.request(CtapHidCommand.cbor, [4], silence: _silence, longest: _longest),
        throwsA(isA<CtapHidError>().having((e) => e.kind, 'kind', kind)),
        reason: '$code',
      );
    }
  });

  test('tells the keep-alive statuses "processing" and "touch needed" apart', () {
    expect(CtapHidKeepalive.fromStatus(1), CtapHidKeepalive.processing);
    expect(CtapHidKeepalive.fromStatus(2), CtapHidKeepalive.touchNeeded);
    expect(CtapHidKeepalive.fromStatus(9), CtapHidKeepalive.other);
  });

  test('asks for a channel with a nonce on the broadcast channel and reads what the key can do', () async {
    final wire = _Wire()
      // Someone else's INIT answer on the shared channel, then ours.
      ..answerInit(nonce: 'ffffffffffffffff')
      ..answerInit();
    final channel = wire.channel();

    final init = await channel.init(_silence);

    expect(wire.written.single, 'ffffffff8600080102030405060708${'00' * 49}');
    expect(init.channel, _cid);
    expect(init.protocolVersion, 2);
    expect(init.version, (5, 4, 3));
    expect(init.cbor, isTrue);
    expect(init.msg, isTrue);
    expect(channel.info, same(init));
  });

  test('reads a key without the CBOR capability as U2F only', () async {
    final wire = _Wire()..answerInit(capabilities: 0x01);

    expect((await wire.channel().init(_silence)).cbor, isFalse);
  });

  test('gives up on INIT when the key says nothing', () async {
    final wire = _Wire();
    final start = wire.clock;

    await expectLater(wire.channel().init(_silence), throwsA(isA<SecurityKeyTimeout>()));
    expect(wire.clock.difference(start), _silence);
  });

  test('sends a request and returns the answer that follows the keep-alives', () async {
    final wire = _Wire()..answerInit();
    final channel = wire.channel();
    await channel.init(_silence);
    wire.written.clear();
    wire.reads
      ..add([_padded('00010203 bb 0001 01')])
      ..add([_padded('00010203 bb 0001 02')])
      ..add(ctapHidPack(_cid, CtapHidCommand.cbor, [0x00, 0xa0]));
    final seen = <CtapHidKeepalive>[];

    final answer = await channel.request(CtapHidCommand.cbor, [0x07], silence: _silence, longest: _longest, onKeepalive: seen.add);

    expect(answer, [0x00, 0xa0]);
    expect(seen, [CtapHidKeepalive.processing, CtapHidKeepalive.touchNeeded]);
    expect(wire.written.single, '0001020390000107${'00' * 56}');
    expect(channel.isWaiting, isFalse);
  });

  test('tells a silent key to stop and gives up after the time limit', () async {
    final wire = _Wire()..answerInit();
    final channel = wire.channel();
    await channel.init(_silence);
    final start = wire.clock;

    await expectLater(channel.request(CtapHidCommand.cbor, [4], silence: _silence, longest: _longest), throwsA(isA<SecurityKeyTimeout>()));

    expect(wire.clock.difference(start), _silence);
    expect(wire.written.last, '00010203910000${'00' * 57}', reason: 'CANCEL');
  });

  test('keeps waiting while the key sends keep-alives, to the longest wait and no further', () async {
    final wire = _Wire()
      ..answerInit()
      ..perRead = const Duration(seconds: 1);
    final channel = wire.channel();
    await channel.init(_silence);
    final start = wire.clock;
    for (var i = 0; i < 100; i++) {
      wire.reads.add([_padded('00010203 bb 0001 01')]);
    }
    var keepalives = 0;

    await expectLater(
      channel.request(CtapHidCommand.cbor, [4], silence: _silence, longest: _longest, onKeepalive: (_) => keepalives++),
      throwsA(isA<SecurityKeyTimeout>()),
    );

    expect(wire.clock.difference(start), _longest);
    expect(keepalives, 60);
    expect(wire.written.last.substring(8, 10), '91');
  });
}
