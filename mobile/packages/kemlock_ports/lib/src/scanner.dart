import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Why the camera isn't scanning.
enum ScannerFailureKind { permissionDenied, noCamera, other }

@immutable
class ScannerFailure {
  const ScannerFailure(this.kind, [this.detail]);

  final ScannerFailureKind kind;

  /// What the platform said, for [ScannerFailureKind.other].
  final String? detail;

  @override
  bool operator ==(Object other) => other is ScannerFailure && other.kind == kind && other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, detail);
}

enum ScannerPhase { stopped, starting, live, failed }

/// What the camera is doing, for the viewfinder to show: `QRScanner.tsx`'s
/// starting, live and denied, plus the torch and the cameras to flip between.
@immutable
class ScannerState {
  const ScannerState({
    this.phase = ScannerPhase.stopped,
    this.failure,
    this.torchAvailable = false,
    this.torchOn = false,
    this.cameraCount = 1,
  });

  final ScannerPhase phase;

  /// Set when [phase] is [ScannerPhase.failed].
  final ScannerFailure? failure;
  final bool torchAvailable;
  final bool torchOn;

  /// How many cameras the phone has; the flip button shows when there are two or more.
  final int cameraCount;

  bool get isLive => phase == ScannerPhase.live;

  ScannerState copyWith({ScannerPhase? phase, ScannerFailure? failure, bool? torchAvailable, bool? torchOn, int? cameraCount}) {
    final next = phase ?? this.phase;
    return ScannerState(
      phase: next,
      failure: next == ScannerPhase.failed ? failure ?? this.failure : null,
      torchAvailable: torchAvailable ?? this.torchAvailable,
      torchOn: torchOn ?? this.torchOn,
      cameraCount: cameraCount ?? this.cameraCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScannerState &&
      other.phase == phase &&
      other.failure == failure &&
      other.torchAvailable == torchAvailable &&
      other.torchOn == torchOn &&
      other.cameraCount == cameraCount;

  @override
  int get hashCode => Object.hash(phase, failure, torchAvailable, torchOn, cameraCount);
}

/// The camera behind a QR viewfinder: a live preview and the QR codes it
/// reads. A viewfinder makes one through the app's `scannerSourceProvider`,
/// starts it while it is on screen and stops it otherwise.
///
/// The store build's is `MobileScannerSource` (ML Kit on Android, Vision on
/// iOS); the free build's reads frames of the `camera` plugin with a QR
/// decoder in Dart. Widget tests use `FakeScanner` from
/// `test/fakes/fake_scanner.dart`, which needs no camera and lets a test
/// hand the viewfinder a code.
abstract class ScannerSource {
  ValueListenable<ScannerState> get state;

  /// The text of every QR code the camera reads, as often as it reads it.
  Stream<String> get codes;

  /// Turns the camera on, asking for permission the first time. Failures
  /// are reported through [state], never thrown.
  Future<void> start();

  /// Turns the camera off, freeing it for other apps and screens.
  Future<void> stop();

  Future<void> setTorch(bool on);

  /// Moves to the next camera, front or back.
  Future<void> switchCamera();

  /// The live preview, filling the box it is given.
  Widget buildPreview(BuildContext context);

  /// Whether the viewfinder animates; fakes turn it off so `pumpAndSettle` settles.
  bool get animated => true;

  Future<void> dispose();
}

/// Reads the QR code in a picture, as `qrImage.ts` did with jsQR.
abstract interface class QrImageReader {
  /// The text of the first QR code in the picture at [path], or null when there is none.
  Future<String?> decode(String path);
}
