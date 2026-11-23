/// A transfer's QR codes on paper, as `QRExportDialog.tsx` laid them out in
/// its print-only area. The sizes are the print area's, from CSS pixels
/// (1/96 in) to points (1/72 in): the 220px codes are 165pt. Like that
/// area, the page is in English whatever the app's language.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// What goes on paper.
class QrPrintout {
  const QrPrintout({
    required this.chunks,
    required this.encrypted,
    required this.accounts,
    required this.services,
    required this.exportedAt,
  });

  final List<String> chunks;
  final bool encrypted;
  final int accounts;
  final int services;
  final DateTime exportedAt;
}

/// The fonts the page is set in: the app's Geist.
class QrPdfFonts {
  const QrPdfFonts({required this.regular, required this.bold});

  /// Reads the fonts from [bundle], the app's own by default.
  static Future<QrPdfFonts> load({AssetBundle? bundle}) async {
    final from = bundle ?? rootBundle;
    return QrPdfFonts(
      regular: pw.Font.ttf(await from.load('assets/fonts/Geist-Regular.ttf')),
      bold: pw.Font.ttf(await from.load('assets/fonts/Geist-Bold.ttf')),
    );
  }

  final pw.Font regular;
  final pw.Font bold;
}

String _plural(int count, String one) => '$count $one${count != 1 ? 's' : ''}';

/// The heading: which kind of export this is.
String qrPrintTitle(QrPrintout printout) => 'Kemlock — ${printout.encrypted ? 'Encrypted' : 'Plaintext'} Vault QR Export';

/// When it was made and what it holds. A plain export doesn't claim to be encrypted, as the print area did.
String qrPrintMeta(QrPrintout printout) {
  final date = DateFormat('M/d/yyyy, h:mm:ss a', 'en_US').format(printout.exportedAt.toLocal());
  final services = printout.services > 0 ? ' + ${_plural(printout.services, 'backup service')}' : '';
  final scheme = printout.encrypted ? ' · Encrypted with AES-256-GCM + PBKDF2' : '';
  return 'Exported $date · ${_plural(printout.accounts, 'account')}$services · ${_plural(printout.chunks.length, 'QR code')}$scheme';
}

/// How to bring the codes back.
String qrPrintHowTo(QrPrintout printout) {
  final total = printout.chunks.length;
  final password = printout.encrypted ? ' You will need your export password to decrypt.' : '';
  return 'Scan all $total QR code${total > 1 ? 's' : ''} in the Kemlock app (Import → Scan QR Vault).$password';
}

const _muted = PdfColor.fromInt(0xFF555555);
const _faint = PdfColor.fromInt(0xFF888888);

/// The print area's 24px padding, and never less than the printer can reach.
const _margin = 24 * 0.75 + 0.4 * PdfPageFormat.inch;

/// The printout as a PDF on paper of [format]: the heading, then every code
/// with its number and the start of its text, then how to scan them.
Future<Uint8List> buildQrPdf(QrPrintout printout, PdfPageFormat format, QrPdfFonts fonts, {bool compress = true}) {
  final total = printout.chunks.length;
  final doc = pw.Document(
    title: qrPrintTitle(printout),
    compress: compress,
    version: PdfVersion.pdf_1_4,
    theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: format.copyWith(
        marginLeft: math.max(format.marginLeft, _margin),
        marginRight: math.max(format.marginRight, _margin),
        marginTop: math.max(format.marginTop, _margin),
        marginBottom: math.max(format.marginBottom, _margin),
      ),
      build: (context) => [
        pw.Text(qrPrintTitle(printout), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 3),
        pw.Text(qrPrintMeta(printout), style: const pw.TextStyle(fontSize: 9, color: _muted)),
        pw.SizedBox(height: 18),
        pw.Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            for (final (i, chunk) in printout.chunks.indexed)
              pw.SizedBox(
                width: 165,
                child: pw.Column(
                  children: [
                    pw.BarcodeWidget(
                      barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.low),
                      data: chunk,
                      width: 165,
                      height: 165,
                      drawText: false,
                    ),
                    pw.SizedBox(height: 6),
                    pw.Text('QR ${i + 1} / $total', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 2),
                    pw.Text('${chunk.substring(0, math.min(28, chunk.length))}…', style: const pw.TextStyle(fontSize: 7.5, color: _faint)),
                  ],
                ),
              ),
          ],
        ),
        pw.SizedBox(height: 24),
        pw.Text(qrPrintHowTo(printout), style: const pw.TextStyle(fontSize: 8.5, color: _faint)),
      ],
    ),
  );
  return doc.save();
}
