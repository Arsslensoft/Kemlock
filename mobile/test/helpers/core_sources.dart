import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The folder that holds the kemlock_core package's libraries, read from `.dart_tool/package_config.json`
/// (flutter test can't resolve a package URI itself): the Kemlock-core checkout pub fetched, or a local one an
/// override points at.
final String coreLib = () {
  final configFile = File(p.join('.dart_tool', 'package_config.json'));
  final config = jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  final package = (config['packages']! as List<Object?>).cast<Map<String, Object?>>().singleWhere((e) => e['name'] == 'kemlock_core');
  final rootUri = package['rootUri']! as String;
  final root = configFile.absolute.uri.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
  final packageUri = (package['packageUri'] as String?) ?? 'lib/';
  return p.normalize(root.resolve(packageUri.endsWith('/') ? packageUri : '$packageUri/').toFilePath());
}();

/// The kemlock_core file that a path under the app's `lib/` names, now that the file moved there and the
/// app's own file only exports it: `lib/crypto/keys/pgp.dart` is `<core>/crypto/keys/pgp.dart`.
String inCore(String libPath) => p.join(coreLib, p.joinAll(p.split(libPath).skip(1)));

/// The app's folder under `lib/` and the core's folder of the same name, those that exist.
List<Directory> appAndCore(String libDirectory) =>
    [Directory(libDirectory), Directory(inCore(libDirectory))].where((d) => d.existsSync()).toList();
