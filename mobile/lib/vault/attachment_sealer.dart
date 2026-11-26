import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'attachment_seal.dart';

/// What seals a new attached file: [sealAttachment] in the app, which encrypts in a background isolate.
typedef AttachmentSealer = Future<SealedAttachment> Function(Uint8List plain, {required String name, String? type, required int now});

/// The sealer a note's attachment and a File item use. Widget tests put one in its place that seals in the test's own isolate,
/// since the isolate's work never finishes under a test's fake async.
final attachmentSealerProvider = Provider<AttachmentSealer>((ref) => sealAttachment);
