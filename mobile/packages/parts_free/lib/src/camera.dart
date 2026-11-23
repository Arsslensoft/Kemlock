import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

import 'qr_decoder.dart';

/// One of the phone's cameras.
@immutable
class Lens {
  const Lens(this.id, {required this.front, required this.hasTorch});

  final String id;
  final bool front;

  /// Whether it has a light to turn on; the back cameras of phones do.
  final bool hasTorch;
}

/// Why a camera couldn't be listed, opened or used.
class CameraFailure implements Exception {
  const CameraFailure(this.failure);

  final ScannerFailure failure;

  @override
  String toString() => 'CameraFailure(${failure.kind.name}: ${failure.detail})';
}

/// The phone's cameras, as the free build's scanner uses them: a preview, a stream of
/// frames' luminance and the torch. The real one is [PluginCamera]; tests use a fake.
abstract interface class Camera {
  /// The phone's cameras. Throws [CameraFailure].
  Future<List<Lens>> lenses();

  /// Opens [lens], asking for permission the first time, and hands each frame to [onFrame]
  /// until [close]. Throws [CameraFailure].
  Future<void> open(Lens lens, void Function(Luminance frame) onFrame);

  /// Turns the open camera's light on or off. Throws [CameraFailure].
  Future<void> setTorch(bool on);

  /// Closes the camera, freeing it for other apps and screens.
  Future<void> close();

  /// The open camera's picture, filling the box it is given.
  Widget preview();
}

/// [Camera] through Flutter's `camera` plugin (CameraX on Android, AVFoundation on iOS).
class PluginCamera implements Camera {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];

  /// Tells [preview] to rebuild once a camera is open.
  final ValueNotifier<CameraController?> _open = ValueNotifier(null);

  @override
  Future<List<Lens>> lenses() async {
    try {
      _cameras = await availableCameras();
    } on CameraException catch (error) {
      throw CameraFailure(failureOf(error));
    }
    return [
      for (final camera in _cameras)
        Lens(
          camera.name,
          front: camera.lensDirection == CameraLensDirection.front,
          hasTorch: camera.lensDirection == CameraLensDirection.back,
        ),
    ];
  }

  @override
  Future<void> open(Lens lens, void Function(Luminance frame) onFrame) async {
    await close();
    final description = _cameras.firstWhere((camera) => camera.name == lens.id);
    // 1280 by 720 is enough for the densest code the app draws, and quick to decode.
    final controller = CameraController(description, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
    try {
      await controller.initialize();
      await controller.startImageStream((image) => onFrame(luminanceOf(image)));
    } on CameraException catch (error) {
      await controller.dispose();
      throw CameraFailure(failureOf(error));
    }
    _controller = controller;
    _open.value = controller;
  }

  @override
  Future<void> setTorch(bool on) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } on CameraException catch (error) {
      throw CameraFailure(failureOf(error));
    }
  }

  @override
  Future<void> close() async {
    final controller = _controller;
    _controller = null;
    _open.value = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) await controller.stopImageStream();
    } on CameraException {
      // Stopped already.
    }
    await controller.dispose();
  }

  @override
  Widget preview() => ValueListenableBuilder<CameraController?>(
    valueListenable: _open,
    builder: (context, controller, _) {
      final size = controller?.value.previewSize;
      if (controller == null || size == null || !controller.value.isInitialized) {
        return const ColoredBox(color: Color(0xFF000000));
      }
      // The preview's size is the sensor's, landscape; the app is held upright.
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(width: size.height, height: size.width, child: CameraPreview(controller)),
        ),
      );
    },
  );
}

/// The failure a `camera` error means. The plugin names a refused permission
/// `CameraAccessDenied` and its kin on both platforms.
ScannerFailure failureOf(CameraException error) => switch (error.code) {
  'CameraAccessDenied' ||
  'CameraAccessDeniedWithoutPrompt' ||
  'CameraAccessRestricted' ||
  'cameraPermission' => const ScannerFailure(ScannerFailureKind.permissionDenied),
  'cameraNotFound' || 'noCameraAvailable' => const ScannerFailure(ScannerFailureKind.noCamera),
  _ => ScannerFailure(ScannerFailureKind.other, error.description ?? error.code),
};

/// A frame's luminance: the Y plane of YUV 420, its rows packed when the plane pads them.
Luminance luminanceOf(CameraImage image) {
  final plane = image.planes.first;
  final width = image.width;
  final height = image.height;
  final stride = plane.bytesPerRow;
  final bytes = Uint8List(width * height);
  if (stride == width) {
    bytes.setRange(0, width * height, plane.bytes);
  } else {
    for (var y = 0; y < height; y++) {
      bytes.setRange(y * width, (y + 1) * width, plane.bytes, y * stride);
    }
  }
  return Luminance(bytes, width, height);
}
