import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';

import '../fakes/fake_piv_card.dart';
import '../features/security_keys/piv_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the Certificates sheet (`Piv.dc.html`), the Certificates row of
/// the Security key sheet (`SecurityKey.dc.html`) and the sheets the
/// mockup does not draw, in dark and light, on a fake key:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/piv_test.dart
void main() {
  /// The mockup's card: 9a in use until 3 Mar 2028, 9c an RSA key ending
  /// in 12 days, 9d and 9e empty, every code the factory one.
  Future<FakePivCard> mockupCard() async {
    final card = FakePivCard();
    card.putCertificate(
      PivSlot.authentication,
      await selfSignedFor(
        card.generate(PivSlot.authentication, PivAlgorithm.eccP256),
        notBefore: DateTime.utc(2026, 3, 3, 12),
        notAfter: DateTime.utc(2028, 3, 3, 12),
      ),
    );
    card.putCertificate(
      PivSlot.signature,
      await selfSignedFor(
        card.generate(PivSlot.signature, PivAlgorithm.rsa2048),
        notBefore: DateTime.utc(2025, 11, 28),
        notAfter: pivNow.add(const Duration(days: 12)),
      ),
    );
    return card;
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<PivRig> open(WidgetTester tester, FakePivCard card) {
      usePhoneScreen(tester);
      return openPivRig(tester, card: card, brightness: brightness, tall: false);
    }

    testScreenshot('piv: the Certificates row on the Security key sheet, $name', (tester) async {
      await open(tester, await mockupCard());
      await takeScreenshot(tester, 'piv_row_$name');
    });

    testScreenshot('piv: the Certificates sheet as the mockup draws it, $name', (tester) async {
      final rig = await open(tester, await mockupCard());
      await rig.openCertificates();
      await takeScreenshot(tester, 'piv_mockup_$name');
    });

    testScreenshot('piv: the Certificates sheet with every code changed, $name', (tester) async {
      final card = await mockupCard()
        ..pin = '271828'
        ..puk = '31415926'
        ..managementKeyType = PivManagementKeyType.aes256
        ..managementKey = Uint8List.fromList(List.filled(32, 7));
      final rig = await open(tester, card);
      await rig.openCertificates();
      await takeScreenshot(tester, 'piv_changed_$name');
    });

    testScreenshot('piv: a slot’s certificate, $name', (tester) async {
      final rig = await open(tester, await mockupCard());
      await rig.openCertificates();
      await rig.tapSlot(PivSlot.authentication);
      await takeScreenshot(tester, 'piv_slot_$name');
    });

    testScreenshot('piv: the Add sheet, $name', (tester) async {
      final rig = await open(tester, await mockupCard());
      await rig.openCertificates();
      await rig.addTo(PivSlot.keyManagement);
      await rig.type('piv.generate.name', 'Ada Example');
      await takeScreenshot(tester, 'piv_add_$name');
    });

    testScreenshot('piv: the management key sheet, $name', (tester) async {
      final rig = await open(tester, await mockupCard());
      await rig.openCertificates();
      await rig.keys.tapRow('piv.managementKey');
      await takeScreenshot(tester, 'piv_management_key_$name');
    });

    testScreenshot('piv: the PIN sheet, $name', (tester) async {
      final rig = await open(
        tester,
        await mockupCard()
          ..pinTries = 1,
      );
      await rig.openCertificates();
      await rig.keys.tapRow('piv.pin');
      await takeScreenshot(tester, 'piv_pin_$name');
    });

    testScreenshot('piv: the reset confirmation, $name', (tester) async {
      final rig = await open(tester, await mockupCard());
      await rig.openCertificates();
      await tester.ensureVisible(keyRow('piv.reset.row'));
      await tester.pumpAndSettle();
      await rig.keys.tapRow('piv.reset.row');
      expect(find.text(t('piv.reset.lost')), findsOneWidget);
      await takeScreenshot(tester, 'piv_reset_$name');
    });
  }
}
