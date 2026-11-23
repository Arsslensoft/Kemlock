// Checks that APKs of the free build hold only free software (openspec: add-fdroid-release,
// design decision 9): no class of Google's ML Kit or Play services, of Google Play Billing,
// or of Amazon's store, and no native library but those the build makes or
// Flutter ships. build.sh runs it on every release, and the checks run it on the free build.
//
//     dart run tool/release/check_free.dart build/app/outputs/flutter-apk/*.apk
//
// It exits non-zero, naming each class package and library it found, when one is there.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The packages whose classes a free build must not hold, as DEX type descriptors begin.
const closedPackages = {
  'com.google.mlkit': 'Google ML Kit',
  'com.google.android.gms': 'Google Play services',
  'com.android.billingclient': 'Google Play Billing',
  'com.amazon': 'Amazon Appstore',
};

/// The native libraries a free build may hold, each free software from a source F-Droid
/// accepts. Anything else is a prebuilt binary nobody has vouched for, and fails the check.
const allowedLibraries = {
  // Flutter's engine, which F-Droid takes prebuilt from the Flutter SDK, and its Vulkan
  // validation layer, in debug builds only
  'libflutter.so',
  'libVkLayer_khronos_validation.so',
  // The app's own Dart, compiled by this build
  'libapp.so',
  // The jni package's bridge (path_provider_android), compiled from its source by this build
  'libdartjni.so',
  // AndroidX, from Google's Maven, built from AOSP's source: DataStore (shared_preferences)
  // and CameraX (the free build's camera)
  'libdatastore_shared_counter.so',
  'libimage_processing_util_jni.so',
  'libsurface_util_jni.so',
};

/// What [apk] holds that a free build must not: a line per closed package with how many of
/// its classes are there, and a line per native library off [allowedLibraries].
List<String> problemsOf(Uint8List apk) {
  final archive = ZipDecoder().decodeBytes(apk);
  final problems = <String>[];
  final found = <String, int>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    if (RegExp(r'^classes\d*\.dex$').hasMatch(name)) {
      for (final descriptor in definedClasses(file.content)) {
        for (final package in closedPackages.keys) {
          if (descriptor.startsWith('L${package.replaceAll('.', '/')}/')) found[package] = (found[package] ?? 0) + 1;
        }
      }
    } else if (name.endsWith('.so') && !allowedLibraries.contains(name.split('/').last)) {
      problems.add('native library $name, not built from source by this build');
    }
  }
  for (final MapEntry(key: package, value: count) in found.entries) {
    problems.add('$count classes of $package (${closedPackages[package]})');
  }
  return problems;
}

/// The type descriptors of the classes [dex] defines, such as `Lcom/kemlock/app/MainActivity;`.
/// Throws [FormatException] for a file that is not DEX.
List<String> definedClasses(Uint8List dex) {
  if (dex.length < 0x70 || String.fromCharCodes(dex, 0, 4) != 'dex\n') throw const FormatException('not a DEX file');
  final data = ByteData.sublistView(dex);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  final stringIds = u32(0x3C);
  final typeIds = u32(0x44);
  final classDefsSize = u32(0x60);
  final classDefs = u32(0x64);

  String stringAt(int index) {
    var offset = u32(stringIds + index * 4);
    // The length in UTF-16 units, as a ULEB128, then the MUTF-8 bytes up to a zero
    while (dex[offset] & 0x80 != 0) {
      offset++;
    }
    offset++;
    final end = dex.indexOf(0, offset);
    return String.fromCharCodes(dex, offset, end);
  }

  return [for (var i = 0; i < classDefsSize; i++) stringAt(u32(typeIds + u32(classDefs + i * 32) * 4))];
}

void main(List<String> paths) {
  if (paths.isEmpty) {
    stderr.writeln('usage: dart run tool/release/check_free.dart <apk>...');
    exit(2);
  }
  var failed = false;
  for (final path in paths) {
    final problems = problemsOf(File(path).readAsBytesSync());
    if (problems.isEmpty) {
      stdout.writeln('$path: free software only');
    } else {
      failed = true;
      stdout.writeln('$path: NOT the free build:');
      for (final problem in problems) {
        stdout.writeln('  $problem');
      }
    }
  }
  if (failed) exit(1);
}
