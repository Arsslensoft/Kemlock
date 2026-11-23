/// The plain copies that picking and sharing a file leave in the phone's
/// cache, and their removal.
///
/// The phone's pickers hand the app a copy of what the person chose: the
/// file picker under `<cache>/file_picker/` on Android and in the temporary
/// directory on iOS, the photo picker and the camera under the cache or the
/// temporary directory. What is picked is often a secret before it is one of
/// the vault's: another app's unencrypted export, a key file, a screenshot
/// of a QR code, a photo of backup codes, a file about to be attached to a
/// note. Nothing else deletes those copies, so the app does, as soon as it
/// has read them.
///
/// What that misses is swept ([sweepPhoneScratch]) when the app starts and
/// whenever a vault locks, is deleted or is erased: a copy whose reading
/// was cut short, the copy Android's share sheet keeps of the last file
/// shared (`<cache>/share_plus/`), an export archive a killed app left
/// (`<cache>/export/`), and the file a Credential Exchange transfer from another
/// app on the phone moved its data through (`<cache>/import_export_temp/`).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The directories the pickers put their copies in: the app's cache, and
/// the system's temporary directory, which on iOS is another one. Both are
/// the app's own on a phone. Anywhere else (a test, a desktop) there are
/// none: a path a picker gives there is the person's own file.
Future<List<Directory>> scratchRoots() async {
  if (!Platform.isAndroid && !Platform.isIOS) return const [];
  final roots = <Directory>[Directory.systemTemp];
  try {
    roots.add(await getTemporaryDirectory());
  } on Object {
    // No cache directory to speak of
  }
  return roots;
}

/// Deletes the copy a picker left at [path], and the folder the picker made
/// for it when that is left empty, if it lies under one of [roots]. A file
/// anywhere else is left alone, and so is a root itself. Never throws: what
/// can't be deleted now is left for the sweep at the next lock or start.
void deletePickedCopy(String? path, List<Directory> roots) {
  if (path == null || path.isEmpty) return;
  try {
    final file = File(path);
    if (!file.existsSync()) return;
    // Resolved, as iOS names its directories through a link (/var and /private/var)
    final real = file.resolveSymbolicLinksSync();
    for (final root in roots) {
      if (!root.existsSync()) continue;
      final base = root.resolveSymbolicLinksSync();
      if (!p.isWithin(base, real)) continue;
      File(real).deleteSync();
      final folder = Directory(p.dirname(real));
      if (p.isWithin(base, folder.path) && folder.listSync().isEmpty) folder.deleteSync();
      return;
    }
  } on FileSystemException {
    // Swept later
  }
}

/// The folders under a scratch root that hold only plain copies: an export
/// archive on its way out, what Android's share sheet copied of the last
/// file shared, what Android's file picker copied, and what Android's
/// Credential Exchange transfer made of another app's export
/// (`import_export_temp`, the folder the providerevents library writes to, for an
/// export to another app as for an import;
/// `android/.../TransferFiles.kt` deletes it when the answer is in).
const scratchFolders = {'export', 'share_plus', 'file_picker', 'import_export_temp'};

// A random UUID, which the photo picker and the camera name their copies by:
// a folder `<uuid>/` on Android (and the file picker's on iOS), a file
// `<uuid><digits>.jpg` for a photo just taken.
final _uuid = RegExp('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');

/// Whether [entry], directly under a scratch root, is a plain copy picking,
/// sharing or exporting left: one of [scratchFolders], a folder named by a
/// UUID, or a file whose name starts with a UUID or with `image_picker`
/// (the photo picker's on iOS).
bool isScratchEntry(FileSystemEntity entry) {
  final name = p.basename(entry.path);
  if (entry is Directory) return scratchFolders.contains(name) || (_uuid.hasMatch(name) && name.length == 36);
  return entry is File && (_uuid.hasMatch(name) || name.startsWith('image_picker'));
}

/// Deletes the plain copies ([isScratchEntry]) directly under each of
/// [roots]. Everything else in a cache stays: the shared item that waits
/// (`share/`) and the PGP actions' files (`pgp/`) have sweeps of their own.
/// Never throws: what can't be deleted now is tried again at the next sweep.
void sweepScratch(List<Directory> roots) {
  for (final root in roots) {
    try {
      if (!root.existsSync()) continue;
      for (final entry in root.listSync(followLinks: false)) {
        if (!isScratchEntry(entry)) continue;
        try {
          entry.deleteSync(recursive: true);
        } on FileSystemException {
          // Tried again at the next sweep
        }
      }
    } on FileSystemException {
      // A root that can't be listed has nothing of ours to delete
    }
  }
}

/// [sweepScratch] on this phone, after asking the file picker to delete
/// what it copied (on iOS that empties the app's temporary directory).
/// Nothing off a phone, where there is no cache of the app's own. Never
/// throws.
Future<void> sweepPhoneScratch() async {
  final roots = await scratchRoots();
  if (roots.isEmpty) return;
  try {
    await FilePicker.clearTemporaryFiles();
  } on Object {
    // No picker to ask: the sweep below takes what it knows
  }
  sweepScratch(roots);
}
