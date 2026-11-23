// The live socket in the app (add-kemlock-server-sync, task 11.3): it is open only while the app is in front, the
// vault is unlocked and Kemlock Server sync is on; a `sync` frame runs the scheduler; hiding the app, locking the
// vault and turning offline mode on close it, and showing the app opens it again.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_live.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';

import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

class _NoValues implements KmVaultValues {
  @override
  Future<Object?> load(String key) async => null;

  @override
  Future<void> save(String key, Object? value) async {}

  @override
  void remove(String key) {}
}

/// A host that makes the upgrade without a session: the socket is what is under test, not the sign-in.
class _Host extends KmHost {
  _Host() : super(values: _NoValues(), clientFor: (_) => throw UnimplementedError(), proofsFor: (_) async => null);

  int upgrades = 0;

  @override
  Future<KmLiveUpgrade> liveUpgrade(KemlockTarget target) async {
    upgrades++;
    return KmLiveUpgrade(
      url: Uri.parse('wss://kem.example.com/kem/v1/live'),
      headers: {'Authorization': 'DPoP token-$upgrades', 'DPoP': 'proof-$upgrades'},
    );
  }
}

Future<({SyncSheetKit kit, _Host host, List<int> requests})> _open(WidgetTester tester, {SyncSettings? settings}) async {
  final kit = SyncSheetKit();
  await kit.pump(tester, showSyncSheet, syncHost: true);
  final requests = <int>[];
  final stop = kit.sync.onSyncRequest(() => requests.add(1));
  addTearDown(stop);
  final host = _Host();
  if (settings != null) {
    await kit.save(settings);
  }
  kit.container.read(kemlockHostProvider.notifier).set(host);
  await tester.pumpAndSettle();
  requests.clear();
  return (kit: kit, host: host, requests: requests);
}

/// The app goes behind, or comes to the front, through the states in between, as the phone does.
Future<void> _lifecycle(WidgetTester tester, {required bool front}) async {
  for (final state
      in front ? [AppLifecycleState.inactive, AppLifecycleState.resumed] : [AppLifecycleState.inactive, AppLifecycleState.hidden]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens with the upgrade of the host while the app is in front and the vault unlocked', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));

    final socket = opened.kit.live.current;
    expect(socket, isNotNull);
    expect(socket!.url.toString(), 'wss://kem.example.com/kem/v1/live');
    expect(socket.headers['DPoP'], startsWith('proof-'));
    expect(socket.headers['Authorization'], startsWith('DPoP token-'));
  });

  testWidgets('is not opened when Kemlock Server sync is off', (tester) async {
    final opened = await _open(tester);

    expect(opened.kit.live.attempts, isEmpty);
  });

  testWidgets('a sync frame runs the scheduler, and an unknown one does nothing', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));

    opened.kit.live.current!.send('{"type":"unknown"}');
    await tester.pump();
    expect(opened.requests, isEmpty);

    opened.kit.live.current!.send('{"type":"sync"}');
    await tester.pump();
    expect(opened.requests, [1]);
  });

  testWidgets('hiding the app closes the socket, and showing it opens another with a fresh proof', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));
    final first = opened.kit.live.current!;

    await _lifecycle(tester, front: false);

    expect(first.closed, isTrue);
    expect(opened.kit.live.current, isNull);

    await _lifecycle(tester, front: true);

    final second = opened.kit.live.current;
    expect(second, isNotNull);
    expect(second!.headers['DPoP'], isNot(first.headers['DPoP']));
  });

  testWidgets('locking the vault closes the socket', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));
    final socket = opened.kit.live.current!;

    opened.kit.vault.lock();
    await tester.pumpAndSettle();

    expect(socket.closed, isTrue);
    expect(opened.kit.live.current, isNull);
  });

  testWidgets('offline mode closes the socket and no attempt is made while it is on', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));
    final socket = opened.kit.live.current!;

    await opened.kit.setOffline(tester, true);
    await tester.pump(const Duration(minutes: 10));

    expect(socket.closed, isTrue);
    expect(opened.kit.live.current, isNull);
    expect(opened.kit.live.attempts, hasLength(1));
  });

  testWidgets('a dropped socket is opened again after the back-off', (tester) async {
    final opened = await _open(tester, settings: const SyncSettings(kemlock: _target));

    await opened.kit.live.current!.drop();
    await tester.pump();
    expect(opened.kit.live.current, isNull);
    expect(opened.kit.live.attempts, hasLength(1));

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(opened.kit.live.attempts, hasLength(2));
  });
}
