// Nudges from other devices (add-kemlock-server-sync, task 11.2): a `sync`
// nudge runs the scheduler only while the vault is open and Kemlock Server sync
// is on with push left on, and a nudge of a type this version does not know is
// dropped. The push token goes to the server with the device.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/platform/push.dart';

import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

class _Push implements PushTokens {
  final controller = StreamController<PushNudge>.broadcast();

  @override
  bool get available => true;

  @override
  Future<String?> token() async => 'relay-token';

  @override
  Stream<PushNudge> get onMessage => controller.stream;
}

/// A vault with sync running as in the app, and a count of the sync requests that reach the scheduler.
Future<({SyncSheetKit kit, _Push push, List<int> requests})> _open(WidgetTester tester, {SyncSettings? settings}) async {
  final push = _Push();
  addTearDown(push.controller.close);
  final kit = SyncSheetKit();
  await kit.pump(tester, showSyncSheet, syncHost: true, overrides: [pushTokensProvider.overrideWithValue(push)]);
  if (settings != null) await kit.save(settings);
  final requests = <int>[];
  final stop = kit.sync.onSyncRequest(() => requests.add(1));
  addTearDown(stop);
  await tester.pumpAndSettle();
  requests.clear();
  return (kit: kit, push: push, requests: requests);
}

Future<void> _nudge(WidgetTester tester, _Push push, PushNudge nudge) async {
  push.controller.add(nudge);
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
}
