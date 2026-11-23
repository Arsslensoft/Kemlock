// The Bitwarden copy's card in Settings > Sync (move-off-vaultwarden-sync, tasks 6.1 and 6.2): the device that keeps
// the copy needed is named, the removal is offered after 30 days with no device and not before, confirming
// removes the copy and nothing else, and a device that returns withdraws the offer.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock_copy.dart';
import 'package:kemlock/features/sync/kemlock_host_factory.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';

import '../../../helpers/test_app.dart';
import '../../export/transfer_harness.dart' show tapOn;
import '../sync_screen_kit.dart';

const _kemlock = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com:8443')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

const _copy = VaultwardenTarget(
  server: 'https://kem.example.com:8443',
  email: 'me@example.com',
  home: 'home-1',
  mode: VaultwardenMode.plain,
  folderId: 'folder-1',
);

KmDevice _device(String name, {int? bitwardenDaysAgo, int? kemlockDaysAgo}) => KmDevice(
  id: name,
  name: name,
  kind: 'other',
  lastBitwarden: bitwardenDaysAgo == null ? null : testNow.subtract(Duration(days: bitwardenDaysAgo)),
  lastKemlock: kemlockDaysAgo == null ? null : testNow.subtract(Duration(days: kemlockDaysAgo)),
);

/// A vault whose plain home's copy stays beside Kemlock Server, moved [movedDaysAgo] days ago, with the sheet open.
/// [devices] is the account's device list, which a test may change; [removed] gets each home the copy's removal is
/// asked for.
Future<SyncSheetKit> _open(
  WidgetTester tester, {
  required int movedDaysAgo,
  required List<KmDevice> Function() devices,
  List<VaultwardenTarget>? removed,
}) async {
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSyncSheet,
    overrides: [
      kemlockDeviceListProvider.overrideWithValue((target) async => devices()),
      kemlockCopyRemovalProvider.overrideWithValue((target) async {
        removed?.add(target);
        return 4;
      }),
    ],
  );
  await KmMoveStore(VaultKmValues(kit.vaultStore, kit.session)).save(
    KmMoveRecord(
      source: vaultwardenSource,
      server: _copy.server,
      startedAt: 1,
      step: KmMoveStep.done,
      finishedAt: testNow.subtract(Duration(days: movedDaysAgo)).millisecondsSinceEpoch,
      result: const {
        'moved': {'otp': 2},
        'oldStore': 'copyKept',
      },
    ),
  );
  await kit.save(const SyncSettings(kemlock: _kemlock, vaultwarden: _copy));
  await kit.open(tester);
  return kit;
}

void main() {
  testWidgets('names the device that keeps the copy needed, and offers nothing', (tester) async {
    await _open(
      tester,
      movedDaysAgo: 90,
      devices: () => [_device('Amethystora', bitwardenDaysAgo: 1), _device('Pixel', kemlockDaysAgo: 0)],
    );

    expect(find.text(t('kemlock.copy.needed', {'names': 'Amethystora'})), findsOneWidget);
    expect(find.text(t('kemlock.copy.offer.title')), findsNothing);
  });

  testWidgets('offers the removal at 31 days with no device, and not at 10', (tester) async {
    await _open(tester, movedDaysAgo: 31, devices: () => [_device('Old', bitwardenDaysAgo: 45)]);
    expect(find.text(t('kemlock.copy.offer.title')), findsOneWidget);
    expect(find.text(t('kemlock.copy.offer.body')), findsOneWidget);
  });

  testWidgets('waits for 30 days after the move, and says so', (tester) async {
    await _open(tester, movedDaysAgo: 10, devices: () => [_device('Old', bitwardenDaysAgo: 45)]);
    expect(find.text(t('kemlock.copy.offer.title')), findsNothing);
    expect(find.text(t('kemlock.copy.waiting')), findsOneWidget);
  });

  testWidgets('confirming removes the copy and stops syncing the home, and keeps the Kemlock target', (tester) async {
    final removed = <VaultwardenTarget>[];
    final kit = await _open(tester, movedDaysAgo: 40, devices: () => [_device('Old', bitwardenDaysAgo: 45)], removed: removed);

    expect(removed, isEmpty, reason: 'nothing is removed before the person confirms');
    await tapOn(tester, buttonWithText(t('kemlock.copy.remove')));

    expect(removed.map((target) => target.home), ['home-1']);
    expect(kit.settings!.vaultwarden, isNull);
    expect(kit.settings!.kemlock?.accountId, _kemlock.accountId);
    expect(find.text(t('kemlock.copy.removed')), findsOneWidget);
  });

  testWidgets('a device that returns before the confirmation withdraws the offer, and the copy stays', (tester) async {
    var devices = [_device('Old', bitwardenDaysAgo: 45)];
    final removed = <VaultwardenTarget>[];
    final kit = await _open(tester, movedDaysAgo: 40, devices: () => devices, removed: removed);
    expect(find.text(t('kemlock.copy.offer.title')), findsOneWidget);

    devices = [_device('Old', bitwardenDaysAgo: 0)];
    await tapOn(tester, buttonWithText(t('kemlock.copy.remove')));

    expect(removed, isEmpty);
    expect(kit.settings!.vaultwarden?.home, 'home-1');
    expect(find.text(t('kemlock.copy.withdrawn')), findsOneWidget);
    expect(find.text(t('kemlock.copy.offer.title')), findsNothing);
  });
}
