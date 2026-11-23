import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/two_factor_directory.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/links.dart';

import '../../fakes/fake_clipboard.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

/// An account for [issuer], as the Vitest files made them.
OtpAccount account(String id, String issuer, {String label = '', bool? noBackupCodes}) =>
    OtpAccount(id: id, issuer: issuer, label: label, secret: 'S$id', addedAt: 1, noBackupCodes: noBackupCodes);

/// A service with [codes], the first [used] of them used.
BackupService service(String id, String name, List<String> codes, {int used = 0, String? note, String? spaceId}) => BackupService(
  id: id,
  serviceName: name,
  codes: [for (final (i, code) in codes.indexed) BackupCode(code: code, used: i < used)],
  note: note,
  spaceId: spaceId,
  addedAt: 1,
);

/// The bundled 2FA directory, read straight from the file: the asset
/// bundle decodes a file this big on another isolate, which a widget
/// test's fake clock never lets finish.
final Override realDirectory = twoFactorDirectoryProvider.overrideWith(
  (ref) =>
      TwoFactorDirectory.fromJson(jsonDecode(File('assets/data/two_factor_directory.json').readAsStringSync()) as Map<String, Object?>),
);

/// What the app writes to the clipboard, in order, until the test ends.
List<String?> watchClipboard() {
  final writes = <String?>[];
  answerSensitiveCopies(writes.add);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
    return null;
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return writes;
}

/// The whole app open on the Backup tab, on a vault that holds [services]
/// and [accounts]. The screen is a
/// phone's width and tall enough that no card hides under the tab bar.
Future<TestApp> openBackupTab(
  WidgetTester tester, {
  List<BackupService> services = const [],
  List<OtpAccount> accounts = const [],
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(393, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp();
  await tester.runAsync(() async {
    final session = await app.createVault('pw');
    await app.vaultStore.saveAccounts(accounts, session);
    await app.vaultStore.saveBackupServices(services, session);
  });
  await app.pump(tester, overrides: overrides);
  await app.unlock(tester, 'pw');
  await tester.tap(find.text(t('nav.backup')));
  await tester.pumpAndSettle();
  return app;
}

/// Lets a toast that is up run out, so the next one shows.
Future<void> waitOutToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

/// Stands in for the browser: keeps the links opened.
class FakeLinks implements LinkLauncher {
  final List<Uri> opened = [];

  Override get asOverride => linkLauncherProvider.overrideWithValue(this);

  @override
  Future<bool> launch(Uri url) async {
    opened.add(url);
    return true;
  }
}
