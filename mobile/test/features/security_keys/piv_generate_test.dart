import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pem.dart';
import 'package:kemlock/crypto/keys/x509.dart';
import 'package:kemlock/features/security_keys/piv_generate_sheet.dart';
import 'package:kemlock/features/security_keys/piv_slot_sheet.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/security_key/piv/piv_operations.dart';
import 'package:kemlock/ui/ui.dart';

import '../../crypto/keys/x509_software.dart';
import '../../fakes/fake_piv_card.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

const _labels = {PivAlgorithm.rsa2048: 'RSA 2048', PivAlgorithm.eccP256: 'ECC P-256', PivAlgorithm.eccP384: 'ECC P-384'};

/// Fills in the open Add sheet and taps Generate (or Finish).
Future<void> _fill(
  PivRig rig,
  PivSlot slot, {
  PivAlgorithm algorithm = PivAlgorithm.eccP256,
  String name = 'Ada Example',
  String pin = pivFactoryPin,
  bool request = false,
  bool finish = false,
}) async {
  final tester = rig.tester;
  if (!finish) {
    await tester.tap(find.descendant(of: find.byType(SegmentedControl<PivAlgorithm>), matching: find.text(_labels[algorithm]!)));
    await tester.pumpAndSettle();
    if (request) {
      await tester.tap(find.text(t('piv.generate.request')));
      await tester.pumpAndSettle();
    }
  }
  await rig.type('piv.generate.name', name);
  if (slot.needsPin) await rig.type('piv.pin.field', pin);
  await rig.keys.tap(finish ? 'piv.generate.finish' : 'piv.generate.button');
}

void main() {
  for (final algorithm in PivAlgorithm.values) {
    testWidgets('${_labels[algorithm]} in each of the four slots, with the PIN only where the slot wants it', (tester) async {
      final rig = await openPivRig(tester);
      await rig.openCertificates();

      for (final slot in PivSlot.values) {
        rig.card.log.clear();
        await rig.addTo(slot);
        expect(find.byType(PivGenerateSheet), findsOneWidget);
        await _fill(rig, slot, algorithm: algorithm);

        expect(find.byType(PivGenerateSheet), findsNothing, reason: slot.id);
        final certificate = readCertificate(rig.card.certificate(slot)!);
        expect(certificate.subject.commonName, 'Ada Example');
        expect(certificate.notBefore, pivNow);
        expect(certificate.notAfter, DateTime.utc(2028, 11, 16, 9));
        expect(verifyOwnSignature(certificate), isTrue, reason: slot.id);
        expect(samePublicKey(certificate.publicKey!, publicOf(rig.card.keys[slot]!)), isTrue);
        expect(pivAlgorithmOf(certificate.publicKey), algorithm);
        expect(rig.changes.contains('verify'), slot.needsPin, reason: slot.id);
        expect(rig.changes, contains('generate ${slot.id} ${algorithm.id.toRadixString(16).padLeft(2, '0')}'));
      }
      expect(find.text(t('piv.row.slots', {'used': 4, 'total': 4})), findsOneWidget);
    });
  }

  testWidgets('a slot in use asks first, and nothing is sent until the confirmation', (tester) async {
    final card = FakePivCard();
    final before = await selfSignedFor(
      card.generate(PivSlot.authentication, PivAlgorithm.eccP256),
      notBefore: pivNow,
      notAfter: DateTime.utc(2028),
    );
    card.putCertificate(PivSlot.authentication, before);
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    await rig.tapSlot(PivSlot.authentication);
    await rig.keys.tapRow('piv.slot.generate');
    expect(find.text(t('piv.generate.inUse')), findsOneWidget);
    card.log.clear();

    await _fill(rig, PivSlot.authentication);
    expect(find.text(t('piv.generate.replace.body')), findsOneWidget);
    expect(rig.changes, isEmpty);
    await tester.tap(find.text(t('export.cancel')).last);
    await tester.pumpAndSettle();
    expect(rig.changes, isEmpty);
    expect(card.certificate(PivSlot.authentication), before);

    await rig.keys.tap('piv.generate.button');
    await tester.tap(find.widgetWithText(FilledButton, t('piv.generate.replace.confirm')));
    await tester.pumpAndSettle();
    expect(card.certificate(PivSlot.authentication), isNot(before));
  });

  testWidgets('a management key the card refuses generates nothing, and says so', (tester) async {
    final card = FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: List.filled(32, 0x42));
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    await rig.addTo(PivSlot.cardAuthentication);
    await _fill(rig, PivSlot.cardAuthentication);

    // Not the factory key, and no note: it is asked for.
    expect(find.text(t('piv.managementKey.ask.notFound')), findsOneWidget);
    await rig.type('piv.managementKey.field', '41' * 32);
    await rig.keys.tap('piv.continue');
    expect(find.text(t('piv.error.managementKey')), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(t('export.close')).last);
    await tester.pumpAndSettle();

    expect(card.keys, isEmpty);
    expect(card.log.where((line) => line.startsWith('generate') || line.startsWith('put')), isEmpty);
  });

  testWidgets('a typed management key with spaces and lower case is taken', (tester) async {
    final card = FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: List.filled(32, 0xab));
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    await rig.addTo(PivSlot.cardAuthentication);
    await _fill(rig, PivSlot.cardAuthentication);
    await rig.type('piv.managementKey.field', 'abab abab ' * 8);
    await rig.keys.tap('piv.continue');
    expect(card.certificate(PivSlot.cardAuthentication), isNotNull);
    expect(find.textContaining(t('piv.managementKey.used.typed')), findsOneWidget);
  });

  testWidgets('a card that signs wrongly gets no certificate, and the sheet says the key did not sign correctly', (tester) async {
    final card = FakePivCard()..signsWrongly = true;
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    await rig.addTo(PivSlot.keyManagement);
    await _fill(rig, PivSlot.keyManagement);

    expect(find.text(t('piv.error.badSignature')), findsOneWidget);
    expect(card.certificate(PivSlot.keyManagement), isNull);
    expect(card.log.where((line) => line.startsWith('put')), isEmpty);
  });

  testWidgets('the PIN typed is gone once the app was hidden', (tester) async {
    final rig = await openPivRig(tester);
    await rig.openCertificates();
    await rig.addTo(PivSlot.authentication);
    await rig.type('piv.pin.field', '123456');
    hideAndShow(tester);
    await tester.pump();
    expect(tester.widget<TextField>(find.widgetWithText(TextField, t('piv.pin.field')).last).controller!.text, isEmpty);
  });

  testWidgets('a wrong PIN generates nothing and says how many tries are left', (tester) async {
    final rig = await openPivRig(tester);
    await rig.openCertificates();
    await rig.addTo(PivSlot.authentication);
    await _fill(rig, PivSlot.authentication, pin: '000000');
    expect(find.text('${t('piv.pin.wrong')} ${t('securityKeys.pin.triesLeft', {'count': 2})}'), findsOneWidget);
    expect(rig.card.keys, isEmpty);
  });

  group('a request', () {
    testWidgets('is shared as a PKCS#10 request for the slot’s key, beside a placeholder for the same key', (tester) async {
      final rig = await openPivRig(tester);
      await rig.openCertificates();
      await rig.addTo(PivSlot.signature);
      await _fill(rig, PivSlot.signature, request: true);

      final file = rig.files.saved.single;
      expect((file.name, file.shared), ('9c-Ada Example.csr', true));
      final request = readCertificateRequest(readPemBlocks(utf8.decode(file.bytes)).single.decode());
      final slotKey = publicOf(rig.card.keys[PivSlot.signature]!);
      expect(request.verifies, isTrue);
      expect(request.subject.commonName, 'Ada Example');
      expect(samePublicKey(request.publicKey!, slotKey), isTrue);
      final placeholder = readCertificate(rig.card.certificate(PivSlot.signature)!);
      expect((placeholder.selfSigned, placeholder.notAfter), (true, DateTime.utc(2027, 11, 16, 9)));
      expect(samePublicKey(placeholder.publicKey!, slotKey), isTrue);
      expect(find.textContaining(t('piv.generate.done.request')), findsOneWidget);
    });

    testWidgets('the authority’s certificate replaces the placeholder', (tester) async {
      final rig = await openPivRig(tester);
      await rig.openCertificates();
      await rig.addTo(PivSlot.signature);
      await _fill(rig, PivSlot.signature, request: true);
      final authority = FakePivCard().generate(PivSlot.authentication, PivAlgorithm.eccP384);
      final issued = issueCertificate(
        subjectKey: publicOf(rig.card.keys[PivSlot.signature]!),
        commonName: 'Ada Example',
        authorityKey: authority,
        notBefore: pivNow,
        notAfter: DateTime.utc(2027, 11, 16),
      );

      // The toast that says the request was made goes first: it covers the foot of the sheet.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      await rig.tapSlot(PivSlot.signature);
      expect(find.byType(PivSlotSheet), findsOneWidget);
      rig.files.nextPick = PickedFile(name: 'issued.crt', bytes: issued);
      await rig.keys.tapRow('piv.slot.importAuthority');
      await rig.keys.tapRow('piv.import.file');
      await rig.keys.tap('piv.import.button');

      expect(rig.card.certificate(PivSlot.signature), issued);
      expect(find.text(t('piv.slot.importAuthority')), findsNothing);
    });
  });

  group('a key taken away after generating', () {
    testWidgets('is said to have a new key and no certificate, and Finish gives that key its certificate', (tester) async {
      final rig = await openPivRig(tester, kinds: nfc);
      await rig.openCertificates();
      await rig.addTo(PivSlot.authentication);
      // The key leaves as the first signature is asked for: generated, not yet certified.
      rig.phone.removeWhen = (frame) => frame.length > 3 && frame[1] == 0x87 && frame[3] == PivSlot.authentication.key;
      await _fill(rig, PivSlot.authentication);

      expect(find.text(t('piv.generate.dropped')), findsOneWidget);
      expect(rig.card.keys[PivSlot.authentication], isNotNull);
      expect(rig.card.certificate(PivSlot.authentication), isNull);

      rig.phone.removeWhen = null;
      await rig.keys.present(rig.key, nfc);
      await rig.keys.tap('piv.generate.finish');

      final certificate = readCertificate(rig.card.certificate(PivSlot.authentication)!);
      expect(samePublicKey(certificate.publicKey!, publicOf(rig.card.keys[PivSlot.authentication]!)), isTrue);
      expect(rig.card.log.where((line) => line.startsWith('generate')), hasLength(1), reason: 'finishing makes no new key');
    });

    testWidgets('after the sheet is closed, a card with slot metadata still offers Finish; a standard-only one reads Empty', (
      tester,
    ) async {
      for (final maker in [true, false]) {
        final rig = await openPivRig(
          tester,
          card: FakePivCard(makerCommands: maker),
          kinds: nfc,
        );
        await rig.openCertificates();
        await rig.addTo(PivSlot.cardAuthentication);
        rig.phone.removeWhen = (frame) => frame.length > 3 && frame[1] == 0x87 && frame[3] == PivSlot.cardAuthentication.key;
        await _fill(rig, PivSlot.cardAuthentication);
        expect(find.text(t('piv.generate.dropped')), findsOneWidget);
        await tester.tap(find.bySemanticsLabel(t('export.close')).last);
        await tester.pumpAndSettle();
        rig.phone.removeWhen = null;
        await rig.keys.present(rig.key, nfc);

        expect(
          find.descendant(
            of: find.ancestor(of: find.text('9e'), matching: find.byType(GroupRow)).last,
            matching: find.text(t('piv.empty')),
          ),
          findsOneWidget,
        );
        await rig.addTo(PivSlot.cardAuthentication);
        expect(find.text(t('piv.generate.keyOnly')), maker ? findsOneWidget : findsNothing, reason: 'maker: $maker');
        expect(find.text(t('piv.generate.finish')), maker ? findsOneWidget : findsNothing);
        if (maker) {
          await _fill(rig, PivSlot.cardAuthentication, finish: true);
          expect(
            samePublicKey(
              readCertificate(rig.card.certificate(PivSlot.cardAuthentication)!).publicKey!,
              publicOf(rig.card.keys[PivSlot.cardAuthentication]!),
            ),
            isTrue,
          );
        }
      }
    });
  });

  testWidgets('the identifier objects are written on a card without them, and the identifier renewed with each certificate', (
    tester,
  ) async {
    final rig = await openPivRig(tester);
    expect(rig.card.objects.containsKey(pivCccObject), isFalse);
    expect(rig.card.objects.containsKey(pivChuidObject), isFalse);
    await rig.openCertificates();

    await rig.addTo(PivSlot.cardAuthentication);
    await _fill(rig, PivSlot.cardAuthentication);
    final ccc = rig.card.objects[pivCccObject];
    final first = readPivChuidGuid(pivTlv(0x53, rig.card.objects[pivChuidObject]!));
    expect(ccc, isNotNull);
    expect(first, isNotNull);

    await rig.addTo(PivSlot.keyManagement);
    await _fill(rig, PivSlot.keyManagement);
    expect(rig.card.objects[pivCccObject], ccc);
    expect(readPivChuidGuid(pivTlv(0x53, rig.card.objects[pivChuidObject]!)), isNot(first));
  });
}
