import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/crypto/keys/x509.dart';
import 'package:kemlock/features/security_keys/piv_controller.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../crypto/keys/x509_software.dart';
import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_files.dart';
import '../../fakes/fake_piv_card.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart';

export 'key_sheet_harness.dart';

/// The notes of an open vault, in memory, for the PIV sheets alone.
class FakePivNotes implements PivNotes {
  @override
  final List<SecureNote> notes = [];

  /// The next adds fail, as a vault that cannot save.
  bool failAdd = false;

  /// Every add, update and delete, in order, by the note's title.
  final List<String> log = [];

  @override
  Future<bool> add(SecureNote note) async {
    log.add('add ${note.title}');
    if (failAdd) return false;
    notes.add(note);
    return true;
  }

  @override
  Future<bool> update(SecureNote note) async {
    log.add('update ${note.title}');
    final index = notes.indexWhere((kept) => kept.id == note.id);
    if (index < 0) return false;
    notes[index] = note;
    return true;
  }

  @override
  Future<void> delete(SecureNote note) async {
    log.add('delete ${note.title}');
    notes.removeWhere((kept) => kept.id == note.id);
  }

  Override get asOverride => pivNotesProvider.overrideWithValue(this);
}

/// The public half of a key the fake card made.
PublicHalf publicOf(KeyMaterial key) => switch (key) {
  RsaMaterial(:final n, :final e) => RsaPublicHalf(n, e),
  EcMaterial(:final curve, :final point) => EcPublicHalf(curve, point),
  _ => throw StateError('not a slot key'),
};

/// A self-signed certificate for [key] naming [name], as a desktop tool
/// would have put in a slot.
Future<Uint8List> selfSignedFor(KeyMaterial key, {String name = 'Ada Example', required DateTime notBefore, required DateTime notAfter}) =>
    buildSelfSigned(
      publicKey: publicOf(key),
      commonName: name,
      notBefore: notBefore,
      notAfter: notAfter,
      use: CertificateUse.authentication,
      sign: (toBeSigned) async => softwareX509Signature(key, toBeSigned),
    );

/// The time the fake phone starts at, which is the app's clock.
final pivNow = DateTime.utc(2026, 11, 16, 9);

/// The Security key sheet open on a key with [card], and what the PIV
/// sheets reach through it.
class PivRig {
  PivRig(this.keys, this.card, this.key, this.device, this.notes, this.files);

  final KeySheetRig keys;
  final FakePivCard card;
  final FakeKey key;
  final FakeDevice device;
  final FakePivNotes notes;
  final FakeFiles files;

  WidgetTester get tester => keys.tester;
  FakeSecurityKeys get phone => keys.phone;

  /// Opens the Certificates sheet from its row.
  Future<void> openCertificates() async {
    await keys.tapRow('piv.title');
  }

  /// Taps the row of [slot] on the Certificates sheet.
  Future<void> tapSlot(PivSlot slot) async {
    final row = find.ancestor(of: find.text(slot.id), matching: find.byType(GroupRow)).last;
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Taps "Add" on the row of [slot].
  Future<void> addTo(PivSlot slot) async {
    final add = find.descendant(
      of: find.ancestor(of: find.text(slot.id), matching: find.byType(GroupRow)).last,
      matching: find.text(t('piv.add')),
    );
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
  }

  /// Types [text] into the field labelled by the message [id].
  Future<void> type(String id, String text) async {
    final field = find.widgetWithText(TextField, t(id)).last;
    await tester.ensureVisible(field);
    await tester.enterText(field, text);
    await tester.pump();
  }

  /// The commands the card got, without the reads every session starts with.
  List<String> get changes => [
    for (final line in card.log)
      if (!line.startsWith('get ') &&
          !line.startsWith('metadata') &&
          line != 'select' &&
          line != 'verify?' &&
          line != 'version' &&
          line != 'serial')
        line,
  ];
}

/// Opens the Security key sheet on a phone with [capabilities], presents
/// a key with [card] on links of [kinds], and waits for it to be read.
Future<PivRig> openPivRig(
  WidgetTester tester, {
  FakePivCard? card,
  Set<SecurityKeyLinkKind> kinds = usb,
  SecurityKeyCapabilities capabilities = FakeSecurityKeys.android,
  FakePivNotes? notes,
  FakeFiles? files,
  bool fido = true,
  Brightness brightness = Brightness.dark,
  AppLocale locale = AppLocale.en,
  bool tall = true,
}) async {
  final theCard = card ?? FakePivCard();
  final theNotes = notes ?? FakePivNotes();
  final theFiles = files ?? FakeFiles();
  final phone = FakeSecurityKeys(phone: capabilities, start: pivNow);
  final rig = await openKeySheet(
    tester,
    phone: phone,
    brightness: brightness,
    locale: locale,
    tall: tall,
    overrides: [theNotes.asOverride, theFiles.asOverride],
  );
  final key = FakeKey(
    productName: 'Example Key 5C',
    ctap: fido ? FakeFidoKey(pin: '123456') : null,
    fido: fido,
    applets: [theCard],
  );
  final device = await rig.present(key, kinds);
  return PivRig(rig, theCard, key, device, theNotes, theFiles);
}

/// The app goes behind another and comes back.
void hideAndShow(WidgetTester tester) {
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}
