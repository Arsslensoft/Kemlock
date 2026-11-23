/// Which build this is, and what that build can do (openspec: add-fdroid-release): the
/// store build, for the App Store and Google Play, or the free build, made only of
/// free software for F-Droid and the releases page. `kemlock_parts` says, as
/// tool/build/use_free.sh chose it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart';

export 'package:kemlock_ports/kemlock_ports.dart' show BuildKind;

/// Which build this is.
const BuildKind buildKind = parts.buildKind;

/// Which build this is, as a provider, so that a test can be the other one.
final buildKindProvider = Provider<BuildKind>((ref) => buildKind);

/// Whether this build reads backup codes from a screenshot or a photo.
const bool canReadPictures = parts.canReadPictures;

/// Whether this build reads backup codes from a PDF.
const bool canReadPdfs = parts.canReadPdfs;
