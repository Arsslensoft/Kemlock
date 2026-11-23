// Switches this checkout of mobile/ to the free build, as tool/build/use_free.sh does, where
// there is no bash (openspec: add-fdroid-release, design decision 2):
//
//     dart run tool/build/use_free.dart
//     flutter pub get --enforce-lockfile
//
// To go back to the store build: delete pubspec_overrides.yaml and `git checkout pubspec.lock`.
import 'dart:io';

/// What use_free.sh writes, byte for byte.
const overrides = '''
# Written by tool/build/use_free.sh: the free build's parts, in place of the
# store build's (openspec: add-fdroid-release). Not in git.
dependency_overrides:
  kemlock_parts:
    path: packages/parts_free
''';

void main() {
  final mobile = File.fromUri(Platform.script).parent.parent.parent;
  File('${mobile.path}/pubspec_overrides.yaml').writeAsStringSync(overrides);
  File('${mobile.path}/pubspec.free.lock').copySync('${mobile.path}/pubspec.lock');
  stdout.writeln('Switched to the free build; now run: flutter pub get --enforce-lockfile');
}
