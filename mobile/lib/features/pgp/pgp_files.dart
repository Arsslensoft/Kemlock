/// Where the PGP actions keep files for a moment (openspec:
/// add-pgp-messages): `<temporary directory>/pgp/<random>/<name>`. A
/// decrypted file, and the encrypted copy of a file about to be shared,
/// exist only there, and only until the sheet closes, the job is cancelled
/// or the vault locks. Whatever a killed app left is swept away at the
/// next start, before the first frame. Names in it are the files' own,
/// never the vault's.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../crypto/bytes.dart';

/// The directory every job's own directory is made in. Tests point it at a
/// real directory of their own.
final pgpTempRootProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}pgp'),
);

// These touch a directory or a file or two, and are done with the
// blocking calls: nothing waits on them but what must not go on before
// they are done.

/// A new, empty directory for one job, under [root].
Future<Directory> createPgpJobDirectory(Directory root) async {
  final name = [for (final b in randomBytes(8)) b.toRadixString(16).padLeft(2, '0')].join();
  return Directory('${root.path}${Platform.pathSeparator}$name')..createSync(recursive: true);
}

/// Deletes [directory] and what is in it. A directory that is gone, or
/// that the system will not let go of, is left: the sweep at the next
/// start tries again.
Future<void> deletePgpDirectory(Directory directory) async {
  try {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  } on FileSystemException {
    // The cache is the system's to clear, too
  }
}

/// Deletes the file at [path], such as the copy a picker left in the cache
/// of a file that was about to be encrypted.
Future<void> deletePgpFile(String path) async {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // As above
  }
}

/// Deletes everything the PGP actions left under [root]: called at start,
/// in case the app was killed with a decrypted file waiting to be saved.
Future<void> sweepPgpTemp(Directory root) => deletePgpDirectory(root);

/// [sweepPgpTemp] on the phone's own temporary directory. Never throws: a
/// phone without one just has nothing to sweep.
Future<void> sweepPgpTempAtStart() async {
  try {
    await sweepPgpTemp(Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}pgp'));
  } on Object {
    // No temporary directory to speak of
  }
}
