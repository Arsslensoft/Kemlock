import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The F-Droid listing, in the repo's root (openspec: add-fdroid-release, design decision 11).
const _listing = '../fastlane/metadata/android';

const _locales = ['en-US', 'fr-FR'];

/// The files of [locale]'s listing, as paths from it.
List<String> filesOf(String locale) {
  final root = Directory('$_listing/$locale');
  return [
    for (final file in root.listSync(recursive: true).whereType<File>()) file.path.replaceAll(r'\', '/').substring(root.path.length + 1),
  ]..sort();
}

String _read(String locale, String file) => File('$_listing/$locale/$file').readAsStringSync().trimRight();

/// The version codes of the APKs `flutter build apk --split-per-abi` makes of pubspec.yaml's
/// version: a thousand per processor type (armeabi-v7a 1, arm64-v8a 2, x86_64 4) and the
/// build number.
List<int> versionCodes() {
  final version = RegExp(r'^version: *\S+\+(\d+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!;
  final build = int.parse(version[1]!);
  return [
    for (final abi in [1, 2, 4]) abi * 1000 + build,
  ];
}

void main() {
  test('every locale holds the same files', () {
    expect(filesOf('fr-FR'), filesOf('en-US'));
    expect(filesOf('en-US'), containsAll(['title.txt', 'short_description.txt', 'full_description.txt']));
  });

  test('the texts fit F-Droid: a title of 50 characters, a summary of 80 and a description of 4000', () {
    for (final locale in _locales) {
      expect(_read(locale, 'title.txt'), 'Kemlock');
      expect(_read(locale, 'short_description.txt').length, lessThanOrEqualTo(80), reason: locale);
      expect(_read(locale, 'short_description.txt'), isNot(contains('\n')), reason: locale);
      expect(_read(locale, 'full_description.txt').length, lessThanOrEqualTo(4000), reason: locale);
    }
  });

  test('each change note is 500 characters or fewer', () {
    for (final locale in _locales) {
      for (final file in filesOf(locale).where((file) => file.startsWith('changelogs/'))) {
        expect(_read(locale, file).length, lessThanOrEqualTo(500), reason: '$locale/$file');
      }
    }
  });

  test('every version code of pubspec.yaml has a change note in every locale', () {
    for (final locale in _locales) {
      for (final code in versionCodes()) {
        expect(File('$_listing/$locale/changelogs/$code.txt').existsSync(), isTrue, reason: '$locale $code');
      }
    }
  });

  test('the description says what goes over the network, and names the service that is not free software', () {
    final description = _read('en-US', 'full_description.txt');
    expect(description, contains('Have I Been Pwned'));
    expect(description, contains('not free'));
    expect(description, contains('encrypted export'));
  });
}
