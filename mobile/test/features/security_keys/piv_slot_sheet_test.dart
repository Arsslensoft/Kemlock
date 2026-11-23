import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pem.dart';
import 'package:kemlock/crypto/keys/x509.dart';
import 'package:kemlock/features/security_keys/piv_slot_sheet.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../crypto/keys/x509_software.dart';
import '../../fakes/fake_piv_card.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

final _from = DateTime.utc(2026, 11, 1, 12);
final _until = DateTime.utc(2028, 11, 1, 12);

/// The value of the detail row named by the message [id].
Finder _detail(String id, String value) => find.descendant(of: find.widgetWithText(GroupRow, t(id)), matching: find.text(value));

void main() {
  /// Opens the sheet of [slot] on [card].
  Future<PivRig> openSlot(WidgetTester tester, FakePivCard card, PivSlot slot) async {
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    await rig.tapSlot(slot);
    expect(find.byType(PivSlotSheet), findsOneWidget);
    return rig;
  }

  /// Picks [bytes] as the file to import into the open slot sheet.
  Future<void> importFile(PivRig rig, List<int> bytes, {String name = 'cert.crt'}) async {
    rig.files.nextPick = PickedFile(name: name, bytes: Uint8List.fromList(bytes));
    await rig.keys.tapRow(find.text(t('piv.slot.importAuthority')).evaluate().isEmpty ? 'piv.slot.import' : 'piv.slot.importAuthority');
    await rig.keys.tapRow('piv.import.file');
  }

  group('the details', () {
    testWidgets('of a self-signed certificate: the name, self-signed, the dates, serial, algorithm and fingerprint', (tester) async {
      final card = FakePivCard();
      final der = await selfSignedFor(card.generate(PivSlot.authentication, PivAlgorithm.eccP256), notBefore: _from, notAfter: _until);
      card.putCertificate(PivSlot.authentication, der);
      await openSlot(tester, card, PivSlot.authentication);

      final certificate = readCertificate(der);
      expect(_detail('piv.slot.names', 'Ada Example'), findsOneWidget);
      expect(_detail('piv.slot.issuer', t('piv.slot.selfSigned')), findsOneWidget);
      expect(_detail('piv.slot.from', 'Nov 1, 2026'), findsOneWidget);
      expect(_detail('piv.slot.until', 'Nov 1, 2028'), findsOneWidget);
      expect(_detail('piv.slot.algorithm', 'ECC P-256'), findsOneWidget);
      expect(_detail('piv.slot.serial', certificate.serialText), findsOneWidget);
      expect(_detail('piv.slot.fingerprint', pivFingerprint(certificate.sha256Fingerprint)), findsOneWidget);
      expect(find.text(t('piv.slot.9a.purpose')), findsOneWidget);
      expect(find.text(t('piv.slot.importAuthority')), findsOneWidget, reason: 'a self-signed one may be a placeholder');
    });

    testWidgets('of an issued certificate: who issued it, and an OpenSSL one read as OpenSSL reads it', (tester) async {
      final card = FakePivCard();
      final der = File('test/fixtures/keys/openssl/x509/p256.issued.der').readAsBytesSync();
      card.putCertificate(PivSlot.signature, der);
      await openSlot(tester, card, PivSlot.signature);

      expect(_detail('piv.slot.issuer', 'Example Test CA'), findsOneWidget);
      expect(_detail('piv.slot.serial', '09'), findsOneWidget);
      // openssl x509 -fingerprint -sha256, from the fixture's .txt
      final text = File('test/fixtures/keys/openssl/x509/p256.issued.txt').readAsStringSync();
      final fingerprint = RegExp(r'sha256 Fingerprint=([0-9A-F:]+)').firstMatch(text)![1]!;
      expect(_detail('piv.slot.fingerprint', fingerprint), findsOneWidget);
      expect(find.text(t('piv.slot.import')), findsOneWidget);
      expect(find.text(t('piv.slot.importAuthority')), findsNothing);
    });

    testWidgets('of something that is not a certificate: said so, with export and replacement still offered', (tester) async {
      final junk = [0x70, 0x03, 0x30, 0x01, 0x00, 0x71, 0x01, 0x00];
      final card = FakePivCard()..objects[PivSlot.keyManagement.object] = Uint8List.fromList(junk);
      final rig = await openSlot(tester, card, PivSlot.keyManagement);

      expect(find.text(t('piv.slot.unreadable.body')), findsOneWidget);
      expect(find.text(t('piv.slot.import')), findsOneWidget);
      expect(find.text(t('piv.slot.generate')), findsOneWidget);
      await rig.keys.tapRow('piv.slot.export');
      expect(rig.files.saved.single.name, '9d-slot.bin');
      expect(rig.files.saved.single.bytes, [0x30, 0x01, 0x00], reason: 'as the card holds it, untouched');
    });
  });

  group('export', () {
    testWidgets('shares a .crt whose decoded bytes are the card’s, and copies the same text, with no PIN or management key', (
      tester,
    ) async {
      final card = FakePivCard();
      final der = await selfSignedFor(card.generate(PivSlot.authentication, PivAlgorithm.eccP256), notBefore: _from, notAfter: _until);
      card.putCertificate(PivSlot.authentication, der);
      final copied = <String>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add('${(call.arguments as Map<Object?, Object?>)['text']}');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final rig = await openSlot(tester, card, PivSlot.authentication);
      card.log.clear();

      await rig.keys.tapRow('piv.slot.export');
      final file = rig.files.saved.single;
      expect((file.name, file.shared), ('9a-Ada Example.crt', true));
      final pem = utf8.decode(file.bytes);
      expect(readPemBlocks(pem).single.decode(), card.certificate(PivSlot.authentication));
      expect(readPemBlocks(pem).single.label, 'CERTIFICATE');

      await rig.keys.tapRow('piv.slot.copy');
      expect(copied.single, pem);
      expect(card.log.where((line) => line == 'verify' || line == 'auth'), isEmpty);
    });
  });

  group('import', () {
    testWidgets('a certificate for the slot’s key replaces the one there', (tester) async {
      final card = FakePivCard();
      final key = card.generate(PivSlot.authentication, PivAlgorithm.eccP256);
      card.putCertificate(PivSlot.authentication, await selfSignedFor(key, notBefore: _from, notAfter: _until));
      final authority = FakePivCard().generate(PivSlot.authentication, PivAlgorithm.eccP384);
      final issued = issueCertificate(
        subjectKey: publicOf(key),
        commonName: 'Ada Example',
        authorityKey: authority,
        notBefore: _from,
        notAfter: _until,
      );
      final rig = await openSlot(tester, card, PivSlot.authentication);

      await importFile(rig, utf8.encode(writePem('CERTIFICATE', issued)));
      expect(find.text(t('piv.import.unchecked')), findsNothing);
      await rig.keys.tap('piv.import.button');

      expect(card.certificate(PivSlot.authentication), issued);
      expect(find.textContaining(t('piv.import.done')), findsOneWidget);
      expect(find.textContaining(t('piv.managementKey.used.factory')), findsOneWidget);
      expect(_detail('piv.slot.issuer', 'Example Test CA'), findsOneWidget);
    });

    testWidgets('one for another key is refused, and the slot is unchanged', (tester) async {
      final card = FakePivCard();
      final der = await selfSignedFor(card.generate(PivSlot.authentication, PivAlgorithm.eccP256), notBefore: _from, notAfter: _until);
      card.putCertificate(PivSlot.authentication, der);
      final other = await selfSignedFor(
        FakePivCard().generate(PivSlot.authentication, PivAlgorithm.eccP256),
        notBefore: _from,
        notAfter: _until,
      );
      final rig = await openSlot(tester, card, PivSlot.authentication);
      card.log.clear();

      await importFile(rig, other);

      expect(find.text(t('piv.import.mismatch')), findsOneWidget);
      expect(card.certificate(PivSlot.authentication), der);
      expect(card.log, isEmpty, reason: 'nothing was sent');
    });

    testWidgets('a private key and a request are each named and refused before anything is sent', (tester) async {
      final card = FakePivCard();
      card.putCertificate(
        PivSlot.authentication,
        await selfSignedFor(card.generate(PivSlot.authentication, PivAlgorithm.eccP256), notBefore: _from, notAfter: _until),
      );
      final rig = await openSlot(tester, card, PivSlot.authentication);
      card.log.clear();

      for (final (file, message) in [
        ('test/fixtures/keys/openssl/p256.pkcs8.pem', 'piv.import.privateKey'),
        ('test/fixtures/keys/openssl/x509/p256.request.pem', 'piv.import.request'),
        ('test/fixtures/keys/openssl/x509/p256.request.der', 'piv.import.request'),
      ]) {
        await importFile(rig, File(file).readAsBytesSync());
        expect(find.text(t(message)), findsOneWidget, reason: file);
        await tester.tap(find.text(t('export.close')).last);
        await tester.pumpAndSettle();
      }
      await importFile(rig, utf8.encode('not a certificate'));
      expect(find.text(t('piv.import.unreadable')), findsOneWidget);
      expect(card.log, isEmpty);
    });

    testWidgets('pasted text is read as well', (tester) async {
      final card = FakePivCard();
      final key = card.generate(PivSlot.cardAuthentication, PivAlgorithm.eccP256);
      card.putCertificate(PivSlot.cardAuthentication, await selfSignedFor(key, notBefore: _from, notAfter: _until));
      final next = await selfSignedFor(key, name: 'Card Example', notBefore: _from, notAfter: _until);
      final rig = await openSlot(tester, card, PivSlot.cardAuthentication);

      await rig.keys.tapRow('piv.slot.importAuthority');
      await rig.keys.tapRow('piv.import.paste');
      await tester.enterText(find.byType(TextField).last, writePem('CERTIFICATE', next));
      await tester.pump();
      await rig.keys.tap('piv.continue');
      await rig.keys.tap('piv.import.button');

      expect(card.certificate(PivSlot.cardAuthentication), next);
    });

    testWidgets('on a standard-only card with an empty slot, Kemlock says it could not check, and asks', (tester) async {
      final card = FakePivCard(makerCommands: false);
      final cert = await selfSignedFor(card.generate(PivSlot.keyManagement, PivAlgorithm.eccP256), notBefore: _from, notAfter: _until);
      final rig = await openPivRig(tester, card: card);
      await rig.openCertificates();
      await rig.addTo(PivSlot.keyManagement);
      await rig.keys.tap('piv.generate.importInstead');
      expect(find.byType(PivSlotSheet), findsOneWidget);
      expect(find.text(t('piv.slot.empty.body')), findsOneWidget);

      await importFile(rig, cert);
      expect(find.text(t('piv.import.unchecked')), findsOneWidget);
      expect(card.log.where((line) => line.startsWith('put')), isEmpty, reason: 'asked before anything is sent');
      await rig.keys.tap('piv.import.anyway');
      expect(card.certificate(PivSlot.keyManagement), cert);
    });

    testWidgets('a certificate the key has no room for is said to be so, and the slot is unchanged', (tester) async {
      final card = FakePivCard();
      final key = card.generate(PivSlot.authentication, PivAlgorithm.eccP256);
      final der = await selfSignedFor(key, notBefore: _from, notAfter: _until);
      card.putCertificate(PivSlot.authentication, der);
      final rig = await openSlot(tester, card, PivSlot.authentication);
      card.full = true;

      await importFile(rig, await selfSignedFor(key, name: 'Bigger', notBefore: _from, notAfter: _until));
      await rig.keys.tap('piv.import.button');

      expect(find.text(t('piv.error.noRoom')), findsOneWidget);
      expect(card.certificate(PivSlot.authentication), der);
    });
  });

  testWidgets('remove: after the confirmation the slot reads Empty, and the card keeps its private key', (tester) async {
    final card = FakePivCard();
    card.putCertificate(
      PivSlot.keyManagement,
      await selfSignedFor(card.generate(PivSlot.keyManagement, PivAlgorithm.eccP256), notBefore: _from, notAfter: _until),
    );
    final rig = await openSlot(tester, card, PivSlot.keyManagement);

    await rig.keys.tapRow('piv.remove.row');
    expect(find.text(t('piv.remove.body')), findsOneWidget);
    expect(card.log.where((line) => line.startsWith('put')), isEmpty, reason: 'nothing before the confirmation');
    await tester.tap(find.widgetWithText(FilledButton, t('piv.remove.button')));
    await tester.pumpAndSettle();

    expect(find.byType(PivSlotSheet), findsNothing);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('9d'), matching: find.byType(GroupRow)).last,
        matching: find.text(t('piv.empty')),
      ),
      findsOneWidget,
    );
    expect(card.certificate(PivSlot.keyManagement), isNull);
    expect(card.keys[PivSlot.keyManagement], isNotNull);
  });
}
