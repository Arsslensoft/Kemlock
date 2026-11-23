import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart';

export 'package:kemlock_ports/kemlock_ports.dart'
    show QrImageReader, ScannerFailure, ScannerFailureKind, ScannerPhase, ScannerSource, ScannerState;

/// Makes the [ScannerSource] each viewfinder on screen reads from: this build's camera,
/// from `kemlock_parts` (openspec: add-fdroid-release). Tests override it.
final scannerSourceProvider = Provider<ScannerSource Function()>((ref) => parts.newScannerSource);

/// Reads the QR code in a picture, with this build's decoder. Tests override it.
final qrImageReaderProvider = Provider<QrImageReader>((ref) => parts.newQrImageReader());
