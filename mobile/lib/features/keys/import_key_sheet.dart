import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/ids.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../contacts/contact_keys.dart';
import '../contacts/contact_review_sheet.dart';
import 'key_bridge.dart';
import 'key_widgets.dart';

/// Brings a private key into the vault from a file or pasted text.
Future<void> showImportKeySheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('keys.import.title'), builder: (_) => const ImportKeySheet());

/// Reads a key off the UI isolate; tests replace it with one that needs no isolate.
final keyReaderProvider = Provider<Future<crypto.ParsedKey> Function(Object input, {String? passphrase})>((ref) => readKeyInBackground);

/// The message id of why a key couldn't be read.
String keyProblemId(crypto.KeyProblem problem) => 'keys.import.error.${problem.name}';

/// The import sheet: a file or pasted text, read as whatever key format it
/// is, its passphrase asked for when it has one, and a preview of what was
/// found before anything is added. What can't be imported says why, and
/// adds nothing.
class ImportKeySheet extends ConsumerStatefulWidget {
  const ImportKeySheet({super.key});

  @override
  ConsumerState<ImportKeySheet> createState() => _ImportKeySheetState();
}

class _ImportKeySheetState extends ConsumerState<ImportKeySheet> {
  final _paste = TextEditingController();
  final _passphrase = TextEditingController();
  final _name = TextEditingController();
  Object? _input;
  String? _fileName;
  var _needsPassphrase = false;
  var _reading = false;
  ({String id, Map<String, Object?> args})? _error;
  crypto.ParsedKey? _parsed;

  /// The OpenPGP public keys in what was given, when it held a public key
  /// and no private one: someone else's, which belong with the contacts.
  List<crypto.PgpPublicKey>? _others;
  var _asSsh = false;

  /// The vault's copy of the PGP key read, and that copy combined with it
  /// when the file adds something (openspec: add-pgp-key-editing).
  VaultKey? _held;
  VaultKey? _combined;

  @override
  void initState() {
    super.initState();
    _paste.addListener(() => setState(() {}));
    _passphrase.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _paste.dispose();
    _passphrase.dispose();
    _name.dispose();
    super.dispose();
  }

  void _start(Object input, {String? fileName}) {
    _passphrase.clear();
    setState(() {
      _input = input;
      _fileName = fileName;
      _needsPassphrase = false;
      _error = null;
      _parsed = null;
      _others = null;
      _held = null;
      _combined = null;
    });
    unawaited(_read());
  }

  Future<void> _pick() async {
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    _start(picked.bytes, fileName: picked.name);
  }

  Future<void> _read() async {
    final input = _input;
    if (input == null || _reading) return;
    final passphrase = _needsPassphrase ? _passphrase.text : null;
    setState(() {
      _reading = true;
      _error = null;
    });
    try {
      final parsed = await ref.read(keyReaderProvider)(input, passphrase: passphrase);
      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _asSsh = false;
        _name.text = _defaultName(parsed);
      });
      await _compareWithHeld(parsed);
    } on crypto.KeyFormatException catch (error) {
      // A public key alone is not the person's own. When it is an OpenPGP one it is someone else's,
      // and the sheet offers to keep it with other people's keys; any other is refused as before.
      final others = error.problem == crypto.KeyProblem.publicKeyOnly ? await _readOthers(input) : null;
      if (!mounted) return;
      setState(() {
        if (error.problem == crypto.KeyProblem.passphraseNeeded) {
          _needsPassphrase = true;
        } else {
          _error = (id: keyProblemId(error.problem), args: {'detail': error.detail ?? ''});
          _others = others;
        }
      });
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// Whether the vault holds the PGP key [parsed], and what the file adds to
  /// its copy: nothing, and the sheet adds it as before, which says the
  /// vault holds it; or something, which the sheet lists and offers to
  /// update the key with.
  Future<void> _compareWithHeld(crypto.ParsedKey parsed) async {
    if (parsed.kind != crypto.KeyKind.pgp) return;
    final incoming = vaultKeyOf(parsed, id: '', name: '', origin: KeyOrigin.imported);
    final held = ref.read(vaultControllerProvider.notifier).heldKey(incoming);
    if (held == null) return;
    final combined = await combinedPgpKey(held, incoming);
    if (!mounted) return;
    setState(() {
      _held = held;
      _combined = combined;
    });
  }

  Future<void> _update() async {
    final held = _held;
    final combined = _combined;
    if (held == null || combined == null) return;
    final updated = await ref
        .read(vaultControllerProvider.notifier)
        .replaceKeyHalves(held, unb64(combined.privateKey), unb64(combined.publicKey!));
    if (!updated || !mounted) return;
    ref.read(toastsProvider.notifier).show(context.t('keys.change.import.updated', {'name': held.name}));
    Navigator.of(context).pop();
  }

  /// What [combined] holds that [held] does not, one line each.
  List<String> _additions(VaultKey held, VaultKey combined) {
    final before = parsedKeyOf(held).pgp;
    final after = parsedKeyOf(combined).pgp;
    if (before == null || after == null) return const [];
    String purposes(crypto.PgpKey key) => [
      if (key.canCertify) context.t('keys.pgp.certify'),
      if (key.canSign) context.t('keys.pgp.sign'),
      if (key.canEncrypt) context.t('keys.pgp.encrypt'),
      if (key.canAuthenticate) context.t('keys.pgp.authenticate'),
    ].join(', ');
    final dates = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag());
    final had = {for (final subkey in before.subkeys) subkey.fingerprintHex};
    final lines = [
      for (final subkey in after.subkeys)
        if (!had.contains(subkey.fingerprintHex))
          context.t('keys.change.import.subkey', {'algorithm': pgpAlgorithmLabel(subkey), 'purposes': purposes(subkey)}),
      for (final userId in after.userIds)
        if (!before.userIds.contains(userId)) context.t('keys.change.import.userId', {'userId': userId}),
      if (after.primary.expires != before.primary.expires)
        after.primary.expires == null
            ? context.t('keys.change.import.noExpiry')
            : context.t('keys.change.import.expiry', {'date': dates.format(after.primary.expires!.toLocal())}),
      if (after.primary.revoked && !before.primary.revoked) context.t('keys.change.import.revocation'),
    ];
    return lines.isEmpty ? [context.t('keys.change.import.signatures')] : lines;
  }

  /// The sound OpenPGP public keys in [input], or null when it holds none.
  Future<List<crypto.PgpPublicKey>?> _readOthers(Object input) async {
    try {
      return await ref.read(publicKeyReaderProvider)(input);
    } on crypto.KeyFormatException {
      return null;
    }
  }

  /// Closes this sheet and shows the public keys found for review, as other people's keys.
  void _toContacts(List<crypto.PgpPublicKey> keys) {
    final root = Navigator.of(context, rootNavigator: true).context;
    final source = _fileName == null ? ContactSource.paste : ContactSource.file;
    Navigator.of(context).pop();
    unawaited(showContactReviewSheet(root, keys, source));
  }

  String _defaultName(crypto.ParsedKey key) {
    final comment = key.comment?.trim();
    if (comment != null && comment.isNotEmpty) return comment;
    final user = key.pgp?.mainUserId;
    if (user != null && user.isNotEmpty) return user;
    final file = _fileName;
    if (file != null && file.isNotEmpty) return file.replaceFirst(RegExp(r'\.(pem|key|asc|gpg|der|p8|pk8|txt)$', caseSensitive: false), '');
    return context.t('keys.import.defaultName', {'algorithm': algorithmLabel(key.algorithm, key.bits)});
  }

  Future<void> _add() async {
    final parsed = _parsed;
    if (parsed == null || _name.text.trim().isEmpty) return;
    final kept = _asSsh ? parsed.withKind(crypto.KeyKind.ssh) : parsed;
    final key = vaultKeyOf(kept, id: newUuid(), name: _name.text.trim(), origin: KeyOrigin.imported);
    final added = await ref.read(vaultControllerProvider.notifier).addKey(key);
    if (added && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final parsed = _parsed;
    final error = _error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.file_open_outlined), title: context.t('keys.import.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.t('keys.import.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _reading ? null : () => unawaited(_pick()),
                  icon: const Icon(Icons.folder_open_rounded),
                  label: Text(_fileName ?? context.t('keys.import.file')),
                ),
                const SizedBox(height: 12),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _paste,
                  minLines: 3,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: AppType.mono(fontSize: 12, color: p.text),
                  decoration: InputDecoration(
                    labelText: context.t('keys.import.paste'),
                    hintText: '-----BEGIN PRIVATE KEY-----',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: _reading || _paste.text.trim().isEmpty ? null : () => _start(_paste.text),
                    child: Text(context.t('keys.import.read')),
                  ),
                ),
                if (_needsPassphrase && parsed == null) ...[
                  const SizedBox(height: 8),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _passphrase,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: context.t('keys.import.passphrase'),
                      helperText: context.t('keys.import.passphrase.body'),
                    ),
                    onSubmitted: (_) => unawaited(_read()),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton(
                      onPressed: _reading || _passphrase.text.isEmpty ? null : () => unawaited(_read()),
                      child: Text(context.t('keys.import.open')),
                    ),
                  ),
                ],
                if (_reading) ...[const SizedBox(height: 12), const Center(child: Spinner())],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  AppAlert(severity: AlertSeverity.error, child: Text(context.t(error.id, error.args))),
                ],
                if (_others case final others? when error != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _toContacts(others),
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: Text(context.t('keys.import.toContacts')),
                  ),
                ],
                if (parsed != null) ...[
                  const SizedBox(height: 12),
                  KeyFacts(parsed: parsed, comment: _name.text.trim()),
                  if (parsed.hasSshForm && parsed.kind != crypto.KeyKind.ssh) ...[
                    const SizedBox(height: 8),
                    Group(
                      children: [
                        GroupRow(
                          first: true,
                          icon: const Icon(Icons.terminal_rounded),
                          primary: context.t('keys.import.asSsh'),
                          secondary: context.t('keys.import.asSsh.body'),
                          control: AppSwitch(value: _asSsh, onChanged: (value) => setState(() => _asSsh = value)),
                        ),
                      ],
                    ),
                  ],
                  if (_held case final held? when _combined != null) ...[
                    const SizedBox(height: 16),
                    AppAlert(
                      key: const ValueKey('import-update'),
                      severity: AlertSeverity.info,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.t('keys.change.import.held', {'name': held.name})),
                          const SizedBox(height: 6),
                          for (final line in _additions(held, _combined!)) Text('•  $line'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: largeButtonStyle,
                      onPressed: () => unawaited(_update()),
                      icon: const Icon(Icons.update_rounded),
                      label: Text(context.t('keys.change.import.update')),
                    ),
                  ] else ...[
                    const SizedBox(height: 16),
                    TextField(
                      enableIMEPersonalizedLearning: false,
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: context.t('keys.field.name'),
                        errorText: _name.text.trim().isEmpty ? context.t('keys.generate.nameMissing') : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: largeButtonStyle,
                      onPressed: _name.text.trim().isEmpty ? null : () => unawaited(_add()),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(context.t('keys.import.add')),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
