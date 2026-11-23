import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One package of a pub lockfile: its version and, for a hosted one, its hash.
typedef Locked = ({String version, String? sha256, String source});

/// The packages of a lockfile's [text], by name. A pub lockfile is YAML of a fixed shape,
/// two spaces a level, which this reads line by line.
Map<String, Locked> readLockfile(String text) {
  final packages = <String, Locked>{};
  String? name;
  String? version;
  String? sha256;
  String? source;
  void flush() {
    final done = name;
    if (done != null) packages[done] = (version: version ?? '', sha256: sha256, source: source ?? '');
    name = version = sha256 = source = null;
  }

  var inPackages = false;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line == 'packages:') {
      inPackages = true;
      continue;
    }
    if (!inPackages) continue;
    if (line.isNotEmpty && !line.startsWith(' ')) break;
    final package = RegExp(r'^  ([a-z0-9_]+):$').firstMatch(line);
    if (package != null) {
      flush();
      name = package[1];
      continue;
    }
    String? value(String key) => RegExp('^\\s+$key: "?([^"]*)"?\$').firstMatch(line)?[1];
    version = value('version') ?? version;
    sha256 = value('sha256') ?? sha256;
    source = value('source') ?? source;
  }
  flush();
  return packages;
}

/// What the free build must not hold: the closed packages and what only they bring in
/// (openspec: add-fdroid-release, design decision 1). The credential transfer plugin is one of them: it
/// holds the providerevents libraries, one of which brings Google Play services.
const _notFree = [
  'mobile_scanner',
  'google_mlkit_text_recognition',
  'google_mlkit_commons',
  'pdfrx',
  'pdfrx_engine',
  'pdfium_dart',
  'pdfium_flutter',
  'credential_transfer',
];

/// The store build's lockfile: pubspec.lock, or, in a checkout use_free.sh switched to the
/// free build, the one committed.
String storeLockfile() {
  if (!File('pubspec_overrides.yaml').existsSync()) return File('pubspec.lock').readAsStringSync();
  final committed = Process.runSync('git', ['show', 'HEAD:./pubspec.lock']);
  if (committed.exitCode != 0) throw StateError('git show HEAD:./pubspec.lock failed: ${committed.stderr}');
  return committed.stdout as String;
}

void main() {
  final storeText = storeLockfile();
  final freeText = File('pubspec.free.lock').readAsStringSync();
  final store = readLockfile(storeText);
  final free = readLockfile(freeText);

  test('reads both lockfiles', () {
    expect(store, contains('flutter_riverpod'));
    expect(free, contains('flutter_riverpod'));
  });

  test('every package in both builds is the same version, with the same hash', () {
    final differ = [
      for (final name in store.keys.where(free.containsKey))
        if (name != 'kemlock_parts' && (store[name]!.version != free[name]!.version || store[name]!.sha256 != free[name]!.sha256))
          '$name: ${store[name]} and ${free[name]}',
    ];

    expect(differ, isEmpty);
  });

  test('the free build holds none of the closed packages, nor what they bring in', () {
    expect(free.keys.where(_notFree.contains), isEmpty);
  });

  test('the store build holds the credential transfer plugin, from its own folder', () {
    expect(store['credential_transfer']?.source, 'path');
    expect(storeText, contains('path: "packages/credential_transfer"'));
  });

  test('each build points kemlock_parts at its own parts', () {
    expect(store['kemlock_parts']?.source, 'path');
    expect(storeText, contains('path: "packages/parts_store"'));
    expect(freeText, contains('path: "packages/parts_free"'));
  });
}
