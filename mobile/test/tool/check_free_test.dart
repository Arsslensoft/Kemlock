import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/release/check_free.dart';

/// A DEX file that defines [classes], given as type descriptors: the header, the string,
/// type and class tables, and the strings, which is all [definedClasses] reads.
Uint8List dexOf(List<String> classes) {
  final n = classes.length;
  const stringIds = 0x70;
  final typeIds = stringIds + 4 * n;
  final classDefs = typeIds + 4 * n;
  final strings = BytesBuilder();
  final stringOffsets = <int>[];
  for (final descriptor in classes) {
    stringOffsets.add(classDefs + 32 * n + strings.length);
    final bytes = utf8.encode(descriptor);
    strings
      ..addByte(bytes.length) // ULEB128 of a length under 128
      ..add(bytes)
      ..addByte(0);
  }
  final dex = ByteData(classDefs + 32 * n + strings.length);
  final out = dex.buffer.asUint8List();
  out.setRange(0, 8, ascii.encode('dex\n035\x00'));
  void u32(int offset, int value) => dex.setUint32(offset, value, Endian.little);
  u32(0x20, out.length);
  u32(0x24, 0x70);
  u32(0x38, n);
  u32(0x3C, stringIds);
  u32(0x40, n);
  u32(0x44, typeIds);
  u32(0x60, n);
  u32(0x64, classDefs);
  for (var i = 0; i < n; i++) {
    u32(stringIds + 4 * i, stringOffsets[i]);
    u32(typeIds + 4 * i, i);
    u32(classDefs + 32 * i, i);
  }
  out.setRange(classDefs + 32 * n, out.length, strings.takeBytes());
  return out;
}

/// An APK holding [classes] in its DEX and [libraries] under lib/arm64-v8a/.
Uint8List apkOf({List<String> classes = const [], List<String> libraries = const ['libflutter.so', 'libapp.so']}) {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('AndroidManifest.xml', Uint8List(8)))
    ..addFile(
      ArchiveFile.bytes('classes.dex', dexOf(['Lcom/kemlock/app/MainActivity;', 'Landroidx/core/app/ActivityCompat;', ...classes])),
    );
  for (final library in libraries) {
    archive.addFile(ArchiveFile.bytes('lib/arm64-v8a/$library', Uint8List(16)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('reads the classes a DEX file defines', () {
    expect(definedClasses(dexOf(['La/B;', 'Lc/d/E;'])), ['La/B;', 'Lc/d/E;']);
    expect(() => definedClasses(Uint8List(200)), throwsFormatException);
  });

  test('passes an APK of free software: the app, AndroidX, Flutter and the jni bridge', () {
    expect(problemsOf(apkOf(libraries: ['libflutter.so', 'libapp.so', 'libdartjni.so'])), isEmpty);
  });

  test('names each closed package an APK holds classes of', () {
    final problems = problemsOf(
      apkOf(
        classes: [
          'Lcom/google/mlkit/vision/barcode/BarcodeScanning;',
          'Lcom/google/mlkit/vision/text/TextRecognition;',
          'Lcom/google/android/gms/tasks/Task;',
          'Lcom/android/billingclient/api/BillingClient;',
          'Lcom/amazon/device/iap/PurchasingService;',
        ],
      ),
    );

    expect(problems, [
      '2 classes of com.google.mlkit (Google ML Kit)',
      '1 classes of com.google.android.gms (Google Play services)',
      '1 classes of com.android.billingclient (Google Play Billing)',
      '1 classes of com.amazon (Amazon Appstore)',
    ]);
  });

  test('does not mistake a package that only starts alike', () {
    expect(problemsOf(apkOf(classes: ['Lcom/amazonian/Thing;', 'Lcom/google/android/gmsx/Other;'])), isEmpty);
  });

  test('names a native library nobody here built', () {
    expect(problemsOf(apkOf(libraries: ['libflutter.so', 'libapp.so', 'libpdfium.so'])), [
      'native library lib/arm64-v8a/libpdfium.so, not built from source by this build',
    ]);
  });
}
