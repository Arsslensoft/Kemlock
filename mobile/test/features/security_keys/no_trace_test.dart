import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/security_keys/key_passkeys_sheet.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/features/settings/app_version.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_clipboard.dart';
import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart' show usb;

// Strings that appear nowhere else: the key's model, its PIN, and the
// sites and users of its passkeys.
const _model = 'Quartzmodel-ZZ9';
const _pin = '9182736450';
const _sites = ['tracesite-one.example', 'tracesite-two.example'];
const _users = ['traceuser-one', 'traceuser-two'];
final _aaguid = List.filled(16, 0xa7);

/// What would give the key away, in the forms storage could hold it.
final _marks = [
  _model,
  _pin,
  ..._sites,
  ..._users,
  'a7a7a7a7', // the AAGUID in hex
  'p6enp6en', // and in base64
];

/// Everything the phone's storage holds, keys and values, as one text.
String _everything(TestApp app) => [for (final key in app.store.storedKeys()) '$key=${app.store.getItem(key)}'].join('\n');

/// A whole session on a key from the vault opened with [password]: read
/// it, type its PIN, list its passkeys, delete one, close, lock.
Future<void> _session(WidgetTester tester, TestApp app, String password, List<String> clipboard) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') clipboard.add('${(call.arguments as Map<Object?, Object?>)['text']}');
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  answerSensitiveCopies(clipboard.add);

  final phone = FakeSecurityKeys();
  final fido = FakeFidoKey(pin: _pin, aaguid: _aaguid, firmwareVersion: 77)
    ..addPasskey(_sites[0], _users[0])
    ..addPasskey(_sites[1], _users[1]);
  await app.pump(tester, overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0'), phone.asOverride]);
  await app.controller.open(await app.vaultStore.unlockAnyVault(password, app.vaults.startingVault()));
  app.controller.biometricOffered();
  await tester.pumpAndSettle();
  app.container.read(routerProvider).go('/settings');
  await tester.pumpAndSettle();

  final row = find.widgetWithText(GroupRow, t('securityKeys.settings.row'));
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
  phone.arrive(FakeKey(productName: _model, ctap: fido).device(kinds: usb));
  await tester.pumpAndSettle();
  expect(find.text(_model), findsOneWidget);

  await tester.tap(find.widgetWithText(GroupRow, t('securityKeys.passkeys.row')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, _pin);
  await tester.pump();
  await tester.tap(find.text(t('securityKeys.pin.continue')));
  await tester.pumpAndSettle();
  expect(find.byType(KeyPasskeysSheet), findsOneWidget);
  expect(find.text(_sites[1]), findsOneWidget);

  await tester.tap(find.descendant(of: find.widgetWithText(GroupRow, _sites[0]), matching: find.text(t('securityKeys.passkeys.delete'))));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, t('securityKeys.passkeys.delete')));
  await tester.pumpAndSettle();
  expect(fido.credentials, hasLength(1));

  for (var i = 0; i < 2; i++) {
    await tester.tap(find.bySemanticsLabel(t('export.close')).last);
    await tester.pumpAndSettle();
  }
  expect(find.byType(SecurityKeySheet), findsNothing);
  app.controller.lock();
  await tester.pumpAndSettle();
  expect(find.byType(LockScreen), findsOneWidget);
}

void main() {
  testWidgets('a whole session with a key leaves nothing of it in storage, the preferences or the clipboard', (tester) async {
    final app = TestApp();
    await tester.runAsync(() => app.createVault('pw'));
    final clipboard = <String>[];

    await _session(tester, app, 'pw', clipboard);

    final stored = _everything(app);
    expect(stored, isNotEmpty);
    for (final mark in _marks) {
      expect(stored.contains(mark), isFalse, reason: '"$mark" in storage');
      expect(clipboard.join('\n').contains(mark), isFalse, reason: '"$mark" on the clipboard');
      expect(find.textContaining(mark), findsNothing, reason: '"$mark" on the lock screen');
    }
    expect(app.store.storedKeys().where((key) => key.toLowerCase().contains('securitykey') || key.toLowerCase().contains('fido')), isEmpty);
  });

  testWidgets('the same holds from a hidden vault, and nothing stored shows the vault exists', (tester) async {
    final app = TestApp();
    await tester.runAsync(() async {
      await app.createVault('pw');
      await app.vaultStore.setupVault('hidden pw', id: 'c0ffee012345');
    });
    expect(app.vaults.hiddenVaultIds(), ['c0ffee012345']);
    final keysBefore = app.store.storedKeys().toSet();
    final clipboard = <String>[];

    await _session(tester, app, 'hidden pw', clipboard);

    expect(app.vaults.hiddenVaultIds(), ['c0ffee012345'], reason: 'the vault is still unlisted');
    expect(app.store.storedKeys().toSet().difference(keysBefore).where((key) => key.contains('c0ffee012345')), isEmpty);
    final stored = _everything(app);
    for (final mark in _marks) {
      expect(stored.contains(mark), isFalse, reason: '"$mark" in storage');
      expect(clipboard.join('\n').contains(mark), isFalse, reason: '"$mark" on the clipboard');
    }
  });
}
