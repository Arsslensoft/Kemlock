// Nudges from other devices (add-kemlock-server-sync, task 11.2): a `sync`
// nudge runs the scheduler only while the vault is open and Kemlock Server sync
// is on with push left on, and a nudge of a type this version does not know is
// dropped. The push token goes to the server with the device.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock_push.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/platform/push.dart';

import '../../../fakes/fake_push_tokens.dart';
import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

/// A vault with sync running as in the app, and a count of the sync requests that reach the scheduler. [taken] records each
/// token the server is asked to forget.
Future<({SyncSheetKit kit, FakePushTokens push, List<int> requests})> _open(
  WidgetTester tester, {
  SyncSettings? settings,
  FakePushTokens? push,
  List<KemlockTarget>? taken,
}) async {
  push ??= FakePushTokens.apns();
  addTearDown(push.close);
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSyncSheet,
    syncHost: true,
    overrides: [pushTokensProvider.overrideWithValue(push), kemlockPushOffProvider.overrideWithValue((target) async => taken?.add(target))],
  );
  if (settings != null) await kit.save(settings);
  final requests = <int>[];
  final stop = kit.sync.onSyncRequest(() => requests.add(1));
  addTearDown(stop);
  await tester.pumpAndSettle();
  requests.clear();
  return (kit: kit, push: push, requests: requests);
}

Future<void> _nudge(WidgetTester tester, FakePushTokens push, PushNudge nudge) async {
  push.nudges.add(nudge);
  await tester.pump();
}

void main() {
  testWidgets('a sync nudge runs the scheduler while Kemlock Server sync is on', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));

    await _nudge(tester, opened.push, PushNudge.sync);

    expect(opened.requests, [1]);
  });

  testWidgets('a sync nudge is dropped when sync is not Kemlock Server', (tester) async {
    final opened = await _open(tester);

    await _nudge(tester, opened.push, PushNudge.sync);

    expect(opened.requests, isEmpty);
  });

  testWidgets('a sync nudge is dropped when the push switch is off', (tester) async {
    final opened = await _open(tester, settings: SyncSettings(kemlock: _target.copyWith(push: false)));

    await _nudge(tester, opened.push, PushNudge.sync);

    expect(opened.requests, isEmpty);
  });

  testWidgets('a nudge carries only its type: one of a type this version does not know is dropped', (tester) async {
    expect(PushNudge.parse('sync'), PushNudge.sync);
    expect(PushNudge.parse('approval'), PushNudge.approval);
    expect(PushNudge.parse('delete-everything'), isNull);
    expect(PushNudge.parse(null), isNull);
  });

  testWidgets('an approval nudge with no host to ask does nothing and breaks nothing', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));

    await _nudge(tester, opened.push, PushNudge.approval);

    expect(tester.takeException(), isNull);
  });

  group('a change of the phone’s push token', () {
    FakePushTokens unifiedPush({PushToken? token}) => FakePushTokens.unifiedPush(token: token);
    const endpoint = (kind: pushKindUnifiedPush, token: 'https://ntfy.example.com/upNew');

    Future<void> changed(WidgetTester tester, FakePushTokens push) async {
      push.changes.add(null);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a new UnifiedPush endpoint is registered at once, by a sync run, while push is on', (tester) async {
      final push = unifiedPush(token: endpoint);
      final opened = await _open(
        tester,
        settings: const SyncSettings(kemlock: _target),
        push: push,
      );

      await changed(tester, push);

      expect(opened.requests, [1]);
    });

    testWidgets('a lost endpoint is taken back from the server', (tester) async {
      final taken = <KemlockTarget>[];
      final push = unifiedPush();
      final opened = await _open(
        tester,
        settings: const SyncSettings(kemlock: _target),
        push: push,
        taken: taken,
      );

      await changed(tester, push);

      expect(taken, [_target]);
      expect(opened.requests, isEmpty);
    });

    testWidgets('a new endpoint with the push switch off runs nothing', (tester) async {
      final push = unifiedPush(token: endpoint);
      final opened = await _open(
        tester,
        settings: SyncSettings(kemlock: _target.copyWith(push: false)),
        push: push,
      );

      await changed(tester, push);

      expect(opened.requests, isEmpty);
    });

    testWidgets('a lost endpoint with the push switch off asks the server nothing', (tester) async {
      final taken = <KemlockTarget>[];
      final push = unifiedPush();
      await _open(
        tester,
        settings: SyncSettings(kemlock: _target.copyWith(push: false)),
        push: push,
        taken: taken,
      );

      await changed(tester, push);

      expect(taken, isEmpty);
    });

    testWidgets('a UnifiedPush message is a sync nudge', (tester) async {
      final push = unifiedPush(token: endpoint);
      final opened = await _open(
        tester,
        settings: const SyncSettings(kemlock: _target),
        push: push,
      );

      await _nudge(tester, push, PushNudge.sync);

      expect(opened.requests, [1]);
    });
  });
}
