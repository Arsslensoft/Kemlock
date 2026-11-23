import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/piv_reset.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_piv_card.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

/// A card in use: a certificate in 9a and 9c, its own codes and an AES
/// management key kept in [notes]. With [serial] null it hides its serial
/// number, and has no card identifier either.
Future<FakePivCard> _inUse(FakePivNotes notes, {int? serial = 12345678}) async {
  final key = List.filled(32, 0x24);
  final card = FakePivCard(
    pin: '271828',
    puk: '31415926',
    managementKeyType: PivManagementKeyType.aes256,
    managementKey: key,
    serial: serial,
  );
  for (final slot in [PivSlot.authentication, PivSlot.signature]) {
    card.putCertificate(
      slot,
      await selfSignedFor(card.generate(slot, PivAlgorithm.eccP256), notBefore: pivNow, notAfter: DateTime.utc(2028)),
    );
  }
  notes.notes.add(
    SecureNote(
      id: 'mk',
      title: 'Management key – Example Key 5C 12345678',
      addedAt: 1,
      piv: NotePivKey(key: '12345678', algorithm: 'aes256', managementKey: '24' * 32),
    ),
  );
  return card;
}

Future<void> _typeWord(WidgetTester tester, String word) async {
  await tester.enterText(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(TextField)), word);
  await tester.pump();
}

FilledButton _resetButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));

void main() {
  testWidgets('a standard-only card offers no reset', (tester) async {
    final rig = await openPivRig(tester, card: FakePivCard(makerCommands: false));
    await rig.openCertificates();
    expect(find.text(t('piv.reset.row')), findsNothing);
  });

  testWidgets('the reset starts only once the whole word is typed, and leaves the slots empty and the factory codes', (tester) async {
    final notes = FakePivNotes();
    final card = await _inUse(notes);
    final rig = await openPivRig(tester, card: card, notes: notes);
    await rig.openCertificates();
    await rig.keys.tapRow('piv.reset.row');
    expect(find.text(t('piv.reset.lost')), findsOneWidget);

    await _typeWord(tester, 'RESE');
    expect(_resetButton(tester).onPressed, isNull);
    await _typeWord(tester, 'reset');
    expect(_resetButton(tester).onPressed, isNotNull);
    expect(card.log.where((line) => line == 'verify' || line == 'unblock' || line == 'reset'), isEmpty, reason: 'nothing before');
    await tester.tap(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();

    expect(card.log.where((line) => line == 'reset'), hasLength(1));
    expect(card.keys, isEmpty);
    expect((card.pin, card.puk), (pivFactoryPin, pivFactoryPuk));
    expect(card.managementKey, pivFactoryManagementKey);
    // The sheet shows what the key now holds.
    for (final slot in PivSlot.values) {
      expect(
        find.descendant(
          of: find.ancestor(of: find.text(slot.id), matching: find.byType(GroupRow)).last,
          matching: find.text(t('piv.empty')),
        ),
        findsOneWidget,
      );
    }
    expect(find.text(t('piv.factoryDefault').toUpperCase()), findsOneWidget);

    // The note is offered for deletion, and kept when the person says so.
    expect(find.text(t('piv.reset.note.body', {'title': 'Management key – Example Key 5C 12345678'})), findsOneWidget);
    await tester.tap(find.text(t('piv.reset.note.keep')));
    await tester.pumpAndSettle();
    expect(notes.notes, hasLength(1));
  });

  testWidgets('the note is deleted when the person agrees', (tester) async {
    final notes = FakePivNotes();
    final rig = await openPivRig(tester, card: await _inUse(notes), notes: notes);
    await rig.openCertificates();
    await rig.keys.tapRow('piv.reset.row');
    await _typeWord(tester, t('piv.reset.word'));
    await tester.tap(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t('piv.reset.note.delete')));
    await tester.pumpAndSettle();
    expect(notes.notes, isEmpty);
  });

  testWidgets('a key taken away once both codes are blocked is offered "Finish the reset" when it is back', (tester) async {
    final notes = FakePivNotes();
    final card = await _inUse(notes);
    final rig = await openPivRig(tester, card: card, notes: notes, kinds: nfc);
    await rig.openCertificates();
    await rig.keys.tapRow('piv.reset.row');
    await _typeWord(tester, 'RESET');
    // The key leaves just as the reset itself is sent.
    rig.phone.removeWhen = (frame) => frame.length > 1 && frame[1] == 0xfb;
    await tester.tap(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect((card.pinTries, card.pukTries), (0, 0));
    expect(card.keys, isNotEmpty);

    rig.phone.removeWhen = null;
    await rig.keys.present(rig.key, nfc);
    expect(find.text(t('piv.codes.bothBlocked')), findsOneWidget);
    await rig.keys.tap('piv.reset.finish');
    expect(find.text(t('piv.reset.finish.body')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t('piv.reset.button')));
    await tester.pumpAndSettle();

    expect(card.keys, isEmpty);
    expect((card.pinTries, card.pukTries), (3, 3));
  });

  group('runs only on the key the warning was read for', () {
    FakeKey other(FakePivCard card) => FakeKey(
      productName: 'Example Key 5C',
      ctap: FakeFidoKey(pin: '123456'),
      applets: [card],
    );

    void expectUntouched(FakePivCard card) {
      expect(card.log.where((line) => line == 'verify' || line == 'unblock' || line == 'reset'), isEmpty);
      expect((card.pinTries, card.pukTries), (3, 3));
    }

    testWidgets('a key held to the phone in its place that hides its serial number is left as it is', (tester) async {
      final notes = FakePivNotes();
      final rig = await openPivRig(tester, card: await _inUse(notes), notes: notes, kinds: nfc);
      await rig.openCertificates();
      await rig.keys.tapRow('piv.reset.row');
      await _typeWord(tester, 'RESET');
      await rig.keys.remove(rig.device);
      await tester.tap(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();
      // The reset waits for a key; another one comes, which hides its serial number
      final second = FakePivCard(serial: null);
      await rig.keys.present(other(second), nfc);

      expect(find.text(t('piv.error.otherKey')), findsOneWidget);
      expectUntouched(second);
      expect(rig.card.keys, hasLength(2));
    });

    testWidgets('of two keys that hide their serial numbers, the one read while the warning was up is left as it is', (tester) async {
      final notes = FakePivNotes();
      final rig = await openPivRig(tester, card: await _inUse(notes, serial: null), notes: notes, kinds: nfc);
      await rig.openCertificates();
      await rig.keys.tapRow('piv.reset.row');
      await _typeWord(tester, 'RESET');
      // The first key is taken away and a blank one held in its place, read as it comes
      await rig.keys.remove(rig.device);
      final second = FakePivCard(serial: null);
      await rig.keys.present(other(second), nfc);
      await tester.tap(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();

      expect(find.text(t('piv.error.otherKey')), findsOneWidget);
      expectUntouched(second);
      expect(rig.card.keys, hasLength(2));
    });
  });

  testWidgets('a reset leaves the key’s FIDO2 side as it was', (tester) async {
    final notes = FakePivNotes();
    final rig = await openPivRig(tester, card: await _inUse(notes), notes: notes);
    final fido = rig.key.ctap! as FakeFidoKey;
    final before = fido.pin;
    await rig.openCertificates();
    await rig.keys.tapRow('piv.reset.row');
    await _typeWord(tester, 'RESET');
    await tester.tap(find.descendant(of: find.byType(PivResetConfirm), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(fido.pin, before);
    expect(rig.card.keys, isEmpty);
  });
}
