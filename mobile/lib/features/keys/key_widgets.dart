import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:qr_flutter/qr_flutter.dart';

import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'key_bridge.dart';
import 'key_standing.dart';

/// What a key is, as the import preview and the key sheet show it: its
/// kind, algorithm and size, its fingerprint, and for a PGP key its user
/// IDs, its subkeys and what each is for, and whether it keeps its own
/// passphrase. A key of an algorithm Kemlock doesn't know shows its
/// identifier and says that it has no public half or fingerprint to show.
///
/// Given the time [now], a PGP key also says when it expires or that it
/// never does, warns when that is within 30 days, and says in red that it
/// has expired or was revoked and what that means for using it. Each
/// subkey's line says the same of that subkey, with a warning above the
/// lines when a subkey alone has expired or was revoked (openspec:
/// add-key-expiry-warnings). A key of another kind shows none of it.
///
/// A key whose private half is on a security key says so by the card's
/// [cardSerial] in place of the note on its own passphrase (openspec:
/// add-openpgp-card).
class KeyFacts extends StatelessWidget {
  const KeyFacts({
    super.key,
    required this.parsed,
    this.comment,
    this.extra = const [],
    this.now,
    this.onSubkey,
    this.cardSerial,
    this.cardGone = false,
  });

  final crypto.ParsedKey parsed;

  /// The name an SSH key's public line ends with.
  final String? comment;

  /// Rows the key sheet adds, such as dates and origin.
  final List<Widget> extra;

  /// The time a PGP key's expiry is read against; without it nothing is
  /// said of expiry.
  final DateTime? now;

  /// Opens the change of the expiry of the PGP key's subkey at this index:
  /// each subkey line that is not revoked becomes tappable (openspec:
  /// add-pgp-key-editing). Null where the key cannot be changed.
  final void Function(int index)? onSubkey;

  /// The serial of the card a key's private half is on; null for a key
  /// that holds it.
  final String? cardSerial;

  /// Whether that card was read since without the key: it no longer holds it.
  final bool cardGone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fingerprint = crypto.keyFingerprint(parsed);
    final pgp = parsed.pgp;
    String purposes(crypto.PgpKey key) => [
      if (key.canCertify) context.t('keys.pgp.certify'),
      if (key.canSign) context.t('keys.pgp.sign'),
      if (key.canEncrypt) context.t('keys.pgp.encrypt'),
      if (key.canAuthenticate) context.t('keys.pgp.authenticate'),
    ].join(', ');
    final standing = pgp == null || now == null ? null : keyStanding(pgp, now!);
    final dates = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag());
    String date(DateTime when) => dates.format(when.toLocal());
    // What a subkey's line says after its purposes, and whether in red
    (String, bool)? mark(KeyStanding? of) => switch (of) {
      KeyStanding(standing: Standing.revoked) => (context.t('keys.pgp.revoked'), true),
      KeyStanding(standing: Standing.expired, :final expires?) => (context.t('keys.pgp.expired', {'date': date(expires)}), true),
      KeyStanding(:final expires?) => (context.t('keys.pgp.expires', {'date': date(expires)}), false),
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (standing != null && standing.standing != Standing.ok) ...[
          AppAlert(
            key: const ValueKey('key-standing'),
            severity: standing.standing == Standing.expiringSoon ? AlertSeverity.warning : AlertSeverity.error,
            child: Text(switch (standing.standing) {
              Standing.revoked => context.t('keys.expiry.revoked'),
              Standing.expired => context.t('keys.expiry.expired', {'date': date(standing.expires!)}),
              _ => context.t('keys.expiry.soon', {'days': standing.daysLeft ?? 0}),
            }),
          ),
          const SizedBox(height: 12),
        ],
        Group(
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.category_outlined),
              primary: context.t('keys.field.kind'),
              value: Text(context.t(keyKindLabelId(parsed.kind.name))),
            ),
            GroupRow(
              icon: const Icon(Icons.memory_rounded),
              primary: context.t('keys.field.algorithm'),
              value: Text(algorithmLabel(parsed.algorithm, parsed.bits)),
            ),
            if (standing != null)
              GroupRow(
                key: const ValueKey('key-expiry'),
                icon: const Icon(Icons.event_busy_outlined),
                primary: context.t('keys.field.expiry'),
                value: Text(standing.expires == null ? context.t('keys.expiry.never') : date(standing.expires!)),
              ),
            ...extra,
          ],
        ),
        const SizedBox(height: 12),
        if (fingerprint != null) ...[
          Text(context.t('keys.field.fingerprint'), style: AppType.caption.copyWith(color: p.textSecondary)),
          const SizedBox(height: 4),
          SelectableText(
            fingerprint.text,
            key: const ValueKey('fingerprint'),
            style: AppType.mono(fontSize: 13, color: p.text),
          ),
        ] else
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('keys.other.noPublic', {'identifier': parsed.algorithm}))),
        if (pgp != null) ...[
          const SizedBox(height: 12),
          for (final user in pgp.userIdsMainFirst) Text(user, style: AppType.body2.copyWith(color: p.text)),
          const SizedBox(height: 6),
          if (standing?.subkeyProblem != null) ...[
            AppAlert(
              key: const ValueKey('subkey-standing'),
              severity: AlertSeverity.warning,
              child: Text(
                context.t(standing!.subkeyProblem == Standing.revoked ? 'keys.expiry.subkeyRevoked' : 'keys.expiry.subkeyExpired'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            context.t('keys.pgp.primary', {'algorithm': pgpKeyAlgorithmName(pgp.primary.algorithm), 'purposes': purposes(pgp.primary)}),
            style: AppType.caption.copyWith(color: p.textSecondary),
          ),
          for (final (i, subkey) in pgp.subkeys.indexed) ...[
            _tappable(
              onSubkey == null || subkey.revoked ? null : () => onSubkey!(i),
              Text.rich(
                TextSpan(
                  text: context.t('keys.pgp.subkey', {'algorithm': pgpKeyAlgorithmName(subkey.algorithm), 'purposes': purposes(subkey)}),
                  children: [
                    if (mark(standing?.subkeys.elementAtOrNull(i)) case (final words, final wrong)) ...[
                      const TextSpan(text: ' · '),
                      TextSpan(
                        text: words,
                        style: wrong ? TextStyle(color: p.error, fontWeight: FontWeight.w600) : null,
                      ),
                    ],
                  ],
                ),
                key: ValueKey('subkey-$i'),
                style: AppType.caption.copyWith(color: onSubkey == null || subkey.revoked ? p.textSecondary : p.text),
              ),
            ),
            // A post-quantum subkey's own fingerprint, which GnuPG and
            // Sequoia print for it
            if (pgpKeyAlgorithmName(subkey.algorithm) != subkey.algorithm)
              SelectableText(
                groupedFingerprintOf(subkey.fingerprintHex),
                key: ValueKey('subkey-fingerprint-$i'),
                style: AppType.mono(fontSize: 11, color: p.textSecondary),
              ),
          ],
          if (onSubkey != null && pgp.subkeys.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(context.t('keys.change.subkeyHint'), style: AppType.caption.copyWith(color: p.textSecondary)),
          ],
          if (pgpReadersMessageId(pgp) case final readers?) ...[
            const SizedBox(height: 8),
            AppAlert(key: const ValueKey('pgp-readers'), severity: AlertSeverity.info, child: Text(context.t(readers))),
          ],
          for (final (message, algorithm) in pgpCannotMessages(pgp)) ...[
            const SizedBox(height: 8),
            AppAlert(key: ValueKey(message), severity: AlertSeverity.warning, child: Text(context.t(message, {'algorithm': algorithm}))),
          ],
          if (cardSerial != null) ...[
            if (cardGone) ...[
              const SizedBox(height: 8),
              AppAlert(
                key: const ValueKey('key-card-gone'),
                severity: AlertSeverity.warning,
                child: Text(context.t('keys.card.gone', {'serial': cardSerial})),
              ),
            ],
            const SizedBox(height: 8),
            AppAlert(
              key: const ValueKey('key-on-card'),
              severity: AlertSeverity.info,
              child: Text(context.t('keys.card.info', {'serial': cardSerial})),
            ),
          ] else if (pgp.protected) ...[
            const SizedBox(height: 8),
            AppAlert(severity: AlertSeverity.info, child: Text(context.t('keys.pgp.protected'))),
          ],
        ],
      ],
    );
  }
}

/// [child] as a row to tap when [onTap] is given.
Widget _tappable(VoidCallback? onTap, Widget child) => onTap == null
    ? child
    : InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: child),
      );

/// The words of the tag a key of [standing] carries in the vault list,
/// "Expires in 7 days", "Expired" or "Revoked" in the language of
/// [messages]; null for a key in order, which carries none.
String? standingLabel(Messages messages, KeyStanding standing) => switch (standing.standing) {
  Standing.ok => null,
  Standing.expiringSoon => messages.t('keys.standing.expiresIn', {'days': standing.daysLeft ?? 0}),
  Standing.expired => messages.t('keys.standing.expired'),
  Standing.revoked => messages.t('keys.standing.revoked'),
};

/// The tag on the row of a PGP key whose private half is on a security
/// key: "On your key", in the accent colour.
class KeyOnCardTag extends StatelessWidget {
  const KeyOnCardTag({super.key});

  @override
  Widget build(BuildContext context) => StatusTag(label: context.t('keys.card.tag'), tone: StatusTone.accent);
}

/// The tag on the row of a PGP key that needs attention: the warning colour
/// for one expiring soon, the error colour for one that expired or was
/// revoked. Nothing for a key in order.
class KeyStandingTag extends StatelessWidget {
  const KeyStandingTag({super.key, required this.standing});

  final KeyStanding standing;

  @override
  Widget build(BuildContext context) {
    final label = standingLabel(context.messages, standing);
    if (label == null) return const SizedBox.shrink();
    return StatusTag(label: label, tone: standing.standing == Standing.expiringSoon ? StatusTone.warning : StatusTone.danger);
  }
}

/// The most characters of an armored public key a QR code is given: an
/// armored Ed25519 key is about 650 and scans easily; an RSA 3072 key is
/// about 2,500 and an RSA 4096 key 3,200, past what a phone reads off a
/// screen or what one code holds.
const publicKeyQrLimit = 1800;

/// What the QR code of a public key holds: its [text], or for a PGP key
/// whose armored text is over [publicKeyQrLimit] characters, `OPENPGP4FPR:`
/// and its [fingerprint] in hexadecimal, which proves the key without
/// carrying it. Only a PGP key is given a [fingerprint].
({String data, bool fingerprintOnly}) publicKeyQrData(String text, {String? fingerprint}) =>
    fingerprint != null && text.length > publicKeyQrLimit
    ? (data: 'OPENPGP4FPR:$fingerprint', fingerprintOnly: true)
    : (data: text, fingerprintOnly: false);

/// A public key as a QR code on white, with [caption] under it when the
/// code holds a fingerprint in place of the key.
class PublicKeyQr extends StatelessWidget {
  const PublicKeyQr({super.key, required this.data, this.caption});

  /// What the code holds.
  final String data;
  final String? caption;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.all(10),
        color: const Color(0xFFFFFFFF),
        child: QrImageView(
          data: data,
          size: 240,
          padding: EdgeInsets.zero,
          backgroundColor: const Color(0xFFFFFFFF),
          errorCorrectionLevel: QrErrorCorrectLevel.L,
          errorStateBuilder: (_, _) => SizedBox(width: 240, child: Text(context.t('keys.public.qrTooLong'), textAlign: TextAlign.center)),
        ),
      ),
      if (caption != null) ...[
        const SizedBox(height: 12),
        Text(
          caption!,
          textAlign: TextAlign.center,
          style: AppType.caption.copyWith(color: context.palette.textSecondary),
        ),
      ],
    ],
  );
}

/// Shows the public key [text] as a QR code, which is what another Kemlock
/// scans to add the key; see [publicKeyQrData] for what a long PGP key's
/// code holds.
Future<void> showPublicKeyQr(BuildContext context, String text, {String? fingerprint}) {
  final code = publicKeyQrData(text, fingerprint: fingerprint);
  return showAppDialog<void>(
    context,
    builder: (dialog) => AppDialog(
      heading: DialogHeading(title: dialog.t('keys.public.qr')),
      content: Center(
        child: PublicKeyQr(data: code.data, caption: code.fingerprintOnly ? dialog.t('keys.public.qr.fingerprintOnly') : null),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(dialog.t('notes.file.close')))],
    ),
  );
}
