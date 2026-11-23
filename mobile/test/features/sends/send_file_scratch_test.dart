// A received file is saved or shared through one file under `<temporary>/share/<random>/`, which the share step
// deletes when its sheet closes. A killed app leaves that one copy; the sweep that runs at start and when the app
// comes back to the front (PendingShare.sweep, over sweepSharedFiles) takes it once it is as old as a shared item may
// wait, and leaves a younger one, which a sheet may still be working on.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/shared_items.dart';

void main() {
  test('a copy a killed app left under share/<random>/ is swept at start, and the folder with it', () {
    final root = Directory.systemTemp.createTempSync('send-scratch');
    addTearDown(() => root.deleteSync(recursive: true));
    final folder = Directory('${root.path}${Platform.pathSeparator}share${Platform.pathSeparator}0a1b2c3d4e5f6071')
      ..createSync(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}scan.pdf')..writeAsBytesSync([1, 2, 3]);
    final share = Directory('${root.path}${Platform.pathSeparator}share');

    // Just written: left alone, as a sheet may still be working on it
    sweepSharedFiles(share, DateTime.now());
    expect(file.existsSync(), isTrue);

    // Older than a shared item may wait: gone, and its folder
    sweepSharedFiles(share, DateTime.now().add(sharedItemLife + const Duration(minutes: 1)));
    expect(file.existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
    expect(share.listSync(), isEmpty);
  });

  test('deleteSharedFile removes the file and its folder when it is left empty', () {
    final root = Directory.systemTemp.createTempSync('send-scratch');
    addTearDown(() => root.deleteSync(recursive: true));
    final folder = Directory('${root.path}${Platform.pathSeparator}abc')..createSync();
    final file = File('${folder.path}${Platform.pathSeparator}scan.pdf')..writeAsBytesSync([1]);

    deleteSharedFile(file.path);

    expect(file.existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
  });
}
