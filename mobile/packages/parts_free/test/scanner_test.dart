import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/camera.dart';
import 'package:kemlock_parts/src/camera_scanner.dart';
import 'package:kemlock_parts/src/picture_reader.dart';
import 'package:kemlock_parts/src/qr_decoder.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:zxing2/qrcode.dart';

const _otpauth = 'otpauth://totp/Example:alice@example.org?secret=JBSWY3DPEHPK3PXP&issuer=Example';

/// A [width] by [height] picture of grey paper with [text]'s QR code in the middle, [scale]
/// pixels a module, as a camera sees a phone's screen: black a little grey, white a little dim.
Luminance qrFrame(String text, {int width = 640, int height = 480, int scale = 4}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final bytes = Uint8List(width * height)..fillRange(0, width * height, 180);
  final side = (matrix.width + 8) * scale;
  final left = (width - side) ~/ 2;
  final top = (height - side) ~/ 2;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final mx = x ~/ scale - 4;
      final my = y ~/ scale - 4;
      final dark = mx >= 0 && my >= 0 && mx < matrix.width && my < matrix.height && matrix.get(mx, my) == 1;
      bytes[(top + y) * width + left + x] = dark ? 30 : 230;
    }
  }
  return Luminance(bytes, width, height);
}

/// A frame with no code in it.
Luminance blankFrame() => Luminance(Uint8List(640 * 480)..fillRange(0, 640 * 480, 200), 640, 480);

/// Stands in for the phone's cameras.
class FakeCamera implements Camera {
  FakeCamera({List<Lens>? lenses})
    : cameras = lenses ?? const [Lens('back', front: false, hasTorch: true), Lens('front', front: true, hasTorch: false)];

  List<Lens> cameras;

  /// What opening throws, as a refused permission does.
  CameraFailure? openFails;

  /// Every lens opened, in order.
  final List<String> opened = [];
  final List<bool> torch = [];
  int closes = 0;
  void Function(Luminance frame)? _onFrame;

  bool get isOpen => _onFrame != null;

  /// Hands the scanner a frame, as the camera's stream does.
  void show(Luminance frame) => _onFrame?.call(frame);

  @override
  Future<List<Lens>> lenses() async => cameras;

  @override
  Future<void> open(Lens lens, void Function(Luminance frame) onFrame) async {
    final failure = openFails;
    if (failure != null) throw failure;
    opened.add(lens.id);
    _onFrame = onFrame;
  }

  @override
  Future<void> setTorch(bool on) async => torch.add(on);

  @override
  Future<void> close() async {
    closes++;
    _onFrame = null;
  }

  @override
  Widget preview() => const SizedBox();
}

/// The real decoder on its isolate, telling the test when it is ended.
class WatchedDecoder implements FrameDecoder {
  WatchedDecoder(this._inner);

  static final started = <WatchedDecoder>[];

  static Future<FrameDecoder> start() async {
    final decoder = WatchedDecoder(await IsolateFrameDecoder.start());
    started.add(decoder);
    return decoder;
  }

  final FrameDecoder _inner;
  bool closed = false;

  @override
  Future<String?> decode(Luminance frame) => _inner.decode(frame);

  @override
  Future<void> close() async {
    closed = true;
    await _inner.close();
  }
}

/// Waits until [done], as the isolate decodes in its own time.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeCamera camera;
  late CameraScannerSource source;
  late List<String> codes;
  StreamSubscription<String>? listening;

  setUp(() {
    WatchedDecoder.started.clear();
    camera = FakeCamera();
    source = CameraScannerSource(camera: camera, interval: Duration.zero, decoder: WatchedDecoder.start);
    codes = [];
    listening = source.codes.listen(codes.add);
  });

  tearDown(() async {
    await listening?.cancel();
    await source.dispose();
  });

  test('reads the QR code in a frame', () async {
    await source.start();
    expect(source.state.value, const ScannerState(phase: ScannerPhase.live, torchAvailable: true, cameraCount: 2));
    expect(camera.opened, ['back']);

    camera.show(qrFrame(_otpauth));
    await until(() => codes.isNotEmpty);

    expect(codes, [_otpauth]);
  });

  test('reports a code each time it reads it, as mobile_scanner does, and nothing for a frame without one', () async {
    await source.start();

    for (var i = 0; i < 10; i++) {
      camera.show(qrFrame('BMCKIT1-ABCDEFGH-231-CODE'));
      await until(() => codes.length > i);
    }
    camera.show(blankFrame());
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(codes, List.filled(10, 'BMCKIT1-ABCDEFGH-231-CODE'));
  });

  test('drops frames that come while one is being decoded', () async {
    await source.start();

    for (var i = 0; i < 5; i++) {
      camera.show(qrFrame(_otpauth));
    }
    await until(() => codes.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(codes, [_otpauth]);
  });

  test('reports a refused camera permission', () async {
    camera.openFails = const CameraFailure(ScannerFailure(ScannerFailureKind.permissionDenied));

    await source.start();

    expect(source.state.value.phase, ScannerPhase.failed);
    expect(source.state.value.failure, const ScannerFailure(ScannerFailureKind.permissionDenied));
    expect(source.decoding, isFalse);
  });

  test('reports a phone with no camera', () async {
    camera.cameras = const [];

    await source.start();

    expect(source.state.value.failure, const ScannerFailure(ScannerFailureKind.noCamera));
  });

  test('stop closes the camera and ends the decoding isolate', () async {
    await source.start();
    expect(source.decoding, isTrue);

    await source.stop();

    expect(source.state.value.phase, ScannerPhase.stopped);
    expect(camera.isOpen, isFalse);
    expect(source.decoding, isFalse);
    expect(WatchedDecoder.started.single.closed, isTrue);
    camera.show(qrFrame(_otpauth));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(codes, isEmpty);

    // Starting again starts a new isolate.
    await source.start();
    expect(WatchedDecoder.started, hasLength(2));
  });

  test('turns the torch on and off, and moves to the other camera', () async {
    await source.start();

    await source.setTorch(true);
    expect(source.state.value.torchOn, isTrue);
    await source.setTorch(false);
    expect(camera.torch, [true, false]);

    await source.switchCamera();
    expect(camera.opened, ['back', 'front']);
    expect(source.state.value, const ScannerState(phase: ScannerPhase.live, cameraCount: 2));
    await source.setTorch(true);
    expect(camera.torch, [true, false], reason: 'the front camera has no torch');
  });

  test('reads a code turned a quarter, as a phone held upright sees it', () {
    expect(decodeQr(qrFrame(_otpauth).turned()), _otpauth);
  });

  group('DecoderImageReader', () {
    /// [frame] as a PNG file.
    Future<String> png(WidgetTester tester, Luminance frame) async {
      final rgba = Uint8List(frame.width * frame.height * 4);
      for (var i = 0; i < frame.bytes.length; i++) {
        rgba.setRange(i * 4, i * 4 + 4, [frame.bytes[i], frame.bytes[i], frame.bytes[i], 255]);
      }
      final file = File('${Directory.systemTemp.createTempSync('qr').path}/picture.png');
      await tester.runAsync(() async {
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(rgba, frame.width, frame.height, ui.PixelFormat.rgba8888, done.complete);
        final image = await done.future;
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        file.writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
      addTearDown(() => file.parent.deleteSync(recursive: true));
      return file.path;
    }

    testWidgets('reads the code in a picture', (tester) async {
      final path = await png(tester, qrFrame(_otpauth));
      expect(await tester.runAsync(() => const DecoderImageReader().decode(path)), _otpauth);
    });

    testWidgets('finds nothing in a picture without one, or in a file that is no picture', (tester) async {
      final path = await png(tester, blankFrame());
      expect(await tester.runAsync(() => const DecoderImageReader().decode(path)), isNull);

      File(path).writeAsStringSync('not a picture');
      expect(await tester.runAsync(() => const DecoderImageReader().decode(path)), isNull);
    });
  });
}
