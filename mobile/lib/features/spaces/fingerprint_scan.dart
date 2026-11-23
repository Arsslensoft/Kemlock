// Reads a fingerprint's QR code with the app's existing scanner (docs/plans/add-server-spaces.md, tasks 5.3 and 5.4): the
// accept screen and the confirm view give it to `scan`, and compare what it returns with `checkScannedFingerprint`.

library;

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../scan/qr_viewfinder.dart';

/// Opens the camera in a sheet and answers the text of the first code it reads, or null when the sheet is dismissed.
Future<String?> scanFingerprint(BuildContext context) => showAppBottomSheet<String>(
  context,
  label: context.t('accept.scan'),
  builder: (sheet) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        QrViewfinder(onScan: (code) => Navigator.of(sheet).pop(code)),
        TextButton(onPressed: () => Navigator.of(sheet).pop(), child: Text(context.t('recovery.collect.stopScan'))),
      ],
    ),
  ),
);
