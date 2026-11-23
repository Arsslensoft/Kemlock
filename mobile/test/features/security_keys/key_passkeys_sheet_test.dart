import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/key_passkeys_sheet.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart';

const _sites = ['github.com', 'google.com', 'microsoft.com', 'cloudflare.com', 'example.org', 'example.net', 'example.com'];

FakeFidoKey _withSeven(FakeFidoKey fido) {
  for (final site in _sites) {
    fido.addPasskey(site, 'ada@$site');
  }
  return fido;
}

/// Opens the passkey list of [fido] over [kinds], typing the PIN.
Future<KeySheetRig> _open(WidgetTester tester, FakeFidoKey fido, {Set<dynamic>? kinds}) async {
  final rig = await openKeySheet(tester);
  await rig.present(FakeKey(productName: 'Example Key 5C', ctap: fido), kinds == null ? usb : kinds.cast());
  await rig.tapRow('securityKeys.passkeys.row');
  await rig.typePin('123456');
  return rig;
}

Finder _delete(String site) =>
    find.descendant(of: find.widgetWithText(GroupRow, site), matching: find.text(t('securityKeys.passkeys.delete')));

void main() {
  for (final (name, make) in [('standard', () => FakeFidoKey(pin: '123456')), ('preview-only', () => FakeFidoKey.ctap20(pin: '123456'))]) {
    testWidgets('a $name key shows its passkeys, five first and "Show 2 more" for the rest', (tester) async {
      await _open(tester, _withSeven(make()));

      expect(find.byType(KeyPasskeysSheet), findsOneWidget);
      expect(find.text('Example Key 5C'), findsWidgets);
      expect(find.text(t('securityKeys.passkeys.used', {'used': 7, 'total': 100})), findsOneWidget);
      expect(find.bySemanticsLabel(t('securityKeys.passkeys.used.label', {'used': 7, 'total': 100})), findsOneWidget);
      for (final site in _sites.take(5)) {
        expect(find.text(site), findsOneWidget);
        expect(find.text('ada@$site'), findsOneWidget);
      }
      expect(find.text(_sites[5]), findsNothing);
      expect(find.text(t('securityKeys.passkeys.warning')), findsOneWidget);
      expect(find.text(t('securityKeys.passkeys.caption')), findsOneWidget);

      await tester.tap(find.text(t('securityKeys.passkeys.showMore', {'count': 2})));
      await tester.pumpAndSettle();

      expect(find.text(_sites[5]), findsOneWidget);
      expect(find.text(_sites[6]), findsOneWidget);
      expect(find.text(t('securityKeys.passkeys.showMore', {'count': 2})), findsNothing);
    });
  }

  testWidgets('the count is absent before the PIN and shown once it was given, in the sheet’s row too', (tester) async {
    final rig = await openKeySheet(tester);
    await rig.present(
      FakeKey(
        productName: 'Example Key',
        ctap: _withSeven(FakeFidoKey(pin: '123456')),
      ),
      usb,
    );
    final count = t('securityKeys.passkeys.count', {'used': 7, 'total': 100});
    expect(count, '7 / 100');
    expect(find.text(count), findsNothing);

    await rig.tapRow('securityKeys.passkeys.row');
    await rig.typePin('123456');
    await rig.close();

    expect(find.descendant(of: keyRow('securityKeys.passkeys.row'), matching: find.text(count)), findsOneWidget);
  });

  testWidgets('a key with no passkeys says so', (tester) async {
    await _open(tester, FakeFidoKey(pin: '123456'));

    expect(find.text(t('securityKeys.passkeys.empty')), findsOneWidget);
    expect(find.text(t('securityKeys.passkeys.used', {'used': 0, 'total': 100})), findsOneWidget);
    expect(find.text(t('securityKeys.passkeys.warning')), findsOneWidget);
  });

  testWidgets('a site with several users lists each of them', (tester) async {
    final fido = FakeFidoKey(pin: '123456')
      ..addPasskey('example.org', 'ada')
      ..addPasskey('example.org', 'grace')
      ..addPasskey('example.org', 'edsger');
    await _open(tester, fido);

    expect(find.text('example.org'), findsNWidgets(3));
    for (final user in ['ada', 'grace', 'edsger']) {
      expect(find.text(user), findsOneWidget);
    }
  });

  testWidgets('a key removed while the list is read shows no partial list', (tester) async {
    final fido = _withSeven(FakeFidoKey(pin: '123456'));
    final rig = await openKeySheet(tester);
    final device = await rig.present(FakeKey(ctap: fido), nfc);
    var enumerated = 0;
    fido.onRequest = (command, parameters) {
      if (command == 0x0a && parameters[1] == 4 && ++enumerated == 3) rig.phone.remove(device);
    };

    await rig.tapRow('securityKeys.passkeys.row');
    await rig.typePin('123456');

    expect(find.byType(KeyPasskeysSheet), findsNothing);
    expect(find.text('github.com'), findsNothing);
    expect(find.text(t('securityKeys.error.removed')), findsOneWidget);
  });

  testWidgets('deleting names the site and the user, removes the row, drops the count and reads the key again', (tester) async {
    final fido = _withSeven(FakeFidoKey(pin: '123456'));
    await _open(tester, fido);
    final mark = fido.requests.length;

    await tester.tap(_delete('github.com'));
    await tester.pumpAndSettle();
    expect(find.text(t('securityKeys.passkeys.delete.body', {'site': 'github.com', 'user': 'ada@github.com'})), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t('securityKeys.passkeys.delete')));
    await tester.pumpAndSettle();

    expect(fido.credentials.map((credential) => credential.rpId), isNot(contains('github.com')));
    expect(find.text('github.com'), findsNothing);
    expect(find.text(t('securityKeys.passkeys.used', {'used': 6, 'total': 100})), findsOneWidget);
    expect(find.text(t('securityKeys.passkeys.deleted')), findsOneWidget);
    final after = fido.requests.sublist(mark);
    expect(after.indexOf('a.6'), lessThan(after.indexOf('a.1')), reason: 'the count is read after the delete');
    expect(after, contains('a.2'), reason: 'and so is the list');
    expect(find.text(t('securityKeys.passkeys.showMore', {'count': 1})), findsOneWidget);
  });

  testWidgets('cancelling the confirmation sends nothing to the key', (tester) async {
    final fido = _withSeven(FakeFidoKey(pin: '123456'));
    final rig = await _open(tester, fido);
    final frames = rig.phone.sent.length;

    await tester.tap(_delete('github.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, t('export.cancel')));
    await tester.pumpAndSettle();

    expect(rig.phone.sent, hasLength(frames));
    expect(fido.credentials, hasLength(7));
    expect(find.text('github.com'), findsOneWidget);
  });

  testWidgets('a key that leaves before answering a delete: "could not confirm", and the list is read again when it is back', (
    tester,
  ) async {
    final fido = _withSeven(FakeFidoKey(pin: '123456'));
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester);
    final device = await rig.present(key, nfc);
    await rig.tapRow('securityKeys.passkeys.row');
    await rig.typePin('123456');
    fido.onRequest = (command, parameters) {
      // The key acts on the delete and leaves before the app hears of it.
      if (command == 0x0a && parameters[1] == 6) {
        fido.onRequest = null;
        rig.phone
          ..removeWhen = ((_) => true)
          ..removeAfterProcessing = true;
      }
    };
    rig.phone.removeWhen = null;

    await tester.tap(_delete('github.com'));
    await tester.pumpAndSettle();
    fido.onRequest = (command, parameters) {
      if (command == 0x0a && parameters[1] == 6) rig.phone.remove(device);
    };
    await tester.tap(find.widgetWithText(FilledButton, t('securityKeys.passkeys.delete')));
    await tester.pumpAndSettle();

    expect(find.text(t('securityKeys.error.unconfirmed')), findsOneWidget);
    expect(find.text(t('securityKeys.passkeys.deleted')), findsNothing, reason: 'the app does not claim the change happened');
    expect(find.text('github.com'), findsOneWidget, reason: 'nor that it did not: the list is as it was read');

    fido.onRequest = null;
    await rig.present(key, nfc);
    // The PIN went with the connection the key left: a key held to the phone again is asked for it
    await rig.typePin('123456');

    expect(find.text(t('securityKeys.error.unconfirmed')), findsNothing);
    expect(find.text('github.com'), findsNothing, reason: 'the key had deleted it');
    expect(find.text(t('securityKeys.passkeys.used', {'used': 6, 'total': 100})), findsOneWidget);
  });

  testWidgets('on an iPhone a list and a delete each ask for the PIN, then for the key', (tester) async {
    final fido = _withSeven(FakeFidoKey(pin: '123456'));
    final key = FakeKey(ctap: fido);
    final rig = await openKeySheet(tester, capabilities: FakeSecurityKeys.iphone);
    rig.phone.arrive(key.device(kinds: nfc));
    await rig.tap('securityKeys.wait.iphone.read');
    final reads = rig.phone.calls.where((call) => call.startsWith('beginNfc')).length;

    rig.phone.arrive(key.device(kinds: nfc));
    await rig.tapRow('securityKeys.passkeys.row');
    await rig.typePin('123456');
    expect(find.text('github.com'), findsOneWidget);

    rig.phone.arrive(key.device(kinds: nfc));
    await tester.tap(_delete('github.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t('securityKeys.passkeys.delete')));
    await tester.pumpAndSettle();
    // Each read is a connection of its own, and the key read next may be another of the same model
    expect(find.text(t('securityKeys.pin.prompt.body')), findsOneWidget, reason: 'asked before the key is held to the phone');
    await rig.typePin('123456');

    expect(find.text('github.com'), findsNothing);
    expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), hasLength(reads + 2), reason: 'the key was asked for twice');
    expect(fido.credentials, hasLength(6));
  });
}
