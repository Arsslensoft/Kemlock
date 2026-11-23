// The free build's QR decoder (openspec: add-fdroid-release, design decision 3): zxing2, a
// port of ZXing to Dart, with two retries ZXing itself doesn't make.
//
// ZXing works out how many modules a code is across from the distance between its finder
// patterns and a module size measured on them. For the densest codes the app draws, the
// version 39 frames of a vault transfer, an error of one percent in that size gives the
// wrong number, and the code is not read; task 1.1 measured ZXing's own reader (and its Java
// original, identically) reading such a frame at about a third of the sizes tried. So when
// the code isn't read, this tries the module counts next to the estimate, and then the frame
// turned a quarter, which puts other finder patterns first: 482 of 492 such frames read.
//
// zxing2 has no public way into its detector's steps, so this uses its implementation
// libraries; pubspec.yaml pins the version they were read from.
// ignore_for_file: implementation_imports

import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';
import 'package:zxing2/src/common/bit_matrix.dart';
import 'package:zxing2/src/common/detector/math_utils.dart';
import 'package:zxing2/src/common/grid_sampler.dart';
import 'package:zxing2/src/common/perspective_transform.dart';
import 'package:zxing2/src/qrcode/decoder/decoder.dart';
import 'package:zxing2/src/qrcode/decoder/version.dart';
import 'package:zxing2/src/qrcode/detector/alignment_pattern.dart';
import 'package:zxing2/src/qrcode/detector/detector.dart';
import 'package:zxing2/src/qrcode/detector/finder_pattern.dart';
import 'package:zxing2/src/qrcode/detector/finder_pattern_finder.dart';

/// A picture's brightness, one byte a pixel, rows of [width] bytes: a camera frame's
/// luminance plane, or a decoded picture's.
class Luminance {
  Luminance(this.bytes, this.width, this.height) : assert(bytes.length >= width * height);

  final Uint8List bytes;
  final int width;
  final int height;

  /// The same picture turned a quarter, counter-clockwise.
  Luminance turned() {
    final out = Uint8List(width * height);
    for (var y = 0; y < width; y++) {
      final row = y * height;
      for (var x = 0; x < height; x++) {
        out[row + x] = bytes[x * width + (width - 1 - y)];
      }
    }
    return Luminance(out, height, width);
  }
}

/// The text of the QR code in [picture], or null when none is read.
String? decodeQr(Luminance picture) => _decodeOnce(picture) ?? _decodeOnce(picture.turned());

String? _decodeOnce(Luminance picture) {
  try {
    final bits = BinaryBitmap(HybridBinarizer(_Source(picture))).getBlackMatrix();
    final hints = DecodeHints();
    final info = FinderPatternFinder(bits).find(hints);
    final detector = Detector(bits);
    for (final dimension in _dimensions(detector, info.topLeft, info.topRight, info.bottomLeft)) {
      final text = _read(bits, detector, hints, info.topLeft, info.topRight, info.bottomLeft, dimension);
      if (text != null && text.isNotEmpty) return text;
    }
  } on ReaderException {
    // No finder patterns, so no code.
  } on ArgumentError {
    // A pattern found too near the edge to sample around.
  }
  return null;
}

/// The module counts to try, nearest the estimate first. Every QR code is 4v + 17 modules
/// across for its version v, from 21 to 177.
List<int> _dimensions(Detector detector, FinderPattern tl, FinderPattern tr, FinderPattern bl) {
  final moduleSize = detector.calculateModuleSize(tl, tr, bl);
  if (moduleSize < 1) return const [];
  double across(double size) =>
      (MathUtils.round(ResultPoint.distance(tl, tr) / size) + MathUtils.round(ResultPoint.distance(tl, bl) / size)) / 2 + 7;
  int nearest(double modules) => ((modules - 17) / 4).round() * 4 + 17;
  final byRuns = nearest(across(moduleSize));
  // The size the finder patterns measured on themselves, a second estimate.
  final byFinders = nearest(across((tl.estimatedModuleSize + tr.estimatedModuleSize + bl.estimatedModuleSize) / 3));
  return {
    byRuns,
    byFinders,
    byRuns - 4,
    byRuns + 4,
    byFinders - 4,
    byFinders + 4,
    byRuns - 8,
    byRuns + 8,
  }.where((d) => d >= 21 && d <= 177).toList();
}

/// The code read as [dimension] modules across, or null when it doesn't decode so.
String? _read(BitMatrix bits, Detector detector, DecodeHints hints, ResultPoint tl, ResultPoint tr, ResultPoint bl, int dimension) {
  final Version version;
  try {
    version = Version.getProvisionalVersionForDimension(dimension);
  } on ReaderException {
    return null;
  }
  final moduleSize = detector.calculateModuleSize(tl, tr, bl);
  AlignmentPattern? alignment;
  if (version.alignmentPatternCenters.isNotEmpty) {
    // Where a bottom-right finder pattern would be, three modules in, as ZXing guesses it.
    final correction = 1.0 - 3.0 / (version.dimensionForVersion - 7);
    final x = (tl.x + correction * (tr.x - tl.x + bl.x - tl.x)).toInt();
    final y = (tl.y + correction * (tr.y - tl.y + bl.y - tl.y)).toInt();
    for (var allowance = 4; allowance <= 16; allowance <<= 1) {
      try {
        alignment = detector.findAlignmentInRegion(moduleSize, x, y, allowance.toDouble());
        break;
      } on ReaderException {
        // A wider look.
      }
    }
  }
  final far = dimension - 3.5;
  final transform = alignment != null
      ? PerspectiveTransform.quadrilateralToQuadrilateral(
          3.5,
          3.5,
          far,
          3.5,
          far - 3,
          far - 3,
          3.5,
          far,
          tl.x,
          tl.y,
          tr.x,
          tr.y,
          alignment.x,
          alignment.y,
          bl.x,
          bl.y,
        )
      : PerspectiveTransform.quadrilateralToQuadrilateral(
          3.5,
          3.5,
          far,
          3.5,
          far,
          far,
          3.5,
          far,
          tl.x,
          tl.y,
          tr.x,
          tr.y,
          tr.x - tl.x + bl.x,
          tr.y - tl.y + bl.y,
          bl.x,
          bl.y,
        );
  try {
    final grid = GridSampler.gridSampler.sampleGridTransform(bits, dimension, dimension, transform);
    return Decoder().decode(grid, hints: hints).text;
  } on ReaderException {
    return null;
  }
}

/// [Luminance] as zxing2 reads it.
class _Source extends LuminanceSource {
  _Source(Luminance picture)
    : _bytes = Int8List.view(picture.bytes.buffer, picture.bytes.offsetInBytes),
      super(picture.width, picture.height);

  final Int8List _bytes;

  @override
  Int8List getRow(int y, Int8List? row) {
    final out = row == null || row.length < width ? Int8List(width) : row;
    out.setRange(0, width, _bytes, y * width);
    return out;
  }

  @override
  Int8List getMatrix() => width * height == _bytes.length ? _bytes : Int8List.sublistView(_bytes, 0, width * height);
}
