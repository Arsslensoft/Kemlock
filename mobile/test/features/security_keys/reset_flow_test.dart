import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/reset_flow.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart';

FakeFidoKey _usedKey() => FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard)
  ..addPasskey('github.com', 'adalovelace')
  ..addFingerprint('Thumb');

/// Taps "Reset passkeys and PIN" and confirms.
Future<void> _confirmReset(KeySheetRig rig) async {
  await rig.tap('securityKeys.reset.button');
  expect(find.text(t('securityKeys.reset.statement.signIns')), findsOneWidget);
  expect(find.text(t('securityKeys.reset.statement.erased')), findsOneWidget);
  expect(find.text(t('securityKeys.reset.statement.undo')), findsOneWidget);
  await rig.tester.tap(find.widgetWithText(FilledButton, t('securityKeys.reset.confirm')));
  await rig.tester.pumpAndSettle();
}

void main() {
  testWidgets('over USB: confirm, unplug, plug back in, touch, and the sheet shows a key with no PIN', (tester) async {
    final fido = _usedKey();
    final key = FakeKey(productName: 'Example Key', ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, usb);

    await _confirmReset(rig);
    expect(find.byType(KeyResetFlow), findsOneWidget);
    expect(find.text(t('securityKeys.reset.step.usb')), findsOneWidget);
    expect(find.text(t('securityKeys.reset.step.usb.detail')), findsOneWidget);
    expect(fido.requests, isNot(contains('7')), reason: 'nothing is sent while the key has not lost its power');

    await rig.remove(device);
    expect(find.text(t('securityKeys.reset.step.usb')), findsOneWidget);
    expect(fido.requests, isNot(contains('7')));
    await rig.present(key, usb);

    expect(find.text(t('securityKeys.reset.done')), findsOneWidget);
    expect(fido.pin, isNull);
    expect(fido.credentials, isEmpty);
    expect(fido.fingerprints, isEmpty);
    expect(fido.requests.where((request) => request.startsWith('6.') && request != '6.1'), isEmpty, reason: 'no PIN was needed');

    await rig.tap('securityKeys.reset.done.close');
    expect(find.byType(KeyResetFlow), findsNothing);
    expect(keyRow('securityKeys.pin.set'), findsOneWidget);
    expect(keyRow('securityKeys.pin.change'), findsNothing);
  });

  testWidgets('over NFC: confirm, then hold the key to the phone again, and the reset is sent at once', (tester) async {
    final fido = _usedKey();
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, nfc);
    await rig.remove(device);

    await _confirmReset(rig);
    expect(find.text(t('securityKeys.reset.step.nfc')), findsOneWidget);
    final mark = fido.requests.length;
    await rig.present(key, nfc);

    expect(find.text(t('securityKeys.reset.done')), findsOneWidget);
    expect(fido.requests.sublist(mark).take(2), ['4', '7'], reason: 'the key is read and reset at once');
    expect(fido.pin, isNull);
    await rig.tap('securityKeys.reset.done.close');
    expect(keyRow('securityKeys.pin.set'), findsOneWidget);
  });

  testWidgets('over NFC with the key still on the phone: take it away first', (tester) async {
    final fido = _usedKey();
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, nfc);

    await _confirmReset(rig);
    expect(find.text(t('securityKeys.reset.step.nfc.away')), findsOneWidget);
    expect(fido.requests, isNot(contains('7')));

    await rig.remove(device);
    expect(find.text(t('securityKeys.reset.step.nfc')), findsOneWidget);
    await rig.present(key, nfc);
    expect(find.text(t('securityKeys.reset.done')), findsOneWidget);
  });

  testWidgets('on an iPhone the reset goes out under the NFC sheet', (tester) async {
    final fido = _usedKey();
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester, capabilities: FakeSecurityKeys.iphone);
    rig.phone.arrive(key.device(kinds: nfc));
    await rig.tap('securityKeys.wait.iphone.read');

    rig.phone.arrive(key.device(kinds: nfc));
    await _confirmReset(rig);

    expect(find.text(t('securityKeys.reset.done')), findsOneWidget);
    expect(fido.pin, isNull);
    expect(rig.holds.isHeld, isFalse);
  });

  testWidgets('cancelling the confirmation sends nothing to the key', (tester) async {
    final fido = _usedKey();
    final rig = await openKeySheet(tester);
    await rig.present(FakeKey(productName: 'Example Key', ctap: fido), usb);
    final frames = rig.phone.sent.length;

    await rig.tap('securityKeys.reset.button');
    await tester.tap(find.widgetWithText(TextButton, t('export.cancel')));
    await tester.pumpAndSettle();

    expect(find.byType(KeyResetFlow), findsNothing);
    expect(rig.phone.sent, hasLength(frames));
    expect(fido.pin, '123456');
  });

  testWidgets('too late after power-up: the key was not reset, why, and "Try again"', (tester) async {
    final fido = _usedKey();
    final key = FakeKey(productName: 'Example Key', ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, usb);
    await _confirmReset(rig);
    await rig.remove(device);
    // The person took their time: eleven seconds pass between power-up and the reset.
    fido.onRequest = (command, _) {
      if (command == 0x07) rig.phone.elapse(const Duration(seconds: 11));
    };
    await rig.present(key, usb);

    expect(find.text(t('securityKeys.reset.failed.late')), findsOneWidget);
    expect(fido.pin, '123456');
    expect(fido.credentials, hasLength(1));

    fido.onRequest = null;
    await rig.tap('securityKeys.reset.again');
    expect(find.text(t('securityKeys.reset.step.usb')), findsOneWidget);
    await rig.remove(rig.phone.here.single);
    await rig.present(key, usb);
    expect(find.text(t('securityKeys.reset.done')), findsOneWidget);
    expect(fido.pin, isNull);
  });

  testWidgets('no touch in time: the key was not reset, and "Try again"', (tester) async {
    final fido = _usedKey()..touches = false;
    final key = FakeKey(productName: 'Example Key', ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, usb);
    await _confirmReset(rig);
    await rig.remove(device);
    await rig.present(key, usb);

    expect(find.text(t('securityKeys.reset.failed.noTouch')), findsOneWidget);
    expect(find.text(t('securityKeys.reset.again')), findsOneWidget);
    expect(fido.pin, '123456');
  });

  testWidgets('a key that does not reset over NFC says so and suggests plugging it in', (tester) async {
    final fido = _usedKey()..noResetOver = {SecurityKeyLinkKind.nfc};
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, nfc);
    await rig.remove(device);
    await _confirmReset(rig);
    await rig.present(key, nfc);

    expect(find.textContaining(t('securityKeys.reset.failed.late')), findsOneWidget);
    expect(find.textContaining(t('securityKeys.reset.failed.late.usb')), findsOneWidget);
    expect(fido.pin, '123456');
  });

  testWidgets('a key whose PIN is locked for good can be reset, without a PIN', (tester) async {
    final fido = _usedKey()..retries = 0;
    final key = FakeKey(productName: 'Example Key', ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, usb);
    expect(find.text(t('securityKeys.pin.blocked.row')), findsOneWidget);

    await _confirmReset(rig);
    await rig.remove(device);
    await rig.present(key, usb);

    expect(find.text(t('securityKeys.reset.done')), findsOneWidget);
    expect(KeySheetRig.pinRequests(fido), isEmpty);
    await rig.tap('securityKeys.reset.done.close');
    expect(keyRow('securityKeys.pin.set'), findsOneWidget);
    expect(find.text(t('securityKeys.pin.blocked.row')), findsNothing);
  });

  group('goes only to a key like the one the warning was about', () {
    testWidgets('a key of another model held to the phone in its place is not reset', (tester) async {
      final rig = await openKeySheet(tester);
      final device = await rig.present(
        FakeKey(
          ctap: FakeFidoKey(pin: '123456', aaguid: List.filled(16, 1)),
        ),
        nfc,
      );
      await rig.remove(device);
      await _confirmReset(rig);
      expect(find.text(t('securityKeys.reset.step.sameModel')), findsOneWidget);
      final other = FakeFidoKey(pin: '999999', aaguid: List.filled(16, 2))..addPasskey('example.net', 'grace');
      await rig.present(FakeKey(ctap: other), nfc);

      expect(find.text(t('securityKeys.reset.failed.otherKey')), findsOneWidget);
      expect(other.requests, isNot(contains('7')));
      expect(other.pin, '999999');
      expect(other.credentials, hasLength(1));
    });

    testWidgets('a key of the same model that has no PIN, where the one shown had one, is not reset', (tester) async {
      final rig = await openKeySheet(tester);
      final device = await rig.present(FakeKey(ctap: _usedKey()), nfc);
      await rig.remove(device);
      await _confirmReset(rig);
      final other = FakeFidoKey()..addPasskey('example.net', 'grace');
      await rig.present(FakeKey(ctap: other), nfc);

      expect(find.text(t('securityKeys.reset.failed.otherKey')), findsOneWidget);
      expect(other.requests, isNot(contains('7')));
      expect(other.credentials, hasLength(1));
    });

    testWidgets('a plugged-in key that gives another name is not reset', (tester) async {
      final rig = await openKeySheet(tester);
      final device = await rig.present(FakeKey(productName: 'Example Key', ctap: _usedKey()), usb);
      await _confirmReset(rig);
      await rig.remove(device);
      final other = _usedKey();
      await rig.present(FakeKey(productName: 'Other Key', ctap: other), usb);

      expect(find.text(t('securityKeys.reset.failed.otherKey')), findsOneWidget);
      expect(other.requests, isNot(contains('7')));
      expect(other.pin, '123456');
    });
  });

  testWidgets('cancelling while the key is waited for sends nothing and closes the steps', (tester) async {
    final fido = _usedKey();
    final rig = await openKeySheet(tester);
    final device = await rig.present(FakeKey(ctap: fido), nfc);
    await rig.remove(device);
    await _confirmReset(rig);
    final frames = rig.phone.sent.length;

    await tester.tap(find.descendant(of: find.byType(KeyResetFlow), matching: find.widgetWithText(TextButton, t('export.cancel'))));
    await tester.pumpAndSettle();

    expect(find.byType(KeyResetFlow), findsNothing);
    expect(rig.phone.sent, hasLength(frames));
    expect(find.byType(SnackBar), findsNothing);
  });
}
