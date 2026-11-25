/// The store build's parts (openspec: add-fdroid-release, design decision
/// 1): QR codes through `mobile_scanner` (ML Kit on Android, Vision on iOS),
/// text in pictures through ML Kit, and text in PDFs through pdfrx (PDFium).
/// The free build's `kemlock_parts`, in `packages/parts_free`, exports the
/// same names; the app reads them as the default values of its providers and
/// imports nothing else of either.
library;

import 'package:kemlock_ports/kemlock_ports.dart';

import 'src/code_readers.dart';
import 'src/credential_export.dart';
import 'src/credential_transfer.dart';
import 'src/push_tokens.dart';
import 'src/scanner.dart';

/// Which build this is.
const buildKind = BuildKind.store;

/// Whether this build reads backup codes from a screenshot or a photo.
const canReadPictures = true;

/// Whether this build reads backup codes from a PDF.
const canReadPdfs = true;

/// The camera behind a QR viewfinder.
ScannerSource newScannerSource() => MobileScannerSource();

/// Reads the QR code in a picture.
QrImageReader newQrImageReader() => MobileScannerImageReader();

/// Finds the text in a picture.
const ImageTextReader imageTextReader = MlKitImageTextReader();

/// Finds the text in a PDF.
const PdfTextReader pdfTextReader = PdfrxTextReader();

/// The system's list of apps that can export to Kemlock, over Google Play services; Android only.
CredentialTransfer makeCredentialTransfer() => PlayCredentialTransfer();

/// Kemlock as a source other apps import from, over the same plugin (switched off until plan add-credential-exchange, task 8.6).
CredentialExport makeCredentialExport() => PlayCredentialExport();

/// Push through APNs on iOS and UnifiedPush on Android (plan add-unifiedpush).
PushTokens newPushTokens() => makePushTokens();
