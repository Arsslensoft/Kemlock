import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../platform/security_keys.dart';
import '../../ui/ui.dart';

/// Whether the build has the spike page: only one made with
/// `--dart-define=KEY_SPIKE=true`, never a release.
const keySpikeEnabled = bool.fromEnvironment('KEY_SPIKE');

/// Where the spike page is, in a build that has it.
const keySpikePath = '/key-spike';

/// The spike page's route when the build has the page, and nothing
/// otherwise: without the define there is no such route.
List<RouteBase> keySpikeRoutes({bool enabled = keySpikeEnabled}) => [
  if (enabled) GoRoute(path: keySpikePath, builder: (_, _) => const KeySpikePage()),
];

/// One frame the spike sent or got, with how long the answer took.
class SpikeFrame {
  const SpikeFrame(this.label, this.out, this.back, this.took, [this.error]);

  final String label;
  final Uint8List out;
  final Uint8List? back;
  final Duration took;
  final String? error;
}

String _hex(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join(' ');

/// SELECT of the FIDO application `A0000006472F0001`, written out.
final spikeSelect = Uint8List.fromList([0x00, 0xa4, 0x04, 0x00, 0x08, 0xa0, 0x00, 0x00, 0x06, 0x47, 0x2f, 0x00, 0x01, 0x00]);

/// `NFCCTAP_MSG` carrying `authenticatorGetInfo` (0x04).
final spikeGetInfo = Uint8List.fromList([0x80, 0x10, 0x00, 0x00, 0x01, 0x04, 0x00]);

/// `NFCCTAP_MSG` carrying `clientPIN getKeyAgreement` with protocol 1:
/// 0x06, then the map {1: 1, 2: 2}.
final spikeKeyAgreement = Uint8List.fromList([0x80, 0x10, 0x00, 0x00, 0x06, 0x06, 0xa2, 0x01, 0x01, 0x02, 0x02, 0x00]);

Uint8List _report(List<int> start) => Uint8List(64)..setAll(0, start);

/// A debug page for trying real keys before the protocol code is trusted
/// with them (openspec: add-security-key-management, design decision 14).
/// For each key that arrives and each of its links it sends hand-written
/// frames (SELECT of the FIDO application, `authenticatorGetInfo`,
/// `clientPIN getKeyAgreement`) straight over the channel, with none of
/// `lib/security_key`, and shows every frame in hex with its timing.
/// Nothing it shows is kept. Its texts are not translated: it is no part
/// of the app people get.
class KeySpikePage extends ConsumerStatefulWidget {
  const KeySpikePage({super.key});

  @override
  ConsumerState<KeySpikePage> createState() => _KeySpikePageState();
}

class _KeySpikePageState extends ConsumerState<KeySpikePage> {
  late final SecurityKeys _keys = ref.read(securityKeysProvider);
  StreamSubscription<SecurityKeyEvent>? _subscription;
  final List<String> _log = [];
  final List<SpikeFrame> _frames = [];
  SecurityKeyCapabilities? _capabilities;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _say(String line) {
    if (mounted) setState(() => _log.add(line));
  }

  Future<void> _start() async {
    final capabilities = await _keys.capabilities();
    if (!mounted) return;
    setState(() => _capabilities = capabilities);
    _subscription = _keys.watch().listen(_onEvent);
    try {
      for (final device in await _keys.present()) {
        unawaited(_try(device));
      }
    } on SecurityKeyError catch (error) {
      _say('present: ${error.code}');
    }
  }

  void _onEvent(SecurityKeyEvent event) {
    switch (event) {
      case SecurityKeyArrived(:final device):
        unawaited(_try(device));
      case SecurityKeyLeft(:final deviceId):
        _say('left $deviceId');
      case SecurityKeySessionEnded(:final error):
        _say('NFC session ended${error == null ? '' : ': ${error.code}'}');
    }
  }

  Future<void> _try(SecurityKeyDevice found) async {
    var device = found;
    _say('arrived ${device.id}${device.productName == null ? '' : ' "${device.productName}"'}');
    try {
      if (device.needsPermission) device = device.withLinks(await _keys.requestPermission(device.id));
      for (final link in device.links) {
        _say('link ${link.id} ${link.kind.name} extended=${link.extendedLength} frame=${link.frameSize}');
        await _keys.open(link.id);
        switch (link.kind) {
          case SecurityKeyLinkKind.nfc || SecurityKeyLinkKind.smartcard:
            await _apdu(link, 'SELECT', spikeSelect);
            await _apdu(link, 'getInfo', spikeGetInfo);
            await _apdu(link, 'getKeyAgreement', spikeKeyAgreement);
          case SecurityKeyLinkKind.usbHid:
            await _hid(link);
          case SecurityKeyLinkKind.usbCcid:
            await _ccid(link);
        }
        await _keys.close(link.id);
      }
    } on SecurityKeyError catch (error) {
      _say('${device.id}: ${error.code} $error');
    }
  }

  void _frame(SpikeFrame frame) {
    if (mounted) setState(() => _frames.add(frame));
  }

  Future<Uint8List?> _apdu(SecurityKeyLink link, String label, Uint8List apdu) async {
    final watch = Stopwatch()..start();
    try {
      final back = await _keys.transceive(link.id, apdu, timeout: const Duration(seconds: 10));
      _frame(SpikeFrame('${link.kind.name} $label', apdu, back, watch.elapsed));
      return back;
    } on SecurityKeyError catch (error) {
      _frame(SpikeFrame('${link.kind.name} $label', apdu, null, watch.elapsed, error.code));
      return null;
    }
  }

  /// Writes [reports] and shows what comes back within a second.
  Future<List<Uint8List>> _raw(SecurityKeyLink link, String label, List<Uint8List> reports) async {
    final watch = Stopwatch()..start();
    try {
      await _keys.write(link.id, reports);
      final back = await _keys.read(link.id, const Duration(seconds: 1));
      if (back.isEmpty) _frame(SpikeFrame('${link.kind.name} $label', reports.first, null, watch.elapsed, 'no answer'));
      for (final frame in back) {
        _frame(SpikeFrame('${link.kind.name} $label', reports.first, frame, watch.elapsed));
      }
      return back;
    } on SecurityKeyError catch (error) {
      _frame(SpikeFrame('${link.kind.name} $label', reports.first, null, watch.elapsed, error.code));
      return const [];
    }
  }

  /// CTAPHID by hand: INIT with a fixed nonce, then CBOR on the channel the key gave.
  Future<void> _hid(SecurityKeyLink link) async {
    final init = await _raw(link, 'INIT', [
      _report([0xff, 0xff, 0xff, 0xff, 0x86, 0x00, 0x08, 1, 2, 3, 4, 5, 6, 7, 8]),
    ]);
    if (init.isEmpty || init.first.length < 19) return;
    final channel = init.first.sublist(15, 19);
    await _raw(link, 'getInfo', [
      _report([...channel, 0x90, 0x00, 0x01, 0x04]),
    ]);
    await _raw(link, 'getKeyAgreement', [
      _report([...channel, 0x90, 0x00, 0x05, 0x06, 0xa2, 0x01, 0x01, 0x02, 0x02]),
    ]);
  }

  /// CCID by hand: power on, then SELECT in an XfrBlock.
  Future<void> _ccid(SecurityKeyLink link) async {
    await _raw(link, 'IccPowerOn', [
      Uint8List.fromList([0x62, 0, 0, 0, 0, 0, 1, 0, 0, 0]),
    ]);
    await _raw(link, 'SELECT', [
      Uint8List.fromList([0x6f, spikeSelect.length, 0, 0, 0, 0, 2, 0, 0, 0, ...spikeSelect]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final capabilities = _capabilities;
    final mono = AppType.mono(fontSize: 11.5, color: p.text);
    return Scaffold(
      appBar: AppBar(title: const Text('Key spike')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            capabilities == null
                ? 'Asking the phone…'
                : 'nfc=${capabilities.nfc} on=${capabilities.nfcOn} usb=${capabilities.usb} '
                      'smartcards=${capabilities.smartcards} readsOnRequest=${capabilities.readsOnRequest}',
            style: mono,
          ),
          if (capabilities != null && capabilities.readsOnRequest && capabilities.nfc)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: () => unawaited(_keys.beginNfc('Hold a key to the phone')), child: const Text('Read over NFC')),
            ),
          const SizedBox(height: 8),
          for (final line in _log) Text(line, style: mono.copyWith(color: p.textSecondary)),
          const SizedBox(height: 8),
          for (final frame in _frames)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SelectableText(
                '${frame.label}  ${frame.took.inMilliseconds} ms\n'
                '> ${_hex(frame.out)}\n'
                '< ${frame.back == null ? frame.error : _hex(frame.back!)}',
                style: mono,
              ),
            ),
        ],
      ),
    );
  }
}
