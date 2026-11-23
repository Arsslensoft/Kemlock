/// The free build's parts (openspec: add-fdroid-release, design decisions
/// 1, 3, 4 and 5), made only of free software: no text recognition in
/// pictures or PDFs. The store build's `kemlock_parts`, in
/// `packages/parts_store`, exports the same names; tool/build/use_free.sh
/// points the app at this one.
library;

import 'package:kemlock_ports/kemlock_ports.dart';

import 'src/camera_scanner.dart';
import 'src/no_credential_export.dart';
import 'src/no_credential_transfer.dart';
import 'src/no_push.dart';
import 'src/picture_reader.dart';
import 'src/readers.dart';

/// Which build this is.
const buildKind = BuildKind.free;

/// Whether this build reads backup codes from a screenshot or a photo.
const canReadPictures = false;

/// Whether this build reads backup codes from a PDF.
const canReadPdfs = false;

/// The camera behind a QR viewfinder: the `camera` plugin, and QR codes read with zxing2.
ScannerSource newScannerSource() => CameraScannerSource();

/// Reads the QR code in a picture, with the same decoder.
QrImageReader newQrImageReader() => const DecoderImageReader();

/// Finds the text in a picture: never, in this build.
const ImageTextReader imageTextReader = NoImageTextReader();

/// Finds the text in a PDF: never, in this build.
const PdfTextReader pdfTextReader = NoPdfTextReader();

/// No system transfer from another app: Google Play services runs it, and this build holds none.
CredentialTransfer makeCredentialTransfer() => const NoCredentialTransfer();

/// No export to another app on the phone: it runs on Google Play services too.
CredentialExport makeCredentialExport() => const NoCredentialExport();

/// No push: the schedule and the live socket only.
PushTokens newPushTokens() => const NoPushTokens();
