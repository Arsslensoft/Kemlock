import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/app_shell.dart';
import 'package:kemlock/platform/shared_items.dart';

import '../../fakes/fake_shared_items.dart';
import '../pgp/pgp_kit.dart';

/// The app of [PgpApp], and what other apps share to it: [shared] hands items over, and shared files are
/// copied into [shareRoot] as the native side copies them.
class ShareApp extends PgpApp {
  ShareApp(super.tester);

  final shared = FakeSharedItems();
  late Directory shareRoot;

  @override
  List<Override> get overrides => [...super.overrides, shared.asOverride, shareTempRootProvider.overrideWithValue(() async => shareRoot)];

  @override
  Future<void> start({List<String> keys = const []}) async {
    shareRoot = Directory.systemTemp.createTempSync('share-ui-test');
    addTearDown(() {
      if (shareRoot.existsSync()) shareRoot.deleteSync(recursive: true);
    });
    await super.start(keys: keys);
  }

  var _copies = 0;

  /// A file another app shared as [name], copied as the native side does.
  SharedFile copied(String name, List<int> bytes) {
    final directory = Directory('${shareRoot.path}${Platform.pathSeparator}copy${_copies++}')..createSync(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$name')..writeAsBytesSync(bytes);
    return SharedFile(path: file.path, name: name, size: bytes.length);
  }

  /// Another app shares [arrival], and the app settles.
  Future<void> share(SharedArrival arrival) async {
    shared.send(arrival);
    await settle();
  }

  PendingShare get pending => app.container.read(pendingShareProvider.notifier);

  SharedItem? get waiting => app.container.read(pendingShareProvider);

  /// The open vault's shell, to open a sheet from.
  BuildContext get shell => tester.element(find.byType(AppShell));
}
