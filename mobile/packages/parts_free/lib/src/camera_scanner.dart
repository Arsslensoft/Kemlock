import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

import 'camera.dart';
import 'qr_decoder.dart';

/// Decodes frames away from the screen's thread, one at a time.
abstract interface class FrameDecoder {
  /// The text of the QR code in [frame], or null.
  Future<String?> decode(Luminance frame);

  /// Ends the decoder; [decode] is not called after.
  Future<void> close();
}

/// [FrameDecoder] on a background isolate of its own, kept for as long as the camera is on.
class IsolateFrameDecoder implements FrameDecoder {
  IsolateFrameDecoder._(this._isolate, this._requests, this._replies);

  /// Starts the isolate.
  static Future<IsolateFrameDecoder> start() async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_serve, replies.sendPort, debugName: 'qr-decoder');
    final events = replies.asBroadcastStream();
    final requests = await events.first as SendPort;
    return IsolateFrameDecoder._(isolate, requests, _Replies(replies, events));
  }

  final Isolate _isolate;
  final SendPort _requests;
  final _Replies _replies;
  var _closed = false;

  @override
  Future<String?> decode(Luminance frame) async {
    if (_closed) return null;
    final reply = _replies.next();
    _requests.send((TransferableTypedData.fromList([frame.bytes]), frame.width, frame.height));
    return reply;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }

  static void _serve(SendPort replies) {
    final requests = ReceivePort();
    replies.send(requests.sendPort);
    requests.listen((message) {
      final (data, width, height) = message as (TransferableTypedData, int, int);
      replies.send(decodeQr(Luminance(data.materialize().asUint8List(), width, height)));
    });
  }
}

/// The isolate's answers, in the order the frames went.
class _Replies {
  _Replies(this._port, Stream<Object?> events) {
    _subscription = events.listen((reply) {
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete(reply as String?);
    });
  }

  final ReceivePort _port;
  late final StreamSubscription<Object?> _subscription;
  final List<Completer<String?>> _waiting = [];

  Future<String?> next() => (_waiting..add(Completer())).last.future;

  void close() {
    for (final waiting in _waiting) {
      waiting.complete(null);
    }
    _waiting.clear();
    unawaited(_subscription.cancel());
    _port.close();
  }
}

/// The free build's camera behind a QR viewfinder (openspec: add-fdroid-release, design
/// decision 3): the `camera` plugin's preview and frames, each frame's luminance decoded on a
/// background isolate with zxing2, about five frames a second. Like `mobile_scanner` in the
/// store build, it reports a code each time it reads it; the viewfinder drops repeats.
class CameraScannerSource extends ScannerSource {
  CameraScannerSource({Camera? camera, this.interval = const Duration(milliseconds: 200), Future<FrameDecoder> Function()? decoder})
    : _camera = camera ?? PluginCamera(),
      _startDecoder = decoder ?? IsolateFrameDecoder.start;

  final Camera _camera;
  final Future<FrameDecoder> Function() _startDecoder;

  /// The least time between two frames decoded; frames in between are dropped, as are
  /// frames that come while one is being decoded.
  final Duration interval;

  final ValueNotifier<ScannerState> _state = ValueNotifier(const ScannerState());
  final StreamController<String> _codes = StreamController.broadcast();
  final Stopwatch _sinceLast = Stopwatch();
  List<Lens> _lenses = const [];
  int _lens = 0;
  FrameDecoder? _decoder;
  bool _busy = false;
  bool _disposed = false;

  /// Whether frames are being decoded: from a start until a stop.
  @visibleForTesting
  bool get decoding => _decoder != null;

  @override
  ValueListenable<ScannerState> get state => _state;

  @override
  Stream<String> get codes => _codes.stream;

  void _fail(ScannerFailure failure) {
    if (!_disposed) _state.value = ScannerState(phase: ScannerPhase.failed, failure: failure);
  }

  @override
  Future<void> start() async {
    if (_disposed || _state.value.phase == ScannerPhase.starting || _state.value.isLive) return;
    _state.value = _state.value.copyWith(phase: ScannerPhase.starting);
    try {
      _lenses = await _camera.lenses();
      if (_lenses.isEmpty) return _fail(const ScannerFailure(ScannerFailureKind.noCamera));
      // The first back camera, as a phone's camera app opens.
      final back = _lenses.indexWhere((lens) => !lens.front);
      _lens = back < 0 ? 0 : back;
      _decoder ??= await _startDecoder();
      await _open();
    } on CameraFailure catch (error) {
      await _stopDecoding();
      _fail(error.failure);
    } catch (error) {
      await _stopDecoding();
      _fail(ScannerFailure(ScannerFailureKind.other, '$error'));
    }
  }

  Future<void> _open() async {
    await _camera.open(_lenses[_lens], _onFrame);
    _sinceLast.reset();
    if (_disposed) return;
    _state.value = ScannerState(phase: ScannerPhase.live, torchAvailable: _lenses[_lens].hasTorch, cameraCount: _lenses.length);
  }

  void _onFrame(Luminance frame) {
    final decoder = _decoder;
    if (_disposed || decoder == null || _busy) return;
    if (_sinceLast.isRunning && _sinceLast.elapsed < interval) return;
    _busy = true;
    _sinceLast
      ..reset()
      ..start();
    unawaited(
      decoder.decode(frame).then((text) {
        _busy = false;
        if (text != null && text.isNotEmpty && !_disposed && _decoder == decoder) _codes.add(text);
      }, onError: (Object _) => _busy = false),
    );
  }

  Future<void> _stopDecoding() async {
    final decoder = _decoder;
    _decoder = null;
    _busy = false;
    await decoder?.close();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    await _stopDecoding();
    try {
      await _camera.close();
    } catch (_) {
      // Closed already.
    }
    if (!_disposed) _state.value = _state.value.copyWith(phase: ScannerPhase.stopped, torchOn: false);
  }

  @override
  Future<void> setTorch(bool on) async {
    final state = _state.value;
    if (_disposed || !state.isLive || !state.torchAvailable || state.torchOn == on) return;
    try {
      await _camera.setTorch(on);
      if (!_disposed) _state.value = _state.value.copyWith(torchOn: on);
    } on CameraFailure {
      // A light that won't switch is a light this camera hasn't got.
      if (!_disposed) _state.value = _state.value.copyWith(torchAvailable: false, torchOn: false);
    }
  }

  @override
  Future<void> switchCamera() async {
    if (_disposed || _lenses.length < 2 || !_state.value.isLive) return;
    _lens = (_lens + 1) % _lenses.length;
    try {
      await _camera.close();
      await _open();
    } on CameraFailure catch (error) {
      await _stopDecoding();
      _fail(error.failure);
    }
  }

  @override
  Widget buildPreview(BuildContext context) => _camera.preview();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _codes.close();
    _state.dispose();
  }
}
