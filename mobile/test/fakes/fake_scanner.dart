import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/scanner_source.dart';

/// Stands in for the camera behind every QR viewfinder. The real viewfinder
/// is on screen, with its hint and controls; only the camera is fake.
///
/// ```dart
/// final scanner = FakeScanner();
/// await pumpScreen(tester, const MyScreen(), overrides: [scanner.asOverride]);
/// await scanner.emitScan(tester, 'otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP');
/// ```
///
/// - [emitScan] hands the viewfinder on screen a code, as the camera would,
///   and pumps a frame so its `onScan` has run when it returns.
/// - [deny] makes the next start fail as a refused camera permission does;
///   [failWith] fails it any other way.
/// - The viewfinder doesn't animate unless [animated], so `pumpAndSettle` settles.
class FakeScanner {
  FakeScanner({this.animated = false, this.torch = true, this.cameras = 2});

  /// Whether the viewfinder animates as on a phone; for screenshots.
  final bool animated;

  /// Whether the camera has a torch.
  final bool torch;

  /// How many cameras the phone has.
  final int cameras;

  /// Every source the viewfinders on screen made, oldest first.
  final List<FakeScannerSource> sources = [];

  ScannerFailure? _nextFailure;

  Override get asOverride => scannerSourceProvider.overrideWithValue(_create);

  FakeScannerSource _create() {
    final source = FakeScannerSource._(this);
    sources.add(source);
    return source;
  }

  /// The source of the viewfinder most recently put on screen and not yet gone.
  FakeScannerSource get current {
    final live = sources.where((s) => !s.disposed);
    if (live.isEmpty) throw StateError('No QR viewfinder is on screen');
    return live.last;
  }

  /// Whether a viewfinder is on screen with its camera on.
  bool get isScanning => sources.any((s) => !s.disposed && s.state.value.isLive);

  /// Makes the next start fail as a refused camera permission does.
  void deny() => failWith(const ScannerFailure(ScannerFailureKind.permissionDenied));

  /// Makes the next start fail with [failure].
  void failWith(ScannerFailure failure) => _nextFailure = failure;

  ScannerFailure? _takeFailure() {
    final failure = _nextFailure;
    _nextFailure = null;
    return failure;
  }

  /// Feeds [value] to the viewfinder on screen, as if the camera had just
  /// read it, then pumps so the viewfinder has handled it.
  Future<void> emitScan(WidgetTester tester, String value) async {
    current._emit(value);
    await tester.pump();
  }
}

/// One viewfinder's fake camera. Starts at once (or fails, when told to),
/// and records what the viewfinder asked of it.
class FakeScannerSource extends ScannerSource {
  FakeScannerSource._(this._owner) : _state = ValueNotifier(ScannerState(cameraCount: _owner.cameras, torchAvailable: _owner.torch));

  final FakeScanner _owner;
  final ValueNotifier<ScannerState> _state;
  final StreamController<String> _codes = StreamController.broadcast(sync: true);

  int starts = 0;
  int stops = 0;
  int switches = 0;
  bool disposed = false;

  /// Every value the torch was set to.
  final List<bool> torchCalls = [];

  @override
  ValueListenable<ScannerState> get state => _state;

  @override
  Stream<String> get codes => _codes.stream;

  @override
  bool get animated => _owner.animated;

  void _emit(String value) {
    if (disposed) throw StateError('That QR viewfinder has gone');
    _codes.add(value);
  }

  @override
  Future<void> start() async {
    if (disposed) return;
    starts++;
    final failure = _owner._takeFailure();
    _state.value = failure == null
        ? _state.value.copyWith(phase: ScannerPhase.live)
        : _state.value.copyWith(phase: ScannerPhase.failed, failure: failure);
  }

  @override
  Future<void> stop() async {
    if (disposed) return;
    stops++;
    _state.value = _state.value.copyWith(phase: ScannerPhase.stopped, torchOn: false);
  }

  @override
  Future<void> setTorch(bool on) async {
    torchCalls.add(on);
    if (_state.value.torchAvailable) _state.value = _state.value.copyWith(torchOn: on);
  }

  @override
  Future<void> switchCamera() async => switches++;

  @override
  Widget buildPreview(BuildContext context) => const FakeCameraPreview();

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _codes.close();
  }
}

/// Where the camera picture would be: a dim gradient, so screenshots show the viewfinder over something.
class FakeCameraPreview extends StatelessWidget {
  const FakeCameraPreview({super.key});

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2A2F38), Color(0xFF0E1013)]),
    ),
    child: SizedBox.expand(),
  );
}

/// Reads whatever QR code the test says a picture holds.
class FakeQrImageReader implements QrImageReader {
  /// The text of the QR code in every picture, or null for none.
  String? result;

  /// The paths it was asked to read.
  final List<String> paths = [];

  @override
  Future<String?> decode(String path) async {
    paths.add(path);
    return result;
  }

  Override get asOverride => qrImageReaderProvider.overrideWithValue(this);
}
