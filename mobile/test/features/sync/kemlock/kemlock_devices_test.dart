// The devices list (add-kemlock-server-sync, task 9.4): each device's last use
// of the Kemlock API and of the Bitwarden API, this phone marked, a device or
// all the others signed out, and this phone's trust removed.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_trust.dart';
import 'package:kemlock/features/sync/kemlock_devices.dart';
import 'package:kemlock/features/sync/kemlock_flow.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_messages.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/platform/device_keys.dart';

import '../../../fakes/fake_device_keys.dart';
import '../../../helpers/test_app.dart';
import '../sync_screen_kit.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';
import 'km_phone_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: FakeKemlockServer.deviceId,
);

late KmTestAccount _test;

final Map<String, Object?> _phone = {
  'id': 'dev-1',
  'name': 'Kemlock on Pixel 9',
  'kind': 'kemlock-android',
  'createdAt': '2026-11-01T08:00:00Z',
  'lastSeenAt': '2026-11-22T09:00:00Z',
  'lastKemlockUseAt': '2026-11-22T09:00:00Z',
  'lastBitwardenUseAt': '2026-11-10T12:00:00Z',
  'current': true,
  'trusted': false,
};

final Map<String, Object?> _extension = {
  'id': 'dev-2',
  'name': 'Bitwarden extension',
  'kind': 'bitwarden',
  'createdAt': '2026-10-01T08:00:00Z',
  'lastSeenAt': '2026-11-20T09:00:00Z',
  'lastKemlockUseAt': null,
  'lastBitwardenUseAt': '2026-11-20T09:00:00Z',
  'current': false,
  'trusted': false,
};

final Map<String, Object?> _laptop = {
  'id': 'dev-3',
  'name': 'Firefox on Linux',
  'kind': 'kemlock-web',
  'createdAt': '2026-10-05T08:00:00Z',
  'lastSeenAt': '2026-11-21T09:00:00Z',
  'lastKemlockUseAt': '2026-11-21T09:00:00Z',
  'lastBitwardenUseAt': null,
  'current': false,
  'trusted': false,
};

typedef _Opened = ({SyncSheetKit kit, FakeKemlockAccountServer server, FakeDeviceKeys keys});

Future<_Opened> _open(WidgetTester tester, List<Map<String, Object?>> devices, {bool unreachable = false}) async {
  final server = FakeKemlockAccountServer(userId: _test.userId)..deviceList = devices;
  final host = await signedInHost(server, _test);
  final keys = FakeDeviceKeys();
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showKemlockDevices,
    overrides: [
      kemlockHostProvider.overrideWith(() => KmHostHolder(host)),
      kemlockTrustProvider.overrideWithValue(KmTrust(wrapper: DeviceKeysWrapper(keys, protection: 'secure-enclave'))),
    ],
  );
  await kit.save(const SyncSettings(kemlock: _target));
  if (unreachable) server.respond = (request) async => throw StateError('no route to host');
  await kit.open(tester);
  return (kit: kit, server: server, keys: keys);
}

String _when(WidgetTester tester, String iso) =>
    syncTime(tester.element(find.byType(KemlockDevicesSheet)), DateTime.parse(iso).millisecondsSinceEpoch);

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create('00000000-0000-4000-8000-000000000001');
  });

  testWidgets('one row for a phone that uses both APIs, with both dates, and this phone marked', (tester) async {
    await _open(tester, [_phone]);

    expect(find.text('Kemlock on Pixel 9'), findsOneWidget);
    expect(find.text(t('kemlock.devices.thisPhone')), findsOneWidget);
    expect(find.text(t('kemlock.devices.kemlockUse', {'when': _when(tester, '2026-11-22T09:00:00Z')})), findsOneWidget);
    expect(find.text(t('kemlock.devices.bitwardenUse', {'when': _when(tester, '2026-11-10T12:00:00Z')})), findsOneWidget);
    expect(find.text(t('kemlock.devices.signOut')), findsNothing, reason: 'this phone is signed out by turning sync off');
  });

  testWidgets('the Bitwarden extension shows "Kemlock API: never" and its Bitwarden use', (tester) async {
    await _open(tester, [_phone, _extension]);

    expect(find.text('Bitwarden extension'), findsOneWidget);
    expect(find.text(t('kemlock.devices.kemlockUse', {'when': t('kemlock.devices.never')})), findsOneWidget);
    expect(find.text(t('kemlock.devices.bitwardenUse', {'when': _when(tester, '2026-11-20T09:00:00Z')})), findsOneWidget);
  });

  testWidgets('signing out a device ends it by its id', (tester) async {
    final opened = await _open(tester, [_phone, _extension]);

    await tapButton(tester, t('kemlock.devices.signOut'));

    expect(opened.server.signedOut, ['dev-2']);
  });

  testWidgets('"Sign out everywhere else" ends every other device and never this phone', (tester) async {
    final opened = await _open(tester, [_phone, _extension, _laptop]);

    await tapButton(tester, t('kemlock.devices.signOutOthers'));

    expect(opened.server.signedOut, ['dev-2', 'dev-3']);
  });

  testWidgets('removing trust deletes the hardware key and the copy on the server', (tester) async {
    final opened = await _open(tester, [
      {..._phone, 'trusted': true},
    ]);
    opened.server.keyCopy = {'wrappedKey': 'AAAA', 'protection': 'secure-enclave'};
    final tag = kmTrustTag(opened.kit.vaultState.vault.id, _target.accountId);

    await tapButton(tester, t('kemlock.devices.removeTrust'));

    expect(opened.keys.calls, contains('delete $tag'));
    expect(opened.server.keyCopy, isNull);
    expect(find.text(t('kemlock.devices.trustRemoved')), findsOneWidget);
  });

  testWidgets('a phone that is not trusted has no trust to remove', (tester) async {
    await _open(tester, [_phone]);

    expect(find.text(t('kemlock.devices.removeTrust')), findsNothing);
  });

  testWidgets('says so when the list cannot be read', (tester) async {
    await _open(tester, [_phone], unreachable: true);

    expect(find.text(t('kemlock.devices.failed')), findsOneWidget);
  });
}
