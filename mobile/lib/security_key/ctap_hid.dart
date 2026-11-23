/// CTAP's framing over USB HID (CTAP 2.1, section 11.2): a message is cut
/// into fixed-size reports, the first with the command and the length,
/// the others numbered, all on a channel the key hands out.
library;

import 'dart:typed_data';

import '../platform/security_keys.dart';

/// The channel everyone may use to ask for a channel of their own.
const ctapHidBroadcast = 0xffffffff;

/// The size of a report on every key seen; the link says if it differs.
const ctapHidReportSize = 64;

/// The commands of CTAPHID.
abstract final class CtapHidCommand {
  static const ping = 0x01;
  static const msg = 0x03;
  static const init = 0x06;
  static const wink = 0x08;
  static const cbor = 0x10;
  static const cancel = 0x11;
  static const keepalive = 0x3b;
  static const error = 0x3f;
}

/// What a key says while it works on a request.
enum CtapHidKeepalive {
  /// Still working.
  processing,

  /// Waiting for the person to touch it.
  touchNeeded,

  /// A status this app does not know: still a sign of life.
  other;

  static CtapHidKeepalive fromStatus(int status) => switch (status) {
    1 => processing,
    2 => touchNeeded,
    _ => other,
  };
}

/// Why a key refused a CTAPHID message.
enum CtapHidErrorKind {
  invalidCommand(0x01),
  invalidParameter(0x02),
  invalidLength(0x03),
  invalidSequence(0x04),
  messageTimeout(0x05),
  channelBusy(0x06),
  lockRequired(0x0a),
  invalidChannel(0x0b),
  other(0x7f);

  const CtapHidErrorKind(this.code);

  final int code;

  static CtapHidErrorKind fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return other;
  }
}

/// A CTAPHID `ERROR` from the key, or reports that do not follow the framing.
class CtapHidError implements Exception {
  const CtapHidError(this.kind);

  final CtapHidErrorKind kind;

  @override
  String toString() => 'CtapHidError(${kind.name})';
}

/// The longest message that fits the framing: one initial report and 128
/// continuation reports (7,609 bytes with 64-byte reports).
int ctapHidMaxMessage([int reportSize = ctapHidReportSize]) => (reportSize - 7) + 128 * (reportSize - 5);

/// [payload] as the reports that carry it on [channel] as [command]: an
/// initial report (channel, command with the top bit set, length), then
/// continuation reports numbered from 0, each padded with zeros to
/// [reportSize].
List<Uint8List> ctapHidPack(int channel, int command, List<int> payload, {int reportSize = ctapHidReportSize}) {
  if (payload.length > ctapHidMaxMessage(reportSize)) {
    throw ArgumentError.value(payload.length, 'payload', 'too long for CTAPHID');
  }
  Uint8List report(List<int> head, int from, int room) {
    final bytes = Uint8List(reportSize)..setAll(0, head);
    final end = from + room < payload.length ? from + room : payload.length;
    bytes.setRange(head.length, head.length + end - from, payload, from);
    return bytes;
  }

  final cid = [channel >> 24 & 0xff, channel >> 16 & 0xff, channel >> 8 & 0xff, channel & 0xff];
  final reports = [
    report([...cid, command | 0x80, payload.length >> 8, payload.length & 0xff], 0, reportSize - 7),
  ];
  var sequence = 0;
  for (var offset = reportSize - 7; offset < payload.length; offset += reportSize - 5) {
    reports.add(report([...cid, sequence++], offset, reportSize - 5));
  }
  return reports;
}

/// A whole CTAPHID message.
class CtapHidMessage {
  const CtapHidMessage(this.channel, this.command, this.payload);

  final int channel;
  final int command;
  final Uint8List payload;
}

/// Puts the reports a key sends on [channel] back together.
class CtapHidAssembler {
  CtapHidAssembler(this.channel);

  final int channel;
  int? _command;
  int _length = 0;
  int _sequence = 0;
  final BytesBuilder _payload = BytesBuilder(copy: true);

  /// Takes one [report]. Returns the message it completes, or null while
  /// more reports are due. A report for another channel is ignored. Throws
  /// a [CtapHidError] for a continuation that is out of order or that no
  /// initial report announced.
  CtapHidMessage? add(Uint8List report) {
    if (report.length < 5) return null;
    final cid = report[0] << 24 | report[1] << 16 | report[2] << 8 | report[3];
    if (cid != channel) return null;
    if (report[4] & 0x80 != 0) {
      if (report.length < 7) throw const CtapHidError(CtapHidErrorKind.invalidLength);
      _command = report[4] & 0x7f;
      _length = report[5] << 8 | report[6];
      _sequence = 0;
      _payload.clear();
      _take(report, 7);
    } else {
      if (_command == null || report[4] != _sequence) {
        _reset();
        throw const CtapHidError(CtapHidErrorKind.invalidSequence);
      }
      _sequence++;
      _take(report, 5);
    }
    if (_payload.length < _length) return null;
    final message = CtapHidMessage(channel, _command!, _payload.takeBytes());
    _reset();
    return message;
  }

  void _take(Uint8List report, int from) {
    final wanted = _length - _payload.length;
    final end = report.length - from < wanted ? report.length : from + wanted;
    _payload.add(Uint8List.sublistView(report, from, end));
  }

  void _reset() {
    _command = null;
    _length = 0;
    _sequence = 0;
    _payload.clear();
  }
}

/// A key's answer to `INIT`: the channel it hands out and what it can do.
class CtapHidInit {
  const CtapHidInit({required this.channel, required this.protocolVersion, required this.version, required this.capabilities});

  /// Reads the answer in [payload], or null when it answers another
  /// [nonce] than the one sent (someone else's `INIT` on the shared channel).
  static CtapHidInit? parse(Uint8List payload, List<int> nonce) {
    if (payload.length < 17) throw const CtapHidError(CtapHidErrorKind.invalidLength);
    for (var i = 0; i < 8; i++) {
      if (payload[i] != nonce[i]) return null;
    }
    return CtapHidInit(
      channel: payload[8] << 24 | payload[9] << 16 | payload[10] << 8 | payload[11],
      protocolVersion: payload[12],
      version: (payload[13], payload[14], payload[15]),
      capabilities: payload[16],
    );
  }

  final int channel;
  final int protocolVersion;

  /// The device's version as it packs it: major, minor, build.
  final (int, int, int) version;
  final int capabilities;

  /// Whether the key speaks CTAP2 (`CBOR`). One that does not is U2F only.
  bool get cbor => capabilities & 0x04 != 0;

  /// Whether the key speaks U2F (`MSG`).
  bool get msg => capabilities & 0x08 == 0;
}

/// One CTAPHID conversation over a link that writes and reads raw reports.
/// It asks for a channel, sends `CBOR` requests and waits for their
/// answers through the key's keep-alives.
class CtapHidChannel {
  CtapHidChannel({
    required this._write,
    required this._read,
    required this._now,
    required this._nonce,
    this.reportSize = ctapHidReportSize,
  });

  final Future<void> Function(List<Uint8List> reports) _write;
  final Future<List<Uint8List>> Function(Duration timeout) _read;
  final DateTime Function() _now;
  final Uint8List Function() _nonce;
  final int reportSize;

  int? _channel;
  bool _waiting = false;

  /// What the key answered to `INIT`.
  CtapHidInit? info;

  /// Asks the key for a channel, within [timeout].
  Future<CtapHidInit> init(Duration timeout) async {
    final nonce = _nonce();
    await _write(ctapHidPack(ctapHidBroadcast, CtapHidCommand.init, nonce, reportSize: reportSize));
    final assembler = CtapHidAssembler(ctapHidBroadcast);
    final deadline = _now().add(timeout);
    while (true) {
      final left = deadline.difference(_now());
      if (left <= Duration.zero) throw const SecurityKeyTimeout();
      for (final report in await _read(left)) {
        final message = assembler.add(report);
        if (message == null) continue;
        if (message.command == CtapHidCommand.error) throw _error(message);
        if (message.command != CtapHidCommand.init) continue;
        final answer = CtapHidInit.parse(message.payload, nonce);
        if (answer == null) continue;
        _channel = answer.channel;
        return info = answer;
      }
    }
  }

  /// Sends [payload] as [command] and returns the key's answer. The key
  /// must show a sign of life every [silence]; while it sends keep-alives,
  /// each told to [onKeepalive], the wait goes on, to [longest] at most.
  /// Then, and when the key goes silent, it is told to stop and
  /// [SecurityKeyTimeout] is thrown.
  Future<Uint8List> request(
    int command,
    List<int> payload, {
    required Duration silence,
    required Duration longest,
    void Function(CtapHidKeepalive status)? onKeepalive,
  }) async {
    final channel = _channel;
    if (channel == null) throw StateError('No CTAPHID channel yet.');
    await _write(ctapHidPack(channel, command, payload, reportSize: reportSize));
    final assembler = CtapHidAssembler(channel);
    final start = _now();
    var lastSign = start;
    _waiting = true;
    try {
      while (true) {
        final now = _now();
        final untilSilent = lastSign.add(silence).difference(now);
        final untilLongest = start.add(longest).difference(now);
        final left = untilSilent < untilLongest ? untilSilent : untilLongest;
        if (left <= Duration.zero) {
          await cancel();
          throw const SecurityKeyTimeout();
        }
        for (final report in await _read(left)) {
          final message = assembler.add(report);
          if (message == null) continue;
          switch (message.command) {
            case CtapHidCommand.keepalive:
              lastSign = _now();
              onKeepalive?.call(CtapHidKeepalive.fromStatus(message.payload.isEmpty ? 0 : message.payload[0]));
            case CtapHidCommand.error:
              throw _error(message);
            default:
              if (message.command == command) return message.payload;
          }
        }
      }
    } finally {
      _waiting = false;
    }
  }

  /// Whether a request is waiting for its answer.
  bool get isWaiting => _waiting;

  /// Tells the key to drop the request it is working on. The key then
  /// answers that request with CTAP's "cancelled" status.
  Future<void> cancel() async {
    final channel = _channel;
    if (channel == null) return;
    await _write(ctapHidPack(channel, CtapHidCommand.cancel, const [], reportSize: reportSize));
  }

  CtapHidError _error(CtapHidMessage message) =>
      CtapHidError(CtapHidErrorKind.fromCode(message.payload.isEmpty ? 0x7f : message.payload[0]));
}
