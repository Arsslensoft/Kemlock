import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../keys/key_bridge.dart';
import '../keys/key_standing.dart';
import 'contact_standing.dart';

/// A date as the contact screens write it, "3 November 2026", in the
/// phone's time zone; without the year when [year] is false, and with the
/// month cut short, "3 Nov 2026", when [short], for a line with little room.
String contactDate(BuildContext context, DateTime when, {bool year = true, bool short = false}) =>
    DateFormat('d ${short ? 'MMM' : 'MMMM'}${year ? ' y' : ''}', Localizations.localeOf(context).toLanguageTag()).format(when.toLocal());

/// What a key is, on one line: its algorithm, then when it expires, that it
/// never does, that it expired, or that it was revoked, as "Ed25519 ·
/// expires 12 May 2028".
String contactKeyLine(BuildContext context, crypto.PgpKeyInfo info, KeyStanding standing) {
  final expires = standing.expires;
  final state = switch (standing.standing) {
    Standing.revoked => context.t('contacts.review.revoked'),
    Standing.expired when expires != null => context.t('contacts.review.expiredOn', {'date': contactDate(context, expires, short: true)}),
    _ when expires != null => context.t('contacts.review.expires', {'date': contactDate(context, expires, short: true)}),
    _ => context.t('contacts.review.neverExpires'),
  };
  return '${pgpAlgorithmLabel(info.primary)} · $state';
}

/// The line under a contact's name in the list and on its sheet: "Checked
/// on 3 November", with the year when it is not this year, or "Not checked
/// yet".
String contactCheckLine(BuildContext context, ContactStanding standing, DateTime now) {
  final on = standing.checkedOn;
  if (!standing.checked) return context.t('contacts.notChecked');
  if (on == null) return context.t('contacts.checked');
  return context.t('contacts.checkedOn', {'date': contactDate(context, on, year: on.year != now.toLocal().year)});
}

/// The title of a contact sheet with a close button beside it, as the
/// mockup's sheet head. [step] is written under the title, "1 of 2".
class ContactSheetHead extends StatelessWidget {
  const ContactSheetHead({super.key, required this.title, this.step});

  final String title;
  final String? step;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: AppType.h4.copyWith(color: p.text)),
                ),
                if (step != null) Text(step!, style: AppType.caption.copyWith(color: p.textSecondary)),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            style: IconButton.styleFrom(backgroundColor: context.bmc.raised, foregroundColor: p.textSecondary),
            icon: Icon(Icons.close_rounded, size: 18, semanticLabel: context.t('contacts.review.close')),
          ),
        ],
      ),
    );
  }
}

/// A fingerprint in groups of four, on a card: five groups to a row for a
/// version 4 key's ten, four to a row for a version 6 key's sixteen. The
/// groups read left to right, then down, in every language, so the block
/// is laid out left to right even where the page is not, and it is read
/// out as its groups in that order.
class FingerprintCard extends StatelessWidget {
  const FingerprintCard({super.key, required this.fingerprint});

  /// The fingerprint in hexadecimal.
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final groups = crypto.fingerprintGroups(fingerprint);
    final perRow = groups.length > 10 ? 4 : 5;
    // Letter by letter, so a screen reader spells each group instead of guessing a word
    final spoken = [for (final group in groups) group.split('').join(' ')].join(', ');
    return Semantics(
      container: true,
      label: context.t('contacts.review.fingerprint.semantics', {'groups': spoken}),
      child: ExcludeSemantics(
        child: GroupCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var row = 0; row * perRow < groups.length; row++) ...[
                    if (row > 0) const SizedBox(height: 14),
                    Row(
                      children: [
                        for (var i = row * perRow; i < (row + 1) * perRow; i++)
                          Expanded(
                            child: Text(
                              i < groups.length ? groups[i] : '',
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              softWrap: false,
                              style: AppType.mono(fontSize: 17, fontWeight: FontWeight.w500, color: context.palette.text),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The value of a group row that may run long, such as a key's algorithm
/// and expiry: it takes at most two thirds of the row, wraps there, and
/// ends at the row's end.
class RowValue extends StatelessWidget {
  const RowValue(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final sheet = MediaQuery.sizeOf(context).width.clamp(0.0, sheetMaxWidth);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: (sheet - 60).clamp(0.0, double.infinity) * 0.66),
      child: Text(text, textAlign: TextAlign.end),
    );
  }
}
