import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:kemlock_ports/kemlock_ports.dart';

import 'qr_decoder.dart';

/// [QrImageReader] with the free build's decoder (openspec: add-fdroid-release, design
/// decision 3): the picture is decoded by the phone's own image codecs, at most [maxSide]
/// pixels on its longer side, and its QR code read on a background isolate.
class DecoderImageReader implements QrImageReader {
  const DecoderImageReader({this.maxSide = 2048});

  /// A screenshot is at most this big already; a photo is scaled down to it, which keeps a
  /// code that fills a fair part of it readable.
  final int maxSide;

  @override
  Future<String?> decode(String path) async {
    try {
      final picture = await luminanceOfPicture(await File(path).readAsBytes(), maxSide: maxSide);
      if (picture == null) return null;
      return await Isolate.run(() => decodeQr(picture));
    } catch (_) {
      // Not a picture the codecs read, or gone.
      return null;
    }
  }
}

/// The luminance of the encoded picture in [bytes], scaled to at most [maxSide] on its
/// longer side, or null when it isn't a picture.
Future<Luminance?> luminanceOfPicture(Uint8List bytes, {int maxSide = 2048}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final longer = max(descriptor.width, descriptor.height);
  final scale = longer > maxSide ? maxSide / longer : 1.0;
  final codec = await descriptor.instantiateCodec(
    targetWidth: (descriptor.width * scale).round(),
    targetHeight: (descriptor.height * scale).round(),
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    final pixels = rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
    final luminance = Uint8List(image.width * image.height);
    for (var i = 0, p = 0; i < luminance.length; i++, p += 4) {
      // Transparent pixels are shown on white, as a screenshot's background is.
      final alpha = pixels[p + 3];
      final y = (299 * pixels[p] + 587 * pixels[p + 1] + 114 * pixels[p + 2]) ~/ 1000;
      luminance[i] = (y * alpha + 255 * (255 - alpha)) ~/ 255;
    }
    return Luminance(luminance, image.width, image.height);
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
