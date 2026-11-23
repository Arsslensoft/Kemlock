/// The Recovery Kit on paper: one page per piece, as `RecoveryKitDialog.tsx`
/// laid its pieces out in the page's print-only area (`PrintArea.tsx`, with
/// `break-after: page` between them).
///
/// Each page has the kit's title, when it was made and how many pieces open
/// the vault, the piece's QR code, its text in groups of four, and how to
/// use it. A one-piece kit can carry the vault's unused backup codes too.
/// The sizes are the print area's, from CSS pixels (1/96 in) to points
/// (1/72 in): 24px headings are 18pt, the 220px QR code is 165pt.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'recovery_shares.dart';

/// What goes on paper, with its copy already in the app's language.
class KitPrintout {
  const KitPrintout({required this.pages, required this.meta, required this.howTo, this.codesTitle = '', this.codes = const []});

  /// Each piece and the title of its page ("… piece 1 of 3 · My vault").
  final List<({String title, String piece})> pages;

  /// When the kit was made and how many pieces open the vault.
  final String meta;

  /// How to use a piece.
  final String howTo;

  /// The heading over [codes].
  final String codesTitle;

  /// Unused backup codes by service, printed under a one-piece kit's piece.
  final List<({String name, List<String> codes})> codes;
}

/// The fonts the printout is set in: the app's Geist and Geist Mono.
class KitPdfFonts {
  const KitPdfFonts({required this.regular, required this.bold, required this.mono});

  static const assets = (
    regular: 'assets/fonts/Geist-Regular.ttf',
    bold: 'assets/fonts/Geist-Bold.ttf',
    mono: 'assets/fonts/GeistMono-Regular.ttf',
  );

  /// Reads the fonts from [bundle], the app's own by default.
  static Future<KitPdfFonts> load({AssetBundle? bundle}) async {
    final from = bundle ?? rootBundle;
    return KitPdfFonts(
      regular: pw.Font.ttf(await from.load(assets.regular)),
      bold: pw.Font.ttf(await from.load(assets.bold)),
      mono: pw.Font.ttf(await from.load(assets.mono)),
    );
  }

  final pw.Font regular;
  final pw.Font bold;
  final pw.Font mono;
}

/// The print area's 24px padding, and never less than the printer can reach.
const _margin = 24 * 0.75 + 0.4 * PdfPageFormat.inch;

/// Text lines are at most 520px wide, as on screen.
const _textWidth = 520 * 0.75;

const _ink = PdfColor.fromInt(0xFF111111);
const _muted = PdfColor.fromInt(0xFF555555);

/// The printout as a PDF on paper of [format]: each piece starts a page.
Future<Uint8List> buildKitPdf(KitPrintout printout, PdfPageFormat format, KitPdfFonts fonts, {bool compress = true}) {
  final doc = pw.Document(title: 'Kemlock Recovery Kit', compress: compress, version: PdfVersion.pdf_1_4);
  final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold);
  pw.TextStyle text(double size, {pw.Font? font, PdfColor color = _ink}) =>
      pw.TextStyle(font: font ?? fonts.regular, fontSize: size, color: color, lineSpacing: size * 0.35);
  final margin = pw.EdgeInsets.fromLTRB(
    math.max(_margin, format.marginLeft),
    math.max(_margin, format.marginTop),
    math.max(_margin, format.marginRight),
    math.max(_margin, format.marginBottom),
  );
  for (final page in printout.pages) {
    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: margin,
        theme: theme,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        build: (context) => [
          pw.Text(page.title, style: text(18, font: fonts.bold)),
          pw.SizedBox(height: 3),
          pw.Text(printout.meta, style: text(9, color: _muted)),
          // Four of the code's modules clear around it, which scanners need to find it
          pw.SizedBox(height: 18),
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium),
            data: page.piece,
            width: 165,
            height: 165,
            drawText: false,
          ),
          pw.SizedBox(height: 18),
          pw.ConstrainedBox(
            constraints: const pw.BoxConstraints(maxWidth: _textWidth),
            child: pw.Text(displayPiece(page.piece), style: text(9.75, font: fonts.mono)),
          ),
          pw.SizedBox(height: 9),
          pw.ConstrainedBox(
            constraints: const pw.BoxConstraints(maxWidth: _textWidth),
            child: pw.Text(printout.howTo, style: text(9)),
          ),
          if (printout.codes.isNotEmpty) ...[
            pw.SizedBox(height: 18),
            pw.Text(printout.codesTitle, style: text(14, font: fonts.bold)),
            pw.SizedBox(height: 6),
            for (final service in printout.codes)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(service.name, style: text(9, font: fonts.bold)),
                    pw.Text(service.codes.join('   '), style: text(9, font: fonts.mono)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
  return doc.save();
}
