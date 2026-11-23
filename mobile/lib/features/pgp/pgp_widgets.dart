/// What the four PGP sheets share (openspec: add-pgp-messages): closing
/// when the vault locks, the passphrase prompt, the words for each thing
/// that can go wrong, the banner that says who signed, and the main
/// button that turns into progress and Cancel while a job runs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../contacts/contact_widgets.dart' show contactDate;
import '../keys/key_bridge.dart' show pgpKeyAlgorithmName;
import '../keys/key_standing.dart';
import 'pgp_controller.dart';
import 'pgp_job.dart';
import 'pgp_people.dart';

/// Closes the sheet or dialog a state belongs to when the vault locks,
/// whatever is open above it: call [closeOnLock] from `initState`. What
/// awaited the route gets null.
mixin ClosesOnLock<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  void closeOnLock() {
    ref.listenManual(vaultControllerProvider.select((state) => state.session), (_, session) {
      if (session != null || !mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
    });
  }
}

/// The vault's PGP keys, in its order.
List<VaultKey> pgpVaultKeys(VaultState state) => [
  for (final key in state.keys)
    if (key.kind == KeyKind.pgp) key,
];

/// [key] for a job to sign or decrypt with.
PgpJobKey jobKeyOf(VaultKey key, {String? passphrase}) => PgpJobKey(unb64(key.privateKey), passphrase: passphrase, onCard: key.isOnCard);

/// The keys every signature is checked against: the people at hand, then
/// any [given] for this action.
List<Uint8List> verifierKeys(WidgetRef ref, [Iterable<PgpPerson> given = const []]) => [
  for (final person in ref.read(pgpPeopleProvider)) person.publicKey,
  for (final person in given) person.publicKey,
];

/// The person whose key has [fingerprint], among those at hand and those
/// [given].
PgpPerson? personWith(WidgetRef ref, String? fingerprint, [Iterable<PgpPerson> given = const []]) {
  if (fingerprint == null) return null;
  for (final person in [...ref.read(pgpPeopleProvider), ...given]) {
    if (person.fingerprint == fingerprint) return person;
  }
  return null;
}

// ─── Words ────────────────────────────────────────────────────────────────────

/// What to tell the person about [error]. [name] is who the key named by
/// the error's fingerprint belongs to, when it is known.
String pgpErrorText(Messages messages, pgp.PgpException error, {String? name}) {
  final who = name ?? (error.fingerprint == null ? null : shortKeyId(error.fingerprint!));
  switch (error.problem) {
    case pgp.PgpProblem.notAMessage:
      return messages.t(switch (error.detail) {
        'encrypted' => 'pgp.error.isEncrypted',
        'detached' => 'pgp.error.needsFile',
        'not signed' => 'pgp.error.notSigned',
        'a key' => 'pgp.error.isKey',
        _ => 'pgp.error.notAMessage',
      });
    case pgp.PgpProblem.noKeyOpensIt:
      return error.keyIds.isEmpty
          ? messages.t('pgp.error.noKeyOpensIt.hidden')
          : messages.t('pgp.error.noKeyOpensIt', {'ids': error.keyIds.join(', ')});
    case pgp.PgpProblem.wrongPassphrase:
      return messages.t(error.fingerprint == null ? 'pgp.error.wrongPassphrase' : 'pgp.error.wrongKeyPassphrase');
    case pgp.PgpProblem.unsupported:
      final what = error.detail ?? '';
      if (error.fingerprint == null) return messages.t('pgp.error.unsupported', {'name': what});
      if (what == 'version 6 keys') return messages.t('pgp.error.unsupportedV6');
      // A key's protection is named by its method or cipher; its kind as GnuPG names it
      final protection =
          what.startsWith('Argon2') || what == 'MD5' || RegExp(r'^(IDEA|3DES|CAST5|Blowfish|Twofish|Camellia|S2K|cipher)').hasMatch(what);
      return messages.t(protection ? 'pgp.error.unsupportedProtection' : 'pgp.error.unsupportedKey', {
        'name': protection ? what : pgpKeyAlgorithmName(what),
      });
    case pgp.PgpProblem.keyUnusable:
      final reason = error.reason;
      if (reason == null || who == null) return messages.t('pgp.error.keyUnusable');
      return messages.t('pgp.standing.${reason.name}', {'name': who});
    case pgp.PgpProblem.passphraseNeeded ||
        pgp.PgpProblem.damaged ||
        pgp.PgpProblem.noIntegrity ||
        pgp.PgpProblem.noSecretHere ||
        pgp.PgpProblem.tooLarge ||
        pgp.PgpProblem.outOfSpace ||
        pgp.PgpProblem.cancelled:
      return messages.t('pgp.error.${error.problem.name}');
  }
}

/// How a message was encrypted, for the "Encryption" row: the kind of key
/// it was opened with, the cipher and the AEAD mode, as in "X25519,
/// AES-256".
String encryptionSummary(pgp.PgpDecrypted message) {
  final algorithm = message.openedWithAlgorithm;
  final key = algorithm == null
      ? null
      : algorithm == 'cv25519'
      ? 'X25519'
      : algorithm.startsWith('rsa')
      ? 'RSA ${algorithm.substring(3)}'
      : pgpKeyAlgorithmName(algorithm);
  return [?key, ?message.cipher, ?message.mode].join(', ');
}

/// [bytes] as text to show, or null when it is not text: not UTF-8, or
/// with a NUL in it.
String? shownText(Uint8List bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

// ─── The passphrase prompt ────────────────────────────────────────────────────

/// Asks for a passphrase in a dialog: a key's, naming the key in [title],
/// or a message's. [error] says the last one was wrong. Gives null when
/// the person cancels or the vault locks. What is typed is hidden unless
/// the person asks to see it, and is kept nowhere.
Future<String?> askPgpPassphrase(BuildContext context, {required String title, String? body, String? error}) => showAppDialog<String>(
  context,
  builder: (_) => _PassphraseDialog(title: title, body: body, error: error),
);

class _PassphraseDialog extends ConsumerStatefulWidget {
  const _PassphraseDialog({required this.title, this.body, this.error});

  final String title;
  final String? body;
  final String? error;

  @override
  ConsumerState<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends ConsumerState<_PassphraseDialog> with ClosesOnLock {
  final _passphrase = TextEditingController();
  var _shown = false;

  @override
  void initState() {
    super.initState();
    _passphrase.addListener(() => setState(() {}));
    closeOnLock();
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _submit() {
    if (_passphrase.text.isNotEmpty) Navigator.of(context).pop(_passphrase.text);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    semanticLabel: widget.title,
    heading: DialogHeading(icon: const Icon(Icons.key_rounded), title: widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.body != null) ...[Text(widget.body!), const SizedBox(height: 12)],
        PassphraseField(
          controller: _passphrase,
          label: context.t('pgp.passphrase.field'),
          shown: _shown,
          onToggle: () => setState(() => _shown = !_shown),
          error: widget.error,
          autofocus: true,
          onSubmitted: _submit,
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('pgp.cancel'))),
      FilledButton(onPressed: _passphrase.text.isEmpty ? null : _submit, child: Text(context.t('pgp.passphrase.continue'))),
    ],
  );
}

/// A passphrase field: hidden unless [shown], with the eye that toggles.
class PassphraseField extends StatelessWidget {
  const PassphraseField({
    super.key,
    required this.controller,
    required this.label,
    required this.shown,
    required this.onToggle,
    this.error,
    this.enabled = true,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool shown;
  final VoidCallback onToggle;
  final String? error;
  final bool enabled;
  final bool autofocus;
  final VoidCallback? onSubmitted;

  // Shown and copied, the passphrase goes through the secret clipboard
  @override
  Widget build(BuildContext context) => SecretSelection(
    child: TextField(
      enableIMEPersonalizedLearning: false,
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      obscureText: !shown,
      autocorrect: false,
      enableSuggestions: false,
      contextMenuBuilder: secretTextMenu,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      decoration: InputDecoration(
        labelText: label,
        errorText: error,
        errorMaxLines: 3,
        suffixIcon: IconButton(
          onPressed: onToggle,
          tooltip: context.t(shown ? 'pgp.passphrase.hide' : 'pgp.passphrase.show'),
          icon: Icon(shown ? Icons.visibility_off_outlined : Icons.visibility_outlined),
        ),
      ),
    ),
  );
}

// ─── Who signed ───────────────────────────────────────────────────────────────

/// Says what one signature came to: who signed, whether it matches, and
/// what the match is worth. [signer] is the person whose key made it, when
/// that key is at hand. With [onGiveKey], a signature whose signer is
/// unknown offers "Give their key".
class SignatureBanner extends ConsumerWidget {
  const SignatureBanner({super.key, required this.result, this.signer, this.onGiveKey});

  final pgp.SignatureResult result;
  final PgpPerson? signer;
  final VoidCallback? onGiveKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final signer = this.signer;
    final name = signer?.name ?? (result.issuer == null ? null : shortKeyId(result.issuer!));
    // When a contact was checked, as its row in the vault says it: with the year when it is not this one
    final now = ref.watch(clockProvider)();
    final checkedAt = signer?.checkedAt;
    final checkedOn = checkedAt == null ? null : contactDate(context, checkedAt, year: checkedAt.year != now.toLocal().year);
    final (AlertSeverity severity, String title, String body) = switch (result.verdict) {
      pgp.SignatureVerdict.good when result.keyRevoked => (
        AlertSeverity.warning,
        context.t('pgp.decrypted.signedBy', {'name': name ?? ''}),
        context.t('pgp.signature.keyRevoked'),
      ),
      pgp.SignatureVerdict.good when result.keyExpired => (
        AlertSeverity.warning,
        context.t('pgp.decrypted.signedBy', {'name': name ?? ''}),
        context.t('pgp.signature.keyExpired'),
      ),
      pgp.SignatureVerdict.good when result.keyExpiredSince => (
        AlertSeverity.warning,
        context.t('pgp.decrypted.signedBy', {'name': name ?? ''}),
        context.t('pgp.signature.keyExpiredSince'),
      ),
      pgp.SignatureVerdict.good when signer != null && signer.isChecked => (
        AlertSeverity.success,
        context.t('pgp.decrypted.signedBy', {'name': name ?? ''}),
        signer.isOwn
            ? context.t('pgp.decrypted.matchesYours')
            : checkedOn != null
            ? context.t('pgp.signature.matchesChecked', {'date': checkedOn})
            : context.t('pgp.signature.good'),
      ),
      pgp.SignatureVerdict.good when signer != null && signer.isContact => (
        AlertSeverity.info,
        context.t('pgp.decrypted.signedBy', {'name': name ?? ''}),
        context.t('pgp.signature.matchesUnchecked'),
      ),
      pgp.SignatureVerdict.good => (
        AlertSeverity.info,
        context.t('pgp.decrypted.signedBy', {'name': name ?? ''}),
        context.t('pgp.decrypted.matchesGiven'),
      ),
      pgp.SignatureVerdict.bad => (AlertSeverity.error, context.t('pgp.signature.badTitle'), context.t('pgp.signature.bad')),
      pgp.SignatureVerdict.unknownSigner => (
        AlertSeverity.warning,
        context.t('pgp.signature.unknownTitle'),
        context.t('pgp.signature.unknown'),
      ),
      pgp.SignatureVerdict.weakHash => (
        AlertSeverity.warning,
        context.t('pgp.signature.weakTitle'),
        context.t('pgp.signature.weak', {'name': result.detail ?? ''}),
      ),
      pgp.SignatureVerdict.weakKey => (
        AlertSeverity.warning,
        context.t('pgp.signature.weakKeyTitle'),
        context.t('pgp.signature.weakKey', {'name': result.detail ?? ''}),
      ),
      pgp.SignatureVerdict.unsupported => (
        AlertSeverity.warning,
        context.t('pgp.signature.unknownTitle'),
        context.t('pgp.signature.unsupported', {'name': result.detail ?? ''}),
      ),
    };
    final fingerprint = signer?.fingerprint ?? result.issuer;
    final made = result.made;
    final date = made == null ? null : DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).add_Hm().format(made.toLocal());
    return AppAlert(
      severity: severity,
      icon: const Icon(Icons.verified_user_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppType.body2.copyWith(fontWeight: FontWeight.w600, color: p.text),
          ),
          const SizedBox(height: 2),
          Text(body),
          if (date != null) Text(context.t('pgp.signature.made', {'date': date})),
          if (fingerprint != null) ...[
            const SizedBox(height: 2),
            Text(groupedFingerprint(fingerprint), style: AppType.mono(fontSize: 12, color: p.textSecondary)),
          ],
          if (result.verdict == pgp.SignatureVerdict.unknownSigner && onGiveKey != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: onGiveKey, child: Text(context.t('pgp.signature.giveKey'))),
            ),
        ],
      ),
    );
  }
}

/// The banners of [results], one per signature, or the plain line that
/// says a message is not signed.
class SignatureBanners extends ConsumerWidget {
  const SignatureBanners({super.key, required this.results, this.given = const [], this.onGiveKey});

  final List<pgp.SignatureResult> results;

  /// Keys given for this action, which a signature may be by.
  final List<PgpPerson> given;
  final VoidCallback? onGiveKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(context.t('pgp.decrypted.notSigned'), style: AppType.body2.copyWith(color: context.palette.textSecondary)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, result) in results.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          SignatureBanner(result: result, signer: personWith(ref, result.signerFingerprint, given), onGiveKey: onGiveKey),
        ],
      ],
    );
  }
}

// ─── The main button ──────────────────────────────────────────────────────────

/// A sheet's main button. While a job runs it becomes what says so: for a
/// file a bar with the percentage, for text the spinner, each with Cancel.
class PgpWorkButton extends ConsumerWidget {
  const PgpWorkButton({super.key, required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final Widget? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pgpJobControllerProvider);
    final p = context.palette;
    if (status == null) {
      return icon == null
          ? FilledButton(style: largeButtonStyle, onPressed: onPressed, child: Text(label))
          : FilledButton.icon(style: largeButtonStyle, onPressed: onPressed, icon: icon, label: Text(label));
    }
    final percent = (status.progress * 100).floor();
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          if (status.onFile)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(context.t('pgp.progress', {'percent': percent}), style: AppType.body2.copyWith(color: p.textSecondary)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: status.progress, minHeight: 6, semanticsLabel: label),
                  ),
                ],
              ),
            )
          else ...[
            const Spinner(),
            const SizedBox(width: 12),
            Expanded(
              child: Text(context.t('pgp.working'), style: AppType.body2.copyWith(color: p.textSecondary)),
            ),
          ],
          const SizedBox(width: 12),
          TextButton(onPressed: ref.read(pgpJobControllerProvider.notifier).cancel, child: Text(context.t('pgp.cancel'))),
        ],
      ),
    );
  }
}

/// A line of red under a sheet's fields, read out when it appears.
class PgpErrorLine extends StatelessWidget {
  const PgpErrorLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: AppAlert(severity: AlertSeverity.error, child: Text(text)),
  );
}

/// The name of a vault key for a prompt: its main user ID's name
/// (openspec: add-pgp-key-editing), else what the vault calls it.
String vaultKeyTitle(WidgetRef ref, VaultKey key) {
  final info = ref.read(pgpKeyInfoProvider(key.id));
  return userIdName(info?.mainUserId ?? '') ?? key.name;
}

/// Whether [key] is the vault key with the primary fingerprint
/// [fingerprint].
bool vaultKeyHas(WidgetRef ref, VaultKey key, String? fingerprint) =>
    fingerprint != null && ref.read(pgpKeyInfoProvider(key.id))?.primary.fingerprintHex == fingerprint;

/// What the pickers say under a person's name: their address, or the
/// end of their key's fingerprint.
String personLine(PgpPerson person) => person.address ?? groupedFingerprint(shortKeyId(person.fingerprint));

/// The value at the right of a row, which may be a long name: it wraps
/// onto a second line and is cut after that, where a bare text would run
/// off the row.
class PgpRowValue extends StatelessWidget {
  const PgpRowValue(this.text, {super.key, this.mono = false});

  final String text;
  final bool mono;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 190),
    child: Text(
      text,
      textAlign: TextAlign.end,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: mono ? AppType.mono(fontSize: 12.5, color: context.palette.textSecondary) : null,
    ),
  );
}
