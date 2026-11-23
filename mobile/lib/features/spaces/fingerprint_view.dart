// The widget every screen of the spaces plan shows a fingerprint with
// (docs/plans/add-server-spaces.md, design 1; `add-account-crypto`, design 5):
// the 12 groups of 5 digits in three rows of four, to read out, and a QR code of
// the 64 bytes, to scan. The web vault, the server's own pages and Amethystora
// Vault show the same digits.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../crypto/account/bundle.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../keys/key_widgets.dart' show PublicKeyQr;
import 'fingerprint.dart';

/// The key of the digit group [index] (0 to 11), for tests.
ValueKey<String> fingerprintGroupKey(int index) => ValueKey('fingerprint-group-$index');

/// A fingerprint as 12 groups of 5 digits in rows of four, and, unless [showQr] is false, as a QR code.
class FingerprintView extends StatelessWidget {
  const FingerprintView({super.key, required this.fingerprint, this.showQr = true});

  /// The 64 bytes of the fingerprint ([KeyBundle.fingerprint]).
  final Uint8List fingerprint;
  final bool showQr;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final rows = fingerprintRows(fingerprint);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        // One label for a screen reader, which reads the digits as they are read out, not group by group
        Semantics(
          container: true,
          label: fingerprintDigitsOf(fingerprint),
          child: ExcludeSemantics(
            child: Column(
              spacing: 10,
              children: [
                for (var row = 0; row < rows.length; row++)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var column = 0; column < rows[row].length; column++)
                        Text(
                          rows[row][column],
                          key: fingerprintGroupKey(row * fingerprintGroupsPerRow + column),
                          style: AppType.mono(fontSize: 18, fontWeight: FontWeight.w500, color: p.text),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        if (showQr)
          Center(
            child: PublicKeyQr(data: fingerprintQrText(fingerprint), caption: context.t('fingerprint.qr')),
          ),
      ],
    );
  }
}
