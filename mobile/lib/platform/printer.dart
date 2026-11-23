import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/// Lays a document out as a PDF on paper of the format the printer has.
typedef PdfLayout = Future<Uint8List> Function(PdfPageFormat format);

/// Printing through the system's print dialog, as `print.ts` printed the
/// page with `window.print`, which WebViews don't do reliably. Tests
/// replace it with `FakePrinter` (`test/fakes/fake_printer.dart`).
///
/// The print dialog hides the app, so callers hold auto-lock around
/// [printPdf], as `printNow` held it until `afterprint`.
abstract interface class Printer {
  /// Whether this phone can print at all.
  Future<bool> canPrint();

  /// Opens the system print dialog for the document [layout] makes, named
  /// [name]. Resolves to whether it was printed (or saved as a PDF): false
  /// when the person cancelled.
  Future<bool> printPdf({required String name, required PdfLayout layout});
}

/// [Printer] on the phone, through the `printing` package.
class SystemPrinter implements Printer {
  const SystemPrinter();

  @override
  Future<bool> canPrint() async {
    try {
      return (await Printing.info()).canPrint;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> printPdf({required String name, required PdfLayout layout}) => Printing.layoutPdf(name: name, onLayout: layout);
}

final printerProvider = Provider<Printer>((ref) => const SystemPrinter());
