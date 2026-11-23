// The home server away, on the Kemlock Server sheet (add-kemlock-server-sync,
// task 10.3): since when it is offline and which server is in use, and nothing
// of the kind while the phone is on the home.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kemlock/features/sync/kemlock/km_failover.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';

import '../../../helpers/test_app.dart';
import '../sync_screen_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [
    KemlockServer(url: 'https://kem.example.com'),
    KemlockServer(url: 'https://vps.example.com', role: KemlockServer.replica, extra: {'name': 'VPS (Germany)'}),
  ],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

Future<SyncSheetKit> _open(WidgetTester tester) async {
  final kit = SyncSheetKit();
  await kit.pump(tester, showSyncSheet);
  await kit.save(const SyncSettings(kemlock: _target));
  await kit.open(tester);
  return kit;
}

void main() {
  testWidgets('on the home, nothing is said of a home that is away', (tester) async {
    await _open(tester);

    expect(find.textContaining('offline since'), findsNothing);
    expect(find.text(t('kemlock.away.hint')), findsNothing);
  });

  testWidgets('says since when the home is offline, and which server is in use', (tester) async {
    final kit = await _open(tester);
    final since = DateTime(2026, 11, 22, 9, 12);

    kit.container.read(kemlockAwayProvider.notifier).set(KmAway(using: _target.servers[1], since: since));
    await tester.pumpAndSettle();

    expect(find.text(t('kemlock.failover.homeAway', {'time': DateFormat.jm('en').format(since)})), findsOneWidget);
    expect(find.text(t('kemlock.failover.using', {'server': 'VPS (Germany)'})), findsOneWidget);
    expect(find.text(t('kemlock.away.hint')), findsOneWidget);
  });

  testWidgets('a replica with no name is shown by its host', (tester) async {
    final kit = await _open(tester);

    kit.container
        .read(kemlockAwayProvider.notifier)
        .set(
          KmAway(
            using: const KemlockServer(url: 'https://eu.example.com:8443', role: KemlockServer.replica),
            since: DateTime(2026, 11, 22, 9, 12),
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text(t('kemlock.failover.using', {'server': 'eu.example.com:8443'})), findsOneWidget);
  });

  testWidgets('the line goes when the phone is back on the home', (tester) async {
    final kit = await _open(tester);
    final notifier = kit.container.read(kemlockAwayProvider.notifier);
    notifier.set(KmAway(using: _target.servers[1], since: DateTime(2026, 11, 22, 9, 12)));
    await tester.pumpAndSettle();

    notifier.set(null);
    await tester.pumpAndSettle();

    expect(find.text(t('kemlock.away.hint')), findsNothing);
  });
}
