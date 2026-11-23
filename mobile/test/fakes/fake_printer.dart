import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/platform/printer.dart';
import 'package:pdf/pdf.dart';

/// Stands in for the system's print dialog: lays each document out on A4,
/// keeps it, and answers as the test says.
///
/// ```dart
/// final printer = FakePrinter();
/// await pumpScreen(tester, screen, overrides: [printer.asOverride]);
/// // … tap Print …
/// expect(printer.jobs.single.name, 'Kemlock Recovery Kit');
/// ```
class FakePrinter implements Printer {
  FakePrinter({this.printing = true, this.printed = true, this.holds});

  /// Whether the phone can print; when it can't, screens share the PDF instead.
  bool printing;

  /// What the print dialog answers: false as if the person cancelled.
  bool printed;

  /// The auto-lock holds to check while the dialog is open.
  final AutoLockHolds? holds;

  /// Every document printed, laid out on A4, and whether auto-lock was held
  /// while the dialog was open (null without [holds]).
  final List<({String name, Uint8List pdf, bool? held})> jobs = [];

  Override get asOverride => printerProvider.overrideWithValue(this);

  @override
  Future<bool> canPrint() async => printing;

  @override
  Future<bool> printPdf({required String name, required PdfLayout layout}) async {
    if (!printing) throw StateError('This phone cannot print');
    jobs.add((name: name, pdf: await layout(PdfPageFormat.a4), held: holds?.isHeld));
    return printed;
  }
}
