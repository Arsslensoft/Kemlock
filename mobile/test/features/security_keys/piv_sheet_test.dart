import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_piv_card.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

/// The row of [slot] on the Certificates sheet.
Finder _slotRow(PivSlot slot) => find.ancestor(of: find.text(slot.id), matching: find.byType(GroupRow)).last;

Finder _inSlot(PivSlot slot, Finder finder) => find.descendant(of: _slotRow(slot), matching: finder);

void main() {
  /// A card with certificates in 9a, ending on [authentication], and 9c,
  /// ending on [signature].
  Future<FakePivCard> twoSlots({required DateTime authentication, required DateTime signature}) async {
    final card = FakePivCard();
    card.putCertificate(
      PivSlot.authentication,
      await selfSignedFor(
        card.generate(PivSlot.authentication, PivAlgorithm.eccP256),
        notBefore: DateTime.utc(2026),
        notAfter: authentication,
      ),
    );
    card.putCertificate(
      PivSlot.signature,
      await selfSignedFor(card.generate(PivSlot.signature, PivAlgorithm.eccP384), notBefore: DateTime.utc(2026), notAfter: signature),
    );
    return card;
  }

  testWidgets('two slots in use, two Empty with Add, and nothing asked for', (tester) async {
    final card = await twoSlots(authentication: DateTime.utc(2028, 3, 3, 12), signature: DateTime.utc(2029));
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();

    for (final id in ['piv.slot.9a', 'piv.slot.9c', 'piv.slot.9d', 'piv.slot.9e']) {
      expect(find.text(t(id)), findsOneWidget);
    }
    expect(_inSlot(PivSlot.authentication, find.text('ECC P-256 · ${t('piv.slot.untilDate', {'date': 'Mar 3, 2028'})}')), findsOneWidget);
    expect(_inSlot(PivSlot.signature, find.textContaining('ECC P-384')), findsOneWidget);
    for (final slot in [PivSlot.keyManagement, PivSlot.cardAuthentication]) {
      expect(_inSlot(slot, find.text(t('piv.empty'))), findsOneWidget);
      expect(_inSlot(slot, find.text(t('piv.add'))), findsOneWidget);
    }
    expect(find.byType(TextField), findsNothing, reason: 'no PIN was asked for');
    expect(card.log.where((line) => line == 'verify'), isEmpty);
  });

  testWidgets('a certificate ending in 12 days is tagged, an ended one Expired, one two years off not at all', (tester) async {
    final card = await twoSlots(authentication: pivNow.add(const Duration(days: 12)), signature: pivNow.subtract(const Duration(days: 1)));
    card.putCertificate(
      PivSlot.keyManagement,
      await selfSignedFor(
        card.generate(PivSlot.keyManagement, PivAlgorithm.eccP256),
        notBefore: pivNow,
        notAfter: DateTime.utc(2028, 11, 16, 12),
      ),
    );
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();

    expect(_inSlot(PivSlot.authentication, find.text(t('keys.standing.expiresIn', {'days': 12}).toUpperCase())), findsOneWidget);
    expect(_inSlot(PivSlot.authentication, find.text('ECC P-256')), findsOneWidget, reason: 'the tag stands for the date');
    expect(_inSlot(PivSlot.signature, find.text(t('keys.standing.expired').toUpperCase())), findsOneWidget);
    expect(_inSlot(PivSlot.keyManagement, find.byType(StatusTag)), findsNothing);
    expect(_inSlot(PivSlot.keyManagement, find.textContaining('Nov 16, 2028')), findsOneWidget);
  });

  testWidgets('over NFC a card that keeps its certificates to the contact interface says to plug the key in', (tester) async {
    final card = (await twoSlots(authentication: DateTime.utc(2028), signature: DateTime.utc(2028)))..refuseOverNfc = true;
    final rig = await openPivRig(tester, card: card, kinds: nfc);
    await rig.openCertificates();

    for (final slot in [PivSlot.authentication, PivSlot.signature, PivSlot.keyManagement]) {
      expect(_inSlot(slot, find.text(t('piv.slot.needsContact'))), findsOneWidget);
    }
    expect(_inSlot(PivSlot.cardAuthentication, find.text(t('piv.empty'))), findsOneWidget);
  });

  testWidgets('the PIN’s tries, the PUK’s from metadata only, and no try spent', (tester) async {
    final rig = await openPivRig(tester);
    await rig.openCertificates();
    expect(find.widgetWithText(GroupRow, t('piv.pin')), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(GroupRow, t('piv.pin')), matching: find.text(t('piv.triesLeft', {'count': 3}))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.widgetWithText(GroupRow, t('piv.puk')), matching: find.text(t('piv.triesLeft', {'count': 3}))),
      findsOneWidget,
    );
    expect((rig.card.pinTries, rig.card.pukTries), (3, 3));
  });

  testWidgets('a standard-only card shows the PIN’s tries, no PUK count, no factory codes and no reset', (tester) async {
    final rig = await openPivRig(tester, card: FakePivCard(makerCommands: false)..pinTries = 2);
    await rig.openCertificates();

    expect(
      find.descendant(of: find.widgetWithText(GroupRow, t('piv.pin')), matching: find.text(t('piv.triesLeft', {'count': 2}))),
      findsOneWidget,
    );
    expect(find.descendant(of: find.widgetWithText(GroupRow, t('piv.puk')), matching: find.textContaining('left')), findsNothing);
    expect(find.textContaining('123456'), findsNothing);
    expect(find.text(t('piv.reset.row')), findsNothing);
    // The published management key was tried, with no PIN or PUK
    expect(find.text(t('piv.factoryDefault').toUpperCase()), findsOneWidget);
    expect(find.text(t('piv.managementKey.cannot')), findsOneWidget);
    expect(rig.card.pinTries, 2);
  });

  testWidgets('a factory management key has its tag, the warning and the button; a changed one none of them', (tester) async {
    final rig = await openPivRig(tester);
    await rig.openCertificates();
    expect(find.text(t('piv.factoryDefault').toUpperCase()), findsOneWidget);
    expect(find.text(t('piv.defaultWarning')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, t('piv.changeManagementKey')), findsOneWidget);
    expect(find.text(t('piv.codes.factory', {'codes': 'both'})), findsOneWidget);

    final changed = await openPivRig(
      tester,
      card: FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: List.filled(32, 7), pin: '987654', puk: '87654321'),
    );
    await changed.openCertificates();
    expect(find.text(t('piv.factoryDefault').toUpperCase()), findsNothing);
    expect(find.text(t('piv.defaultWarning')), findsNothing);
    expect(find.widgetWithText(FilledButton, t('piv.changeManagementKey')), findsNothing);
    expect(
      find.descendant(of: find.widgetWithText(GroupRow, t('piv.managementKey')), matching: find.text(t('piv.managementKey.changed'))),
      findsOneWidget,
    );
    expect(find.textContaining('123456'), findsNothing);
    expect(find.text(t('piv.reset.row')), findsOneWidget);
  });

  testWidgets('a slot holding bytes that are not a certificate says so', (tester) async {
    final card = FakePivCard()
      ..objects[PivSlot.keyManagement.object] = Uint8List.fromList([0x70, 0x03, 0x30, 0x01, 0x00, 0x71, 0x01, 0x00]);
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    expect(_inSlot(PivSlot.keyManagement, find.text(t('piv.slot.unreadable'))), findsOneWidget);
  });

  testWidgets('a key that is taken away keeps its sheet, read again when it is back', (tester) async {
    final card = await twoSlots(authentication: DateTime.utc(2028), signature: DateTime.utc(2028));
    final rig = await openPivRig(tester, card: card, kinds: {SecurityKeyLinkKind.nfc});
    await rig.openCertificates();
    await rig.keys.remove(rig.device);
    expect(find.text(t('piv.slot.9a')), findsOneWidget);
  });
}
