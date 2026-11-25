// The notification of a sign-in request (add-kemlock-server-sync, task 11.2): an `approval` nudge that reaches a
// locked vault raises the fixed-text notification and fetches nothing; a `sync` nudge raises none; with the vault
// open the request is read instead, and no notification is raised. A tap on the notification, then the unlock, lands on
// the request.
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_approvals.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock_approval.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/platform/push.dart';

import '../../../fakes/fake_push_tokens.dart';
import '../../../helpers/test_app.dart' show t;
import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

Future<({SyncSheetKit kit, FakePushTokens push, List<int> requests})> _open(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  final push = FakePushTokens.apns();
  addTearDown(push.close);
  final kit = SyncSheetKit();
  await kit.pump(tester, showSyncSheet, syncHost: true, overrides: [pushTokensProvider.overrideWithValue(push), ...overrides]);
  await kit.save(const SyncSettings(kemlock: _target));
  final requests = <int>[];
  final stop = kit.sync.onSyncRequest(() => requests.add(1));
  addTearDown(stop);
  await tester.pumpAndSettle();
  requests.clear();
  return (kit: kit, push: push, requests: requests);
}

/// The requests of the account, as the server holds them: a read gives whichever are in [waiting] now, and counts.
class _FakeApprovals extends KemlockApprovals {
  _FakeApprovals(this.reads, this.waiting);

  final List<int> reads;
  final List<KmPendingApproval> waiting;

  @override
  Future<void> refresh() async {
    reads.add(1);
    state = List.of(waiting);
  }
}

final _request = KmPendingApproval(
  request: KmApprovalRequest(
    id: 'b0000000-0000-4000-8000-000000000001',
    deviceName: 'Firefox on Linux',
    deviceKind: 'browser',
    ip: '203.0.113.0',
    phrase: 'slurp series primary ruined afraid',
    createdAt: DateTime(2026, 11, 22),
    expiresAt: DateTime(2026, 11, 23),
  ),
  phrase: 'slurp series primary ruined afraid',
  age: const Duration(minutes: 1),
  serverPhraseAgrees: true,
);

Future<void> _nudge(WidgetTester tester, FakePushTokens push, PushNudge nudge) async {
  push.nudges.add(nudge);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('an approval nudge at a locked vault raises the notification and fetches nothing', (tester) async {
    final opened = await _open(tester);
    opened.kit.vault.lock();
    await tester.pumpAndSettle();

    await _nudge(tester, opened.push, PushNudge.approval);

    expect(opened.kit.notice.showing, isTrue);
    expect(opened.kit.notice.shown, 1);
    expect(opened.requests, isEmpty);
  });

  testWidgets('a sync nudge at a locked vault raises no notification and fetches nothing', (tester) async {
    final opened = await _open(tester);
    opened.kit.vault.lock();
    await tester.pumpAndSettle();

    await _nudge(tester, opened.push, PushNudge.sync);

    expect(opened.kit.notice.showing, isFalse);
    expect(opened.requests, isEmpty);
  });

  testWidgets('an approval nudge with the vault open raises no notification', (tester) async {
    final opened = await _open(tester);

    await _nudge(tester, opened.push, PushNudge.approval);

    expect(opened.kit.notice.showing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap on the notification at a locked vault breaks nothing and leaves it for the unlock', (tester) async {
    final opened = await _open(tester);
    opened.kit.vault.lock();
    await tester.pumpAndSettle();
    await _nudge(tester, opened.push, PushNudge.approval);

    opened.kit.notice.tap();
    await tester.pump();

    expect(opened.kit.notice.showing, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the notification and unlocking lands on the request, which is read only then', (tester) async {
    final reads = <int>[];
    final waiting = <KmPendingApproval>[];
    final opened = await _open(tester, overrides: [kemlockApprovalsProvider.overrideWith(() => _FakeApprovals(reads, waiting))]);
    final title = t('kemlock.approval.title', {'device': 'Firefox on Linux'});
    opened.kit.vault.lock();
    await tester.pumpAndSettle();
    reads.clear();
    await _nudge(tester, opened.push, PushNudge.approval);
    waiting.add(_request);

    opened.kit.notice.tap();
    await tester.pump();

    expect(reads, isEmpty, reason: 'nothing is read while the vault is locked');
    expect(find.text(title), findsNothing);
    expect(opened.kit.notice.showing, isTrue);

    await opened.kit.vault.open(opened.kit.session);
    await tester.pumpAndSettle();

    expect(reads, isNotEmpty, reason: 'the host reads the requests when it starts');
    expect(find.text(title), findsOneWidget);
    expect(opened.kit.notice.showing, isFalse, reason: 'the notice is taken back');
  });
}
