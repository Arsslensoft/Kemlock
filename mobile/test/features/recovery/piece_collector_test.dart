import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/recovery/piece_collector.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';

import '../../fakes/fake_scanner.dart';
import '../../helpers/test_app.dart';

/// The kit's pieces' field and buttons.
Finder get _field => find.widgetWithText(TextField, t('recovery.collect.field'));
Finder get _add => find.widgetWithText(FilledButton, t('recovery.collect.add'));
Finder get _scan => find.widgetWithText(FilledButton, t('recovery.collect.scan'));
Finder get _stop => find.widgetWithText(TextButton, t('recovery.collect.stopScan'));

/// Taps [finder] once it is scrolled into view.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Types [text] into the field and taps Add piece.
Future<void> _addPiece(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pump();
  await tester.tap(_add);
  await tester.pump();
}

/// [piece] with one character of its key share changed: a typo the check catches.
String _typo(String piece) {
  final parts = piece.split('-');
  final share = parts[3];
  parts[3] = '${share[0] == 'A' ? 'B' : 'A'}${share.substring(1)}';
  return parts.join('-');
}

class _Keys {
  final List<({String kitId, Uint8List key})> calls = [];

  void call(String kitId, Uint8List key) => calls.add((kitId: kitId, key: key));
}

void main() {
  final kit = makeKit(2, 3, random: Random(7));

  testWidgets('asks for the first piece, with Add piece off until something is typed', (tester) async {
    final keys = _Keys();
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call)));

    expect(find.text(t('recovery.collect.start')), findsOneWidget);
    expect(tester.widget<FilledButton>(_add).onPressed, isNull);

    await tester.enterText(_field, '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(_add).onPressed, isNull);

    await tester.enterText(_field, kit.pieces[0]);
    await tester.pump();
    expect(tester.widget<FilledButton>(_add).onPressed, isNotNull);
  });

  testWidgets('takes a piece however it was typed, counts it and clears the field', (tester) async {
    final keys = _Keys();
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call)));

    await _addPiece(tester, ' ${displayPiece(kit.pieces[2]).toLowerCase()}\n');

    expect(find.text(t('recovery.collect.progress', {'count': 1, 'needed': 2})), findsOneWidget);
    expect(find.text(t('recovery.collect.piece', {'index': 3, 'shares': 3})), findsOneWidget);
    expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
    expect(keys.calls, isEmpty);
  });

  testWidgets('says what is wrong with each piece it refuses, and clears it after a good one', (tester) async {
    final keys = _Keys();
    final other = makeKit(2, 3, random: Random(8));
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call)));

    await _addPiece(tester, 'hello');
    expect(find.text(t('recovery.piece.error.format')), findsOneWidget);
    // A refused piece stays in the field, to be corrected
    expect(tester.widget<TextField>(_field).controller!.text, 'hello');

    await _addPiece(tester, _typo(kit.pieces[0]));
    expect(find.text(t('recovery.piece.error.checksum')), findsOneWidget);
    expect(find.text(t('recovery.piece.error.format')), findsNothing);

    await _addPiece(tester, kit.pieces[0]);
    expect(find.text(t('recovery.piece.error.checksum')), findsNothing);
    expect(find.text(t('recovery.collect.progress', {'count': 1, 'needed': 2})), findsOneWidget);

    await _addPiece(tester, other.pieces[1]);
    expect(find.text(t('recovery.piece.error.otherKit')), findsOneWidget);

    await _addPiece(tester, kit.pieces[0]);
    expect(find.text(t('recovery.piece.error.duplicate')), findsOneWidget);
    expect(find.text(t('recovery.collect.progress', {'count': 1, 'needed': 2})), findsOneWidget);
    expect(keys.calls, isEmpty);
  });

  testWidgets('hands back the kit id and the rebuilt key once enough pieces are in', (tester) async {
    final keys = _Keys();
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call)));

    await _addPiece(tester, kit.pieces[1]);
    await _addPiece(tester, kit.pieces[2]);

    expect(keys.calls, hasLength(1));
    expect(keys.calls.single.kitId, kit.kitId);
    expect(keys.calls.single.key, kit.key);
    expect(find.text(t('recovery.collect.progress', {'count': 2, 'needed': 2})), findsOneWidget);
    expect(find.text(t('recovery.collect.piece', {'index': 2, 'shares': 3})), findsOneWidget);
    expect(find.text(t('recovery.collect.piece', {'index': 3, 'shares': 3})), findsOneWidget);
  });

  testWidgets('opens a one-piece kit with its only piece', (tester) async {
    final keys = _Keys();
    final mine = makeKit(1, 1, random: Random(9));
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call)));

    await _addPiece(tester, mine.pieces.single);

    expect(keys.calls.single.key, mine.key);
  });

  testWidgets('turns the field and Add piece off while busy', (tester) async {
    final keys = _Keys();
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call, busy: true)));

    expect(tester.widget<TextField>(_field).enabled, isFalse);
    await tester.enterText(_field, kit.pieces[0]);
    await tester.pump();
    expect(tester.widget<FilledButton>(_add).onPressed, isNull);
  });

  testWidgets('announces its progress to screen readers', (tester) async {
    final keys = _Keys();
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call)));

    await _addPiece(tester, kit.pieces[0]);

    final progress = t('recovery.collect.progress', {'count': 1, 'needed': 2});
    expect(tester.getSemantics(find.text(progress)), isSemantics(label: progress, isLiveRegion: true));
  });

  testWidgets('scans pieces until there are enough, then stops the camera and hands back the key', (tester) async {
    final keys = _Keys();
    final scanner = FakeScanner();
    await pumpOnPage(
      tester,
      SingleChildScrollView(child: PieceCollector(onKey: keys.call)),
      overrides: [scanner.asOverride],
    );

    await _tap(tester, _scan);
    expect(scanner.isScanning, isTrue);
    expect(_field, findsNothing);

    await scanner.emitScan(tester, kit.pieces[0]);
    await tester.pumpAndSettle();
    expect(find.text(t('recovery.collect.progress', {'count': 1, 'needed': 2})), findsOneWidget);
    // Still scanning, with a fresh viewfinder for the next piece
    expect(scanner.isScanning, isTrue);
    expect(scanner.sources.where((s) => s.disposed), hasLength(1));

    await scanner.emitScan(tester, kit.pieces[2]);
    await tester.pumpAndSettle();

    expect(keys.calls.single.key, kit.key);
    expect(scanner.isScanning, isFalse);
    expect(_field, findsOneWidget);
  });

  testWidgets('says what is wrong with a scanned code and keeps scanning', (tester) async {
    final keys = _Keys();
    final scanner = FakeScanner();
    await pumpOnPage(
      tester,
      SingleChildScrollView(child: PieceCollector(onKey: keys.call)),
      overrides: [scanner.asOverride],
    );
    await _tap(tester, _scan);

    await scanner.emitScan(tester, 'otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP');
    await tester.pumpAndSettle();

    expect(find.text(t('recovery.piece.error.format')), findsOneWidget);
    expect(scanner.isScanning, isTrue);

    await scanner.emitScan(tester, kit.pieces[1]);
    await tester.pumpAndSettle();
    expect(find.text(t('recovery.piece.error.format')), findsNothing);
    expect(find.text(t('recovery.collect.piece', {'index': 2, 'shares': 3})), findsOneWidget);
  });

  testWidgets('goes back to typing when scanning stops', (tester) async {
    final keys = _Keys();
    final scanner = FakeScanner();
    await pumpOnPage(
      tester,
      SingleChildScrollView(child: PieceCollector(onKey: keys.call)),
      overrides: [scanner.asOverride],
    );
    await _tap(tester, _scan);

    await _tap(tester, _stop);

    expect(scanner.isScanning, isFalse);
    expect(scanner.sources.single.disposed, isTrue);
    expect(_field, findsOneWidget);
  });

  testWidgets('turns scanning off while busy', (tester) async {
    final keys = _Keys();
    await pumpOnPage(tester, SingleChildScrollView(child: PieceCollector(onKey: keys.call, busy: true)));

    expect(tester.widget<FilledButton>(_scan).onPressed, isNull);
  });
}
