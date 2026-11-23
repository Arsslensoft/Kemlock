import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart';

/// Fills the PIN form's fields, in order, and submits it.
Future<void> _fill(KeySheetRig rig, List<String> values, String submitId) async {
  final fields = find.byType(TextField);
  expect(fields, findsNWidgets(values.length));
  for (final (index, value) in values.indexed) {
    await rig.tester.enterText(fields.at(index), value);
  }
  await rig.tester.pump();
  await rig.tester.tap(find.widgetWithText(FilledButton, t(submitId)));
  await rig.tester.pumpAndSettle();
}

void main() {
  for (final kinds in [nfc, usb]) {
    final over = kinds == nfc ? 'NFC' : 'USB';

    Future<(KeySheetRig, FakeFidoKey)> read(WidgetTester tester, FakeFidoKey fido) async {
      final rig = await openKeySheet(tester);
      await rig.present(FakeKey(productName: 'Example Key', ctap: fido), kinds);
      return (rig, fido);
    }

    group('over $over', () {
      testWidgets('a first PIN is set, and the row turns to "Set"', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey());
        await rig.tapRow('securityKeys.pin.set');
        expect(find.text(t('securityKeys.pin.current')), findsNothing);

        await _fill(rig, ['123456', '123456'], 'securityKeys.pin.set.save');

        expect(fido.pin, '123456');
        expect(find.text(t('securityKeys.pin.done.set')), findsOneWidget);
        expect(keyRow('securityKeys.pin.change'), findsOneWidget);
        expect(find.descendant(of: keyRow('securityKeys.pin.change'), matching: find.text(t('securityKeys.pin.isSet'))), findsOneWidget);
        expect(keyRow('securityKeys.pin.set'), findsNothing);
      });

      testWidgets('two entries that differ send nothing to the key', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey());
        await rig.tapRow('securityKeys.pin.set');
        final frames = rig.phone.sent.length;

        await _fill(rig, ['123456', '123457'], 'securityKeys.pin.set.save');

        expect(find.text(t('securityKeys.pin.mismatch')), findsOneWidget);
        expect(rig.phone.sent, hasLength(frames));
        expect(fido.pin, isNull);
      });

      testWidgets('a PIN shorter than the key’s minimum is refused before anything is sent', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(minPinLength: 6));
        await rig.tapRow('securityKeys.pin.set');
        final frames = rig.phone.sent.length;

        await _fill(rig, ['12345', '12345'], 'securityKeys.pin.set.save');

        expect(find.text(t('securityKeys.pin.tooShort', {'count': 6})), findsOneWidget);
        expect(rig.phone.sent, hasLength(frames));
        expect(fido.pin, isNull);
      });

      testWidgets('four characters are asked for when the key reports no minimum', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey());
        await rig.tapRow('securityKeys.pin.set');
        final frames = rig.phone.sent.length;

        await _fill(rig, ['123', '123'], 'securityKeys.pin.set.save');
        expect(find.text(t('securityKeys.pin.tooShort', {'count': 4})), findsOneWidget);
        expect(rig.phone.sent, hasLength(frames));

        await _fill(rig, ['1234', '1234'], 'securityKeys.pin.set.save');
        expect(fido.pin, '1234');
      });

      testWidgets('a PIN longer than 63 bytes is refused before anything is sent', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey());
        await rig.tapRow('securityKeys.pin.set');
        final frames = rig.phone.sent.length;

        await _fill(rig, ['é' * 32, 'é' * 32], 'securityKeys.pin.set.save');

        expect(find.text(t('securityKeys.pin.tooLong')), findsOneWidget);
        expect(rig.phone.sent, hasLength(frames));
        expect(fido.pin, isNull);
      });

      testWidgets('the PIN is changed with the right current PIN', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(pin: '123456'));
        await rig.tapRow('securityKeys.pin.change');

        await _fill(rig, ['123456', '654321', '654321'], 'securityKeys.pin.change');

        expect(fido.pin, '654321');
        expect(find.text(t('securityKeys.pin.done.changed')), findsOneWidget);
      });

      testWidgets('a wrong current PIN is said with the tries left, and the warning that the key locks for good', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(pin: '123456')..retries = 6);
        await rig.tapRow('securityKeys.pin.change');

        await _fill(rig, ['000000', '654321', '654321'], 'securityKeys.pin.change');

        expect(fido.pin, '123456');
        expect(find.textContaining(t('securityKeys.pin.wrong')), findsOneWidget);
        expect(find.textContaining(t('securityKeys.pin.triesLeft', {'count': 5})), findsOneWidget);
        expect(find.textContaining(t('securityKeys.pin.wrong.warning')), findsOneWidget);
        expect(KeySheetRig.pinRequests(fido), ['6.4'], reason: 'nothing is sent again by itself');
      });

      testWidgets('the key’s own refusal of a new PIN is said, and the old PIN still works', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(pin: '123456')..refusesPin = (pin) => pin == '111111');
        await rig.tapRow('securityKeys.pin.change');

        await _fill(rig, ['123456', '111111', '111111'], 'securityKeys.pin.change');

        expect(find.text(t('securityKeys.pin.refused')), findsOneWidget);
        expect(fido.pin, '123456');
      });

      testWidgets('a forced change leads to the form first, then to what was asked for', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(pin: '123456', forcePinChange: true)..addPasskey('example.org', 'ada'));
        await rig.tapRow('securityKeys.passkeys.row');
        expect(find.text(t('securityKeys.pin.forced')), findsOneWidget);
        expect(KeySheetRig.pinRequests(fido), isEmpty);

        await _fill(rig, ['123456', '654321', '654321'], 'securityKeys.pin.change');

        expect(fido.pin, '654321');
        expect(find.text('example.org'), findsOneWidget, reason: 'the passkeys open with the PIN just typed');
      });

      testWidgets('a wrong PIN at the prompt says the tries left and asks again', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(pin: '123456')..addPasskey('example.org', 'ada'));
        await rig.tapRow('securityKeys.passkeys.row');
        expect(find.textContaining(t('securityKeys.pin.wrong.warning')), findsNothing, reason: 'eight tries left: nothing to warn of yet');

        await rig.typePin('000000');

        expect(find.textContaining(t('securityKeys.pin.wrong')), findsOneWidget);
        expect(find.textContaining(t('securityKeys.pin.triesLeft', {'count': 7})), findsOneWidget);
        expect(KeySheetRig.pinRequests(fido), hasLength(1));

        await rig.typePin('123456');
        expect(find.text('example.org'), findsOneWidget);
      });

      testWidgets('the prompt says how many tries are left before typing when three or fewer remain', (tester) async {
        final (rig, _) = await read(tester, FakeFidoKey(pin: '123456')..retries = 3);

        await rig.tapRow('securityKeys.passkeys.row');

        expect(find.textContaining(t('securityKeys.pin.triesLeft', {'count': 3})), findsOneWidget);
        expect(find.textContaining(t('securityKeys.pin.wrong.warning')), findsOneWidget);
        expect(find.textContaining(t('securityKeys.pin.wrong')), findsNothing, reason: 'nothing was typed yet');
      });

      testWidgets('three wrong PINs in a row say to remove the key and present it again', (tester) async {
        final (rig, fido) = await read(tester, FakeFidoKey(pin: '123456')..addPasskey('example.org', 'ada'));
        await rig.tapRow('securityKeys.passkeys.row');
        await rig.typePin('0000');
        await rig.typePin('0000');
        await rig.typePin('0000');

        expect(find.text(t('securityKeys.pin.locked')), findsOneWidget);
        expect(KeySheetRig.pinRequests(fido), hasLength(3));
        await rig.tap('export.close');

        await rig.tapRow('securityKeys.passkeys.row');
        expect(find.text(t('securityKeys.pin.locked')), findsOneWidget, reason: 'no PIN is asked for while the key takes none');
        expect(KeySheetRig.pinRequests(fido), hasLength(3));
      });

      testWidgets('a blocked PIN replaces the PIN actions with the explanation and the way to reset', (tester) async {
        final reader = FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard)..retries = 0;
        final (rig, fido) = await read(tester, reader);

        expect(
          find.descendant(of: keyRow('securityKeys.pin.change'), matching: find.text(t('securityKeys.pin.blocked.row'))),
          findsOneWidget,
        );
        for (final row in ['securityKeys.passkeys.row', 'securityKeys.fingerprints.row', 'securityKeys.pin.change']) {
          await rig.tapRow(row);
          expect(find.text(t('securityKeys.pin.blocked')), findsOneWidget, reason: row);
          expect(find.byType(TextField), findsNothing, reason: row);
          await rig.tap('export.close');
        }
        expect(KeySheetRig.pinRequests(fido), isEmpty);
        expect(find.text(t('securityKeys.reset.button')), findsOneWidget);
      });

      testWidgets('the last wrong PIN leads to the blocked explanation', (tester) async {
        final (rig, _) = await read(tester, FakeFidoKey(pin: '123456')..retries = 1);
        await rig.tapRow('securityKeys.passkeys.row');

        await rig.typePin('000000');

        expect(find.text(t('securityKeys.pin.blocked')), findsOneWidget);
      });
    });
  }

  testWidgets('over NFC the PIN is asked for before the key', (tester) async {
    final fido = FakeFidoKey(pin: '123456')..addPasskey('example.org', 'ada');
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, nfc);
    await rig.remove(device);
    final frames = rig.phone.sent.length;

    await rig.tapRow('securityKeys.passkeys.row');
    expect(find.text(t('securityKeys.pin.prompt.body')), findsOneWidget);
    expect(find.text(t('securityKeys.activity.present')), findsNothing, reason: 'the key is not asked for yet');
    await rig.typePin('123456');

    expect(find.text(t('securityKeys.activity.present')), findsOneWidget);
    expect(rig.phone.sent, hasLength(frames), reason: 'nothing was sent before the key came back');
    await rig.present(key, nfc);
    expect(find.text('example.org'), findsOneWidget);
  });

  testWidgets('on an iPhone the PIN is asked for before the NFC sheet comes up', (tester) async {
    final fido = FakeFidoKey(pin: '123456')..addPasskey('example.org', 'ada');
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester, capabilities: FakeSecurityKeys.iphone);
    rig.phone.arrive(key.device(kinds: nfc));
    await rig.tap('securityKeys.wait.iphone.read');
    final reads = rig.phone.calls.where((call) => call.startsWith('beginNfc')).length;

    await rig.tapRow('securityKeys.passkeys.row');
    expect(find.text(t('securityKeys.pin.prompt.body')), findsOneWidget);
    expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), hasLength(reads));

    rig.phone.arrive(key.device(kinds: nfc));
    await rig.typePin('123456');
    expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), hasLength(reads + 1));
    expect(find.text('example.org'), findsOneWidget);
  });

  testWidgets('setting a PIN over NFC collects both entries before the key is asked for', (tester) async {
    final fido = FakeFidoKey();
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, nfc);
    await rig.remove(device);

    await rig.tapRow('securityKeys.pin.set');
    await _fill(rig, ['123456', '123456'], 'securityKeys.pin.set.save');
    expect(find.text(t('securityKeys.activity.present')), findsWidgets);
    expect(fido.pin, isNull);

    await rig.present(key, nfc);
    expect(fido.pin, '123456');
    expect(keyRow('securityKeys.pin.change'), findsOneWidget);
  });

  test('link kinds used here are the two FIDO2 runs over on Android', () {
    expect(nfc.single, SecurityKeyLinkKind.nfc);
    expect(usb, contains(SecurityKeyLinkKind.usbHid));
  });
}
