import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/space_picker.dart';
import 'package:kemlock/features/sync/spaces_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';

import '../fakes/fake_scanner.dart';
import '../features/sync/sync_screen_kit.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

const _dav = DavAccount(url: folder, username: 'me', password: 'app-pw');

Space _space(String id, String name) => Space(
  id: id,
  name: name,
  target: SyncTarget(dav: _dav, file: spaceFile(id), key: b64(randomBytes(32))),
  joinedAt: 1,
);

/// Renders the sync sheet, the spaces sheet and the space picker, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/sync_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('sync: turning sync on, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSyncSheet, brightness: brightness);
      await kit.open(tester);
      await takeScreenshot(tester, 'sync_off_$name');
    });

    testScreenshot('sync: a refused address, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSyncSheet, brightness: brightness);
      await kit.open(tester);
      await kit.fillDav(tester, url: 'http://nas.local/dav/');
      await tester.enterText(field(t('sync.field.passphrase')), 'shared secret phrase');
      await tester.pump();
      await tapButton(tester, t('sync.connect'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, 400));
      await takeScreenshot(tester, 'sync_off_error_$name');
    });

    testScreenshot('sync: on and synced, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSyncSheet, brightness: brightness);
      await kit.save(
        SyncSettings(
          personal: SyncTarget(dav: _dav, file: syncFile, key: b64(randomBytes(32)), kdf: newKdf()),
        ),
      );
      kit.sync.setScopeStatus(personalScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.open(tester);
      await takeScreenshot(tester, 'sync_on_$name');
    });

    // openspec: add-offline-mode; no mockup, built from the alert and the sheet's own widgets
    testScreenshot('sync: paused by offline mode, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSyncSheet, brightness: brightness);
      await kit.save(
        SyncSettings(
          personal: SyncTarget(dav: _dav, file: syncFile, key: b64(randomBytes(32)), kdf: newKdf()),
        ),
      );
      kit.sync.setScopeStatus(personalScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.setOffline(tester, true);
      await kit.open(tester);
      await takeScreenshot(tester, 'sync_paused_$name');
    });

    testScreenshot('sync: on with a problem, syncing, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSyncSheet, brightness: brightness);
      await kit.save(
        SyncSettings(
          personal: SyncTarget(dav: _dav, file: syncFile, key: b64(randomBytes(32)), kdf: newKdf()),
        ),
      );
      kit.sync.setScopeStatus(personalScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch, problem: SyncProblem.network));
      await kit.open(tester);
      kit.sync.setRunning(true);
      await takeScreenshot(tester, 'sync_on_problem_$name');
    });

    testScreenshot('spaces: the list, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, brightness: brightness);
      await kit.save(SyncSettings(spaces: [_space('fam', 'Family'), _space('team', 'Marketing team')]));
      await kit.vault.applySynced(
        Lists(
          accounts: [
            for (final id in ['a', 'b', 'c'])
              OtpAccount(id: id, issuer: id, label: '', secret: 'JBSWY3DPEHPK3PXP', spaceId: 'fam', addedAt: 1),
          ],
        ),
      );
      kit.sync.setScopeStatus('fam', ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      kit.sync.setScopeStatus('team', const ScopeStatus(problem: SyncProblem.auth));
      await kit.open(tester);
      await takeScreenshot(tester, 'spaces_list_$name');
    });

    testScreenshot('spaces: no space yet, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, brightness: brightness);
      await kit.open(tester);
      await takeScreenshot(tester, 'spaces_empty_$name');
    });

    testScreenshot('spaces: a new space, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, brightness: brightness);
      await kit.open(tester);
      await tapButton(tester, t('spaces.create'));
      await tester.enterText(field(t('spaces.field.name')), 'Family');
      FocusManager.instance.primaryFocus?.unfocus();
      await takeScreenshot(tester, 'spaces_create_$name');
    });

    testScreenshot('spaces: the invite, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, brightness: brightness);
      await kit.open(tester);
      await tapButton(tester, t('spaces.create'));
      await tester.enterText(field(t('spaces.field.name')), 'Family');
      await kit.fillDav(tester);
      await tapButton(tester, t('spaces.create.button'));
      await takeScreenshot(tester, 'spaces_invite_$name');
    });

    testScreenshot('spaces: joining, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, brightness: brightness);
      await kit.open(tester);
      await tapButton(tester, t('spaces.join'));
      await tester.enterText(field(t('spaces.field.invite')), 'bmc-space:eyJ2IjoxLCJzYWx0IjoiUTJ4');
      await tester.enterText(field(t('spaces.field.code')), 'AAAA-BBBB-DDDD');
      await kit.fillDav(tester);
      await tapButton(tester, t('spaces.join.button'));
      await takeScreenshot(tester, 'spaces_join_error_$name');
    });

    testScreenshot('spaces: scanning an invite, $name', (tester) async {
      usePhoneScreen(tester);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, brightness: brightness, overrides: [FakeScanner().asOverride]);
      await kit.open(tester);
      await tapButton(tester, t('spaces.join'));
      await tester.tap(find.byTooltip(t('recovery.collect.scan')));
      await takeScreenshot(tester, 'spaces_join_scan_$name');
    });

    testScreenshot('sync: space picker, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpOnPage(
        tester,
        brightness: brightness,
        center: false,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            const SizedBox(height: 40),
            SpacePicker(value: null, onChanged: (_) {}),
            SpacePicker(value: 'fam', onChanged: (_) {}),
            SpacePicker(value: 'fam', small: true, onChanged: (_) {}),
            SpacePicker(value: 'gone', onChanged: (_) {}),
          ],
        ),
        overrides: [
          fakeSync(SyncSnapshot(settings: SyncSettings(spaces: [_space('fam', 'Family'), _space('team', 'Marketing team')]))),
        ],
      );
      await tester.tap(find.text('Family').first);
      await takeScreenshot(tester, 'sync_space_picker_$name');
    });
  }
}
