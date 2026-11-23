import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The failure a `mobile_scanner` error means.
ScannerFailure scannerFailureOf(MobileScannerException error) => switch (error.errorCode) {
  MobileScannerErrorCode.permissionDenied => const ScannerFailure(ScannerFailureKind.permissionDenied),
  MobileScannerErrorCode.unsupported => const ScannerFailure(ScannerFailureKind.noCamera),
  _ => ScannerFailure(ScannerFailureKind.other, error.errorDetails?.message),
};

/// The phone's camera through `mobile_scanner`, reading QR codes only.
class MobileScannerSource extends ScannerSource {
  MobileScannerSource()
    : _controller = MobileScannerController(autoStart: false, formats: const [BarcodeFormat.qrCode], detectionTimeoutMs: 200) {
    _controller.addListener(_sync);
    _subscription = _controller.barcodes.listen(_onCapture, onError: (Object _) {});
  }

  final MobileScannerController _controller;
  final ValueNotifier<ScannerState> _state = ValueNotifier(const ScannerState());
  final StreamController<String> _codes = StreamController.broadcast();
  late final StreamSubscription<BarcodeCapture> _subscription;
  bool _disposed = false;

  @override
  ValueListenable<ScannerState> get state => _state;

  @override
  Stream<String> get codes => _codes.stream;

  void _sync() {
    if (_disposed) return;
    final value = _controller.value;
    final error = value.error;
    final ScannerPhase phase;
    if (error != null) {
      phase = ScannerPhase.failed;
    } else if (value.isRunning) {
      phase = ScannerPhase.live;
    } else if (value.isStarting || _state.value.phase == ScannerPhase.starting) {
      // Still on its way up: start marks the source starting before the controller does.
      phase = ScannerPhase.starting;
    } else {
      phase = ScannerPhase.stopped;
    }
    _state.value = ScannerState(
      phase: phase,
      failure: error == null ? null : scannerFailureOf(error),
      torchAvailable: value.torchState != TorchState.unavailable,
      torchOn: value.torchState == TorchState.on,
      cameraCount: value.availableCameras ?? 1,
    );
  }

  void _onCapture(BarcodeCapture capture) {
    final value = capture.barcodes.map((b) => b.rawValue).nonNulls.where((v) => v.isNotEmpty).firstOrNull;
    if (value != null && !_disposed) _codes.add(value);
  }

  @override
  Future<void> start() async {
    if (_disposed) return;
    _state.value = _state.value.copyWith(phase: ScannerPhase.starting);
    try {
      await _controller.start();
    } on MobileScannerException catch (error) {
      if (error.errorCode == MobileScannerErrorCode.controllerAlreadyInitialized ||
          error.errorCode == MobileScannerErrorCode.controllerInitializing) {
        return;
      }
      if (!_disposed) _state.value = ScannerState(phase: ScannerPhase.failed, failure: scannerFailureOf(error));
    } catch (error) {
      if (!_disposed) _state.value = ScannerState(phase: ScannerPhase.failed, failure: ScannerFailure(ScannerFailureKind.other, '$error'));
    }
    _sync();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _controller.stop();
    } catch (_) {
      // Already stopped.
    }
    if (!_disposed) _state.value = _state.value.copyWith(phase: ScannerPhase.stopped, torchOn: false);
  }

  @override
  Future<void> setTorch(bool on) async {
    if (_disposed || !_state.value.torchAvailable || _state.value.torchOn == on) return;
    try {
      await _controller.toggleTorch();
    } catch (_) {
      // A torch that won't switch just stays as it is.
    }
  }

  @override
  Future<void> switchCamera() async {
    if (_disposed) return;
    try {
      await _controller.switchCamera();
    } catch (_) {
      // Stays on the camera it has.
    }
  }

  @override
  Widget buildPreview(BuildContext context) => MobileScanner(
    controller: _controller,
    fit: BoxFit.cover,
    useAppLifecycleState: false,
    placeholderBuilder: (_) => const ColoredBox(color: Color(0xFF000000)),
    // The viewfinder explains failures; the preview stays black underneath.
    errorBuilder: (_, _) => const ColoredBox(color: Color(0xFF000000)),
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_sync);
    await _subscription.cancel();
    await _codes.close();
    _state.dispose();
    await _controller.dispose();
  }
}

/// [QrImageReader] through `mobile_scanner`'s still-image analysis.
class MobileScannerImageReader implements QrImageReader {
  @override
  Future<String?> decode(String path) async {
    final controller = MobileScannerController(autoStart: false, formats: const [BarcodeFormat.qrCode]);
    try {
      final capture = await controller.analyzeImage(path, formats: const [BarcodeFormat.qrCode]);
      return capture?.barcodes.map((b) => b.rawValue).nonNulls.where((v) => v.isNotEmpty).firstOrNull;
    } catch (_) {
      return null;
    } finally {
      await controller.dispose();
    }
  }
}
