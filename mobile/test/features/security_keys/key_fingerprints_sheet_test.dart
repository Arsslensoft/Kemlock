import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/key_fingerprints_sheet.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import 'key_sheet_harness.dart';

FakeFidoKey _reader() => FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard);

/// Opens the fingerprint list of [fido] over [kinds], typing the PIN.
Future<KeySheetRig> _open(WidgetTester tester, FakeFidoKey fido, {Set<SecurityKeyLinkKind> kinds = usb}) async {
  final rig = await openKeySheet(tester);
  await rig.present(FakeKey(productName: 'Bio Key', ctap: fido), kinds);
  await rig.tapRow('securityKeys.fingerprints.row');
  await rig.typePin('123456');
  return rig;
}

void main() {
  testWidgets('lists the fingerprints by name, numbering those without one', (tester) async {
    final fido = _reader()
      ..addFingerprint('Right thumb')
      ..addFingerprint();
    await _open(tester, fido);

    expect(find.byType(KeyFingerprintsSheet), findsOneWidget);
    expect(find.text('Right thumb'), findsOneWidget);
    expect(find.text(t('securityKeys.fingerprints.unnamed', {'number': 2})), findsOneWidget);
  });

  testWidgets('says when the key has none yet', (tester) async {
    await _open(tester, _reader());

    expect(find.text(t('securityKeys.fingerprints.empty')), findsOneWidget);
  });

  testWidgets('adding asks for each touch, says how many more, and the fingerprint can be named', (tester) async {
    final fido = _reader()..samplesNeeded = 3;
    final rig = await _open(tester, fido);

    await rig.tap('securityKeys.fingerprints.add');

    expect(fido.fingerprints, hasLength(1), reason: 'the fake touches the reader each time it is asked');
    expect(find.text(t('securityKeys.fingerprints.added')), findsOneWidget);
    expect(find.text(t('securityKeys.fingerprints.name.title')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Left index');
    await rig.tap('securityKeys.fingerprints.name.save');

    expect(fido.fingerprints.single.name, 'Left index');
    expect(find.text('Left index'), findsOneWidget);
    expect(fido.requests.where((request) => request == '9.1' || request == '9.2'), ['9.1', '9.2', '9.2']);
  });

  testWidgets('says when the key waited for a touch and none came', (tester) async {
    final fido = _reader()..touches = false;
    final rig = await _open(tester, fido);

    await rig.tap('securityKeys.fingerprints.add');

    expect(find.text(t('securityKeys.fingerprints.noTouch')), findsOneWidget);
    expect(fido.fingerprints, isEmpty);
  });

  testWidgets('a bad touch is said, is asked for again, and does not lower the count of touches left', (tester) async {
    final fido = _reader()
      ..samplesNeeded = 3
      ..samples.addAll([0, 9]);
    // The key hangs on the touch after the bad one, so the screen can be read at that moment.
    await _openHanging(tester, fido, afterTouches: 2);
    await tester.tap(find.text(t('securityKeys.fingerprints.add')).last);

    await _pumpUntil(tester, find.text(t('securityKeys.fingerprints.bad.short')));

    expect(find.text(t('securityKeys.fingerprints.touch')), findsOneWidget);
    expect(find.text(t('securityKeys.fingerprints.remaining', {'count': 2})), findsOneWidget, reason: 'as after the first, good touch');
    expect(fido.requests.where((request) => request == '9.2'), hasLength(1));
    expect(fido.fingerprints, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, t('export.cancel')).last);
    await _pumpUntil(tester, find.text(t('securityKeys.fingerprints.add')));
  });

  testWidgets('over NFC adding says to plug the key in, and listing, renaming and removing still work', (tester) async {
    final fido = _reader()..addFingerprint('Thumb');
    final rig = await _open(tester, fido, kinds: nfc);
    final mark = fido.requests.length;

    await rig.tap('securityKeys.fingerprints.add');
    expect(find.text(t('securityKeys.fingerprints.add.nfc')), findsOneWidget);
    expect(fido.requests, hasLength(mark), reason: 'nothing is sent');

    await tester.tap(find.bySemanticsLabel(t('securityKeys.fingerprints.rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Right thumb');
    await rig.tap('securityKeys.fingerprints.name.save');
    expect(fido.fingerprints.single.name, 'Right thumb');
    expect(find.text('Right thumb'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(t('securityKeys.fingerprints.remove')));
    await tester.pumpAndSettle();
    expect(find.text(t('securityKeys.fingerprints.remove.body', {'name': 'Right thumb'})), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t('securityKeys.fingerprints.remove')));
    await tester.pumpAndSettle();

    expect(fido.fingerprints, isEmpty);
    expect(find.text(t('securityKeys.fingerprints.empty')), findsOneWidget);
  });

  testWidgets('giving up half-way tells the key to drop the unfinished fingerprint, and the list is unchanged', (tester) async {
    final fido = _reader()..addFingerprint('Thumb');
    // After the first touch the key waits for the second for ever, until it is told to stop.
    await _openHanging(tester, fido, afterTouches: 1);

    await tester.tap(find.text(t('securityKeys.fingerprints.add')).last);
    await _pumpUntil(tester, find.text(t('securityKeys.fingerprints.remaining', {'count': 3})));
    expect(find.text(t('securityKeys.fingerprints.touch')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, t('export.cancel')).last);
    await _pumpUntil(tester, find.text(t('securityKeys.fingerprints.add')));

    expect(fido.requests, contains('9.3'), reason: 'the cancel command');
    expect(fido.enrollmentsCancelled, 1);
    expect(fido.fingerprints.map((fingerprint) => fingerprint.name), ['Thumb']);
    expect(find.text('Thumb'), findsOneWidget);
    expect(find.text(t('securityKeys.fingerprints.touch')), findsNothing);
  });

  testWidgets('removing asks first, and cancelling sends nothing', (tester) async {
    final fido = _reader()..addFingerprint('Thumb');
    final rig = await _open(tester, fido);
    final frames = rig.phone.sent.length;

    await tester.tap(find.bySemanticsLabel(t('securityKeys.fingerprints.remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, t('export.cancel')));
    await tester.pumpAndSettle();

    expect(rig.phone.sent, hasLength(frames));
    expect(fido.fingerprints, hasLength(1));
  });

  testWidgets('a full reader says to remove one first', (tester) async {
    final fido = _reader()..maxFingerprints = 1;
    fido.addFingerprint('Thumb');
    final rig = await _open(tester, fido);

    await rig.tap('securityKeys.fingerprints.add');

    expect(find.text(t('securityKeys.fingerprints.full')), findsOneWidget);
    expect(fido.fingerprints, hasLength(1));
  });

  testWidgets('a key with no reader never opens the sheet', (tester) async {
    final rig = await openKeySheet(tester);
    await rig.present(FakeKey(ctap: FakeFidoKey(pin: '123456')), usb);
    final frames = rig.phone.sent.length;

    expect(tester.widget<GroupRow>(keyRow('securityKeys.fingerprints.row')).onTap, isNull);
    await tester.tap(keyRow('securityKeys.fingerprints.row'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(KeyFingerprintsSheet), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(rig.phone.sent, hasLength(frames));
  });
}

/// Opens the fingerprint list of [fido] on a key that stops being touched
/// after [afterTouches] touches, on a phone whose reads take a pump each.
Future<KeySheetRig> _openHanging(WidgetTester tester, FakeFidoKey fido, {required int afterTouches}) async {
  final rig = await openKeySheet(tester);
  rig.phone.yieldOnRead = true;
  rig.phone.arrive(
    FakeKey(
      productName: 'Bio Key',
      ctap: _Hanging(fido, afterTouches: afterTouches),
    ).device(kinds: usb),
  );
  await _pumpUntil(tester, find.text(t('securityKeys.connected').toUpperCase()));
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.tap(keyRow('securityKeys.fingerprints.row'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, '123456');
  await tester.pump();
  await tester.tap(find.text(t('securityKeys.pin.continue')));
  await _pumpUntil(tester, find.byType(KeyFingerprintsSheet));
  await tester.pumpAndSettle();
  return rig;
}

/// Pumps frames, letting the fake key's answers through one read at a
/// time, until [finder] finds something.
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 2));
  }
  expect(finder, findsWidgets);
  await tester.pump();
}

/// Wraps a fake authenticator so that, once the reader was touched
/// [afterTouches] times in an enrolment, it waits for the next touch for
/// ever, as a key does while nobody touches it.
class _Hanging extends FakeCtapAuthenticator {
  _Hanging(this.inner, {required this.afterTouches});

  final FakeFidoKey inner;
  final int afterTouches;
  int _touches = 0;

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) {
    final sub = command == 0x09 && parameters.isNotEmpty ? cborIntMap(cborDecode(parameters))[2] : null;
    if (sub == 1 || sub == 2) {
      if (_touches == afterTouches) return FakeCtapReply.hang(2);
      _touches++;
    }
    return inner.handle(command, parameters, kind);
  }

  @override
  void poweredUp(DateTime Function() now) => inner.poweredUp(now);
}
