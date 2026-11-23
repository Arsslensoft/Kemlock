import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/piv_sheet.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_piv_card.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

void main() {
  testWidgets('the row counts the slots that hold a certificate', (tester) async {
    final card = FakePivCard();
    for (final slot in [PivSlot.authentication, PivSlot.signature]) {
      card.putCertificate(
        slot,
        await selfSignedFor(card.generate(slot, PivAlgorithm.eccP256), notBefore: pivNow, notAfter: DateTime.utc(2028)),
      );
    }

    await openPivRig(tester, card: card);

    expect(find.text(t('securityKeys.section.also').toUpperCase()), findsOneWidget);
    expect(keyRow('piv.title'), findsOneWidget);
    expect(find.text(t('piv.row.slots', {'used': 2, 'total': 4})), findsOneWidget);
    // In the one "Also on this key" group, after Codes
    final also = find.ancestor(of: keyRow('piv.title'), matching: find.byType(Group));
    expect(find.descendant(of: also, matching: keyRow('keyCodes.row')), findsOneWidget);
    expect(tester.getTopLeft(keyRow('keyCodes.row')).dy, lessThan(tester.getTopLeft(keyRow('piv.title')).dy));
    // Read without a PIN
    expect(card.log, isNot(contains('verify')));
  });

  testWidgets('a key without a PIV application has no row, and the group has Codes alone', (tester) async {
    final rig = await openKeySheet(tester);
    await rig.present(FakeKey(productName: 'Example Key', ctap: FakeFidoKey()), usb);

    expect(find.text(t('securityKeys.passkeys.row')), findsOneWidget);
    expect(keyRow('piv.title'), findsNothing);
    expect(find.text(t('securityKeys.section.also').toUpperCase()), findsOneWidget);
    expect(keyRow('keyCodes.row'), findsOneWidget);
  });

  testWidgets('a key with PIV and no FIDO2 has the row, under what the sheet says of FIDO2', (tester) async {
    await openPivRig(tester, fido: false, kinds: {SecurityKeyLinkKind.usbCcid});
    expect(find.text(t('securityKeys.noFido')), findsOneWidget);
    expect(find.text(t('piv.row.slots', {'used': 0, 'total': 4})), findsOneWidget);
  });

  testWidgets('the row opens the Certificates sheet', (tester) async {
    final rig = await openPivRig(tester);

    await rig.openCertificates();

    expect(find.byType(PivSheet), findsOneWidget);
    expect(find.text(t('piv.caption')), findsOneWidget);
  });

  testWidgets('on an iPhone the PIV application is read under the same NFC sheet as the rest', (tester) async {
    final card = FakePivCard();
    final rig = await openKeySheet(tester, capabilities: FakeSecurityKeys.iphone, overrides: [FakePivNotes().asOverride]);
    rig.phone.arrive(FakeKey(ctap: FakeFidoKey(), applets: [card]).device(kinds: nfc));
    await rig.tap('securityKeys.wait.iphone.read');

    expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), hasLength(1));
    expect(find.text(t('piv.row.slots', {'used': 0, 'total': 4})), findsOneWidget);
    expect(card.log, contains('select'));
    expect(tester.takeException(), isNull);
    expect(find.byType(Scaffold), findsWidgets);
  });
}
