// The push switch of the Kemlock Server sheet on Android (plan add-unifiedpush): with no distributor installed it says so,
// links to the page that lists them and does not turn on; with one or several it turns on through the distributor, names
// the one in use and lets the person change it; turned off, it takes the token back from the server and gives the
// registration back. The iPhone's switch is the plain one, which kemlock_sheet_test checks.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock_push.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/platform/push.dart';

import '../../../fakes/fake_push_tokens.dart';
import '../../../helpers/test_app.dart';
import '../../backup/backup_test_kit.dart' show FakeLinks;
import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

const _ntfy = PushDistributor(id: 'io.heckel.ntfy', name: 'ntfy');
const _nextPush = PushDistributor(id: 'org.unifiedpush.distributor.nextpush', name: 'NextPush');

/// The sheet of a vault that syncs with Kemlock Server, on a phone whose push is [push]. [taken] records each token the
/// server is asked to forget.
Future<SyncSheetKit> _open(
  WidgetTester tester,
  FakePushTokens push, {
  KemlockTarget target = _target,
  FakeLinks? links,
  List<KemlockTarget>? taken,
}) async {
  addTearDown(push.close);
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSyncSheet,
    overrides: [
      pushTokensProvider.overrideWithValue(push),
      kemlockPushOffProvider.overrideWithValue((target) async => taken?.add(target)),
      if (links != null) links.asOverride,
    ],
  );
  await kit.save(SyncSettings(kemlock: target));
  await kit.open(tester);
  return kit;
}

Finder get _tile => find.widgetWithText(SwitchListTile, t('kemlock.push.changes'));

bool _on(WidgetTester tester) => tester.widget<SwitchListTile>(_tile).value;

void main() {
  group('with no distributor installed', () {
    testWidgets('says so, links to the page that lists them, and the switch cannot be turned on', (tester) async {
      final links = FakeLinks();
      final kit = await _open(tester, FakePushTokens.unifiedPush(), links: links);

      expect(find.text(t('kemlock.push.unifiedpush.none')), findsOneWidget);
      expect(_on(tester), isFalse, reason: 'push is wanted, but nothing delivers it');
      expect(tester.widget<SwitchListTile>(_tile).onChanged, isNull);

      await tapButton(tester, t('kemlock.push.unifiedpush.get'));

      expect(links.opened, [Uri.parse('https://unifiedpush.org/users/distributors/')]);
      expect(kit.settings?.kemlock?.push, isTrue, reason: 'the setting is left as it was');
    });
  });

  group('with distributors installed', () {
    testWidgets('turning the switch on asks the distributor to start, then saves it', (tester) async {
      final push = FakePushTokens.unifiedPush(installed: [_ntfy]);
      final kit = await _open(tester, push, target: _target.copyWith(push: false));
      expect(_on(tester), isFalse);
      expect(find.text(t('kemlock.push.unifiedpush.hint')), findsOneWidget);

      await tester.tap(find.text(t('kemlock.push.changes')));
      await tester.pumpAndSettle();

      expect(push.calls, ['start']);
      expect(_on(tester), isTrue);
      expect(kit.settings?.kemlock?.push, isTrue);
      expect(find.text(t('kemlock.push.unifiedpush.using', {'name': 'ntfy'})), findsOneWidget);
    });

    testWidgets('turning the switch on asks for a sync once it is saved, which registers an endpoint that came first', (tester) async {
      final push = FakePushTokens.unifiedPush(
        installed: [_ntfy],
        token: (kind: pushKindUnifiedPush, token: 'https://ntfy.example.com/up1'),
      );
      final kit = await _open(tester, push, target: _target.copyWith(push: false));
      var requests = 0;
      final stop = kit.sync.onSyncRequest(() => requests++);
      addTearDown(stop);

      await tester.tap(find.text(t('kemlock.push.changes')));
      await tester.pumpAndSettle();

      expect(kit.settings?.kemlock?.push, isTrue);
      expect(requests, greaterThan(0), reason: 'an endpoint that came before the save was ignored, and only a sync takes it');
    });

    testWidgets('a person who goes back from the system’s choice leaves it off and saves nothing', (tester) async {
      final push = FakePushTokens.unifiedPush(installed: [_ntfy, _nextPush])..startAnswer = false;
      final kit = await _open(tester, push, target: _target.copyWith(push: false));

      await tester.tap(find.text(t('kemlock.push.changes')));
      await tester.pumpAndSettle();

      expect(push.calls, ['start']);
      expect(_on(tester), isFalse);
      expect(kit.settings?.kemlock?.push, isFalse);
    });

    testWidgets('wanted but not yet chosen, the switch is off until a distributor is in use', (tester) async {
      final push = FakePushTokens.unifiedPush(installed: [_ntfy, _nextPush]);
      await _open(tester, push);

      expect(_on(tester), isFalse);
      expect(find.text(t('kemlock.push.unifiedpush.using', {'name': 'ntfy'})), findsNothing);
      expect(find.text(t('kemlock.push.unifiedpush.change')), findsNothing);
    });

    testWidgets('names the distributor in use, and with several lets the person change it', (tester) async {
      final push = FakePushTokens.unifiedPush(installed: [_ntfy, _nextPush], inUse: _ntfy);
      await _open(tester, push);

      expect(_on(tester), isTrue);
      expect(find.text(t('kemlock.push.unifiedpush.using', {'name': 'ntfy'})), findsOneWidget);

      await tapButton(tester, t('kemlock.push.unifiedpush.change'));

      expect(push.calls, ['change']);
    });

    testWidgets('with only one installed there is nothing to change it to', (tester) async {
      await _open(tester, FakePushTokens.unifiedPush(installed: [_ntfy], inUse: _ntfy));

      expect(find.text(t('kemlock.push.unifiedpush.using', {'name': 'ntfy'})), findsOneWidget);
      expect(find.text(t('kemlock.push.unifiedpush.change')), findsNothing);
    });

    testWidgets('turning it off is saved, takes the token back from the server and gives the registration back', (tester) async {
      final taken = <KemlockTarget>[];
      final push = FakePushTokens.unifiedPush(installed: [_ntfy], inUse: _ntfy);
      final kit = await _open(tester, push, taken: taken);

      await tester.tap(find.text(t('kemlock.push.changes')));
      await tester.pumpAndSettle();

      expect(kit.settings?.kemlock?.push, isFalse);
      expect(taken.map((target) => target.push), [false]);
      expect(push.calls, ['stop']);
    });
  });
}
