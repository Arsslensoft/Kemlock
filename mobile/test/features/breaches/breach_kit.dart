/// What the breach tests share: the list made from Have I Been Pwned's own answer, and a
/// vault holding entries, open in the whole app.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/breaches/breach_list.dart';
import 'package:kemlock/features/breaches/breach_providers.dart';
import 'package:kemlock/features/settings/app_version.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/router.dart';

import '../../helpers/app_harness.dart';
import 'breach_list_test.dart' show hibpFixture;

/// The fixture's breaches: Trello was listed on 2024-01-22 (no passwords), Duolingo on
/// 2023-08-23 (no passwords), Twitter on 2022-08-13 and 2023-01-05, Canva on 2019-08-09
/// (passwords) and Adobe on 2013-12-04 (passwords).
final BreachList fixtureBreaches = BreachList.fromHibp(hibpFixture(), updated: '2026-11-15');

/// The fixture's breaches as the list the app uses.
final Override fixtureBreachList = breachListProvider.overrideWith((ref) async => fixtureBreaches);

/// The first day of 2019: before every breach above but Adobe's was listed.
final int addedIn2019 = DateTime.utc(2019, 1, 1).millisecondsSinceEpoch;

OtpAccount breachAccount(String id, String issuer, {String? label, int? addedAt, List<String>? dismissed}) => OtpAccount(
  id: id,
  issuer: issuer,
  label: label ?? '$id@example.com',
  secret: 'JBSWY3DPEHPK3PXP',
  addedAt: addedAt ?? addedIn2019,
  breachesDismissed: dismissed,
);

BackupService breachCodes(String id, String name, {int? addedAt}) =>
    BackupService(id: id, serviceName: name, codes: const [], addedAt: addedAt ?? addedIn2019);

/// The whole app with a vault holding [accounts] and [services], open on [route], on a
/// screen tall enough for all of Settings. The vault starts with [prefs] as its settings,
/// and the app uses the fixture's breaches unless [breaches] puts another list in.
Future<TestApp> openVaultWith(
  WidgetTester tester, {
  List<OtpAccount> accounts = const [],
  List<BackupService> services = const [],
  String route = '/settings',
  Map<String, Object?>? prefs,
  Override? breaches,
  List<Override> overrides = const [],
  void Function(TestApp app)? before,
}) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp();
  await tester.runAsync(() async {
    final session = await app.createVault('pw');
    await app.vaultStore.saveAccounts(accounts, session);
    await app.vaultStore.saveBackupServices(services, session);
  });
  if (prefs != null) app.store.setItem(prefsKey, jsonEncode(prefs));
  before?.call(app);
  await app.pump(tester, overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0'), breaches ?? fixtureBreachList, ...overrides]);
  await app.unlock(tester, 'pw');
  app.container.read(routerProvider).go(route);
  await tester.pumpAndSettle();
  return app;
}
