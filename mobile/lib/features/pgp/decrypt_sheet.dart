/// The Decrypt sheet (openspec: add-pgp-messages, `Decrypt.dc.html`):
/// pasted text or a file goes in; the sheet finds which of the vault's
/// keys opens it, asks for a passphrase only when one is needed, and
/// shows who signed it, the message, what opened it and how it was
/// encrypted. Nothing decrypted is saved: the text is gone when the sheet
/// closes, and a decrypted file with it unless the person saved it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../platform/secret_clipboard.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../keys/card_key_use.dart';
import '../keys/key_standing.dart';
import '../notes/note_files.dart' show fileSizeText;
import 'add_someone_sheet.dart';
import 'encrypt_sheet.dart';
import 'pgp_controller.dart';
import 'pgp_job.dart';
import 'pgp_people.dart';
import 'pgp_widgets.dart';

/// Opens the Decrypt sheet, with the message in [text] or [file] already
/// in place (something shared to Kemlock).
Future<void> showDecryptSheet(BuildContext context, {String? text, PickedPath? file}) => showAppBottomSheet<void>(
  context,
  label: context.t('pgp.decrypt.title'),
  builder: (_) => DecryptSheet(text: text, file: file),
);

/// Says what a message is without any secret; tests may replace it.
final pgpInspectorProvider = Provider<pgp.PgpMessageInfo Function(pgp.PgpData data)>((ref) => pgp.inspectMessage);

/// What was decrypted, as the sheet shows it: [text], or a file.
class _Shown {
  const _Shown(this.message, {this.text, this.path, this.name, this.size});

  final pgp.PgpDecrypted message;
  final String? text;
  final String? path;
  final String? name;
  final int? size;
}

class DecryptSheet extends ConsumerStatefulWidget {
  const DecryptSheet({super.key, this.text, this.file});

  /// The message to start with, as if pasted.
  final String? text;

  /// The file to start with, which the sheet then deletes as it does a
  /// picker's copy.
  final PickedPath? file;

  @override
  ConsumerState<DecryptSheet> createState() => _DecryptSheetState();
}

class _DecryptSheetState extends ConsumerState<DecryptSheet> with ClosesOnLock {
  late final PgpJobController _jobs;
  final _input = TextEditingController();
  PickedPath? _file;
  String? _error;
  _Shown? _shown;

  /// Keys given to check this message's signature with.
  final _given = <PgpPerson>[];

  @override
  void initState() {
    super.initState();
    _jobs = ref.read(pgpJobControllerProvider.notifier);
    _input.text = widget.text ?? '';
    if (widget.file case final file?) {
      _jobs.adopt(file.path);
      _file = file;
    }
    _input.addListener(() => setState(() => _error = null));
    closeOnLock();
  }

  @override
  void dispose() {
    // What was decrypted goes with the sheet
    unawaited(_jobs.discard());
    _input.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    _input.text = text;
  }

  Future<void> _pickFile() async {
    final picked = await ref.read(fileServiceProvider).pickFilePath();
    if (picked == null) return;
    _jobs.adopt(picked.path);
    if (!mounted) return;
    final old = _file;
    setState(() {
      _file = picked;
      _error = null;
    });
    if (old != null) await _jobs.forget(old.path);
  }

  Future<void> _dropFile() async {
    final file = _file;
    if (file == null) return;
    setState(() => _file = null);
    await _jobs.forget(file.path);
  }

  Future<String?> _askKey(VaultKey key, {String? error}) => askPgpPassphrase(
    context,
    title: context.t('pgp.keyPassphrase.title', {'name': vaultKeyTitle(ref, key)}),
    body: context.t('pgp.keyPassphrase.body'),
    error: error,
  );

  Future<void> _decrypt() async {
    if (_jobs.isRunning) return;
    final messages = context.messages;
    final file = _file;
    final text = file == null ? Uint8List.fromList(utf8.encode(_input.text)) : null;
    if (text != null && text.isEmpty) return;
    void fail(String message) => setState(() => _error = message);
    if (text != null && text.length > pgp.maxPgpTextLength) return fail(messages.t('pgp.error.textTooLarge'));
    setState(() => _error = null);

    // What it is, read without a secret, so that what cannot be opened is
    // named before any passphrase is asked for
    final pgp.PgpMessageInfo info;
    try {
      info = ref.read(pgpInspectorProvider)(file != null ? pgp.PgpData.file(file.path) : pgp.PgpData.bytes(text!));
    } on pgp.PgpException catch (error) {
      return fail(pgpErrorText(messages, error));
    }
    switch (info.kind) {
      case pgp.PgpMessageKind.detachedSignature:
        return fail(messages.t('pgp.error.isSignature'));
      case pgp.PgpMessageKind.publicKey || pgp.PgpMessageKind.secretKey:
        return fail(messages.t('pgp.error.isKey'));
      default:
        break;
    }
    if (info.noIntegrity) return fail(messages.t('pgp.error.noIntegrity'));
    if (info.unsupported != null) return fail(messages.t('pgp.error.unsupported', {'name': info.unsupported}));

    final keys = pgpVaultKeys(ref.read(vaultControllerProvider));
    // Asked for only once a run says which is needed: the passphrase of a
    // key the message names, by that key's name, or the message's own
    final passphrases = <String, String>{};
    String? messagePassphrase;
    // A key on a security key opens it there, once no other key did (openspec: add-openpgp-card)
    final card = CardKeyBridge.needed(keys) ? CardKeyBridge(context, ref) : null;

    while (true) {
      final directory = await _jobs.newDirectory();
      final outcome = await _jobs.run(
        DecryptRequest(
          now: ref.read(clockProvider)(),
          text: text,
          inputPath: file?.path,
          inputName: file?.name,
          outputDirectory: directory.path,
          keys: [for (final key in keys) jobKeyOf(key, passphrase: passphrases[key.id])],
          passphrase: messagePassphrase,
          verifiers: verifierKeys(ref, _given),
        ),
        directory: directory,
        card: card,
      );
      if (!mounted) return;
      switch (outcome) {
        case PgpDecryptedOutcome(:final message):
          await _show(message, directory);
          return;
        case PgpFailedOutcome(:final error):
          final wrong = error.problem == pgp.PgpProblem.wrongPassphrase;
          if (!wrong && error.problem != pgp.PgpProblem.passphraseNeeded) return fail(pgpErrorText(messages, error));
          final key = keys.where((k) => vaultKeyHas(ref, k, error.fingerprint)).firstOrNull;
          final String? passphrase;
          if (key != null) {
            passphrase = await _askKey(key, error: wrong ? messages.t('pgp.error.wrongKeyPassphrase') : null);
            if (passphrase != null) passphrases[key.id] = passphrase;
          } else if (error.fingerprint == null) {
            passphrase = await askPgpPassphrase(
              context,
              title: messages.t('pgp.messagePassphrase.title'),
              error: wrong ? messages.t('pgp.error.wrongPassphrase') : null,
            );
            messagePassphrase = passphrase;
          } else {
            return fail(pgpErrorText(messages, error));
          }
          // Cancelled: the message stays where it was pasted, to try again
          if (passphrase == null || !mounted) return;
        default:
          if (card?.failureText(context) case final text?) fail(text);
          return;
      }
    }
  }

  Future<void> _show(pgp.PgpDecrypted message, Directory directory) async {
    final bytes = message.bytes;
    // Pasted text, and a file the sender marked as text, are read on screen
    final text = bytes == null || (_file != null && !message.isText) ? null : shownText(bytes);
    if (text != null) {
      setState(() => _shown = _Shown(message, text: text));
      return;
    }
    var path = message.path;
    final name = pgp.cleanFileName(message.fileName, inputName: _file?.name);
    if (path == null) {
      path = '${directory.path}${Platform.pathSeparator}$name';
      File(path).writeAsBytesSync(bytes!, flush: true);
    }
    if (mounted) setState(() => _shown = _Shown(message, path: path, name: name, size: message.length));
  }

  Future<void> _giveKey() async {
    final person = await showAddSomeoneSheet(context, forSigner: true);
    if (person == null || !mounted) return;
    _given.add(person);
    // Read again, now with their key to check against
    await _decrypt();
  }

  /// Whoever signed it with a signature that matched, when their key is at hand.
  PgpPerson? get _signer {
    for (final result in _shown?.message.signatures ?? const <pgp.SignatureResult>[]) {
      if (result.verdict != pgp.SignatureVerdict.good) continue;
      final person = personWith(ref, result.signerFingerprint, _given);
      if (person != null) return person;
    }
    return null;
  }

  void _reply() {
    final signer = _signer;
    // The page under the sheets, which is still there once this one is gone
    final under = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    unawaited(showEncryptSheet(under, to: signer));
  }

  Future<void> _copy(String text) async {
    final messages = context.messages;
    if (await ref.read(secretClipboardProvider).copy(text)) {
      ref.read(toastsProvider.notifier).show(messages.t('pgp.decrypted.copied'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: const Icon(Icons.lock_open_rounded),
          title: context.t(
            shown == null
                ? 'pgp.decrypt.title'
                : shown.message.encrypted
                ? 'pgp.decrypted.title'
                : 'pgp.decrypted.titleSigned',
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: shown == null ? _inputStep(context) : _resultStep(context, shown),
          ),
        ),
      ],
    );
  }

  Widget _inputStep(BuildContext context) {
    final p = context.palette;
    final working = ref.watch(pgpJobControllerProvider) != null;
    final file = _file;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (file == null)
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _input,
            enabled: !working,
            minLines: 6,
            maxLines: 10,
            autocorrect: false,
            enableSuggestions: false,
            style: AppType.mono(fontSize: 12, color: p.text),
            decoration: InputDecoration(
              labelText: context.t('pgp.decrypt.field'),
              hintText: '-----BEGIN PGP MESSAGE-----',
              alignLabelWithHint: true,
            ),
          )
        else
          Group(
            children: [
              GroupRow(
                first: true,
                icon: const Icon(Icons.insert_drive_file_outlined),
                primary: file.name,
                secondary: fileSizeText(context, file.size),
                control: IconButton(
                  onPressed: working ? null : () => unawaited(_dropFile()),
                  tooltip: context.t('pgp.encrypt.removeFile'),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        const SizedBox(height: 4),
        Wrap(
          children: [
            if (file == null)
              TextButton.icon(
                onPressed: working ? null : () => unawaited(_paste()),
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: Text(context.t('pgp.decrypt.paste')),
              ),
            TextButton.icon(
              onPressed: working ? null : () => unawaited(_pickFile()),
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(context.t('pgp.decrypt.chooseFile')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_error != null) PgpErrorLine(_error!),
        PgpWorkButton(
          label: context.t('pgp.decrypt.button'),
          onPressed: file != null || _input.text.trim().isNotEmpty ? () => unawaited(_decrypt()) : null,
        ),
      ],
    );
  }

  Widget _resultStep(BuildContext context, _Shown shown) {
    final p = context.palette;
    final message = shown.message;
    final text = shown.text;
    final files = ref.read(fileServiceProvider);
    final opener = personWith(ref, message.openedWithFingerprint);
    final openerNote = switch (opener?.standing) {
      Standing.revoked => context.t('pgp.decrypted.keyRevoked'),
      Standing.expired => context.t('pgp.decrypted.keyExpired'),
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Rise(
          child: SignatureBanners(results: message.signatures, given: _given, onGiveKey: () => unawaited(_giveKey())),
        ),
        Rise(
          delay: const Duration(milliseconds: 60),
          child: SectionLabel(context.t(text != null ? 'pgp.decrypted.message' : 'pgp.decrypted.file')),
        ),
        Rise(
          delay: const Duration(milliseconds: 60),
          child: text != null
              ? GroupCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    // Selected and copied, the decrypted text goes through the secret clipboard as Copy does
                    child: SecretSelection(
                      child: SelectableText(
                        text,
                        style: AppType.body1.copyWith(height: 1.55, color: p.text),
                        contextMenuBuilder: secretTextMenu,
                      ),
                    ),
                  ),
                )
              : Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.insert_drive_file_outlined),
                      primary: shown.name!,
                      secondary: fileSizeText(context, shown.size!),
                    ),
                  ],
                ),
        ),
        if (text == null && message.isText)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Text(context.t('pgp.decrypted.asFile'), style: AppType.body2.copyWith(color: p.textSecondary)),
          ),
        if (message.encrypted) ...[
          const SizedBox(height: 12),
          Rise(
            delay: const Duration(milliseconds: 120),
            child: Group(
              children: [
                GroupRow(
                  first: true,
                  primary: context.t('pgp.decrypted.openedWith'),
                  secondary: openerNote,
                  value: PgpRowValue(message.openedWithPassphrase ? context.t('pgp.decrypted.aPassphrase') : opener?.name ?? ''),
                ),
                GroupRow(primary: context.t('pgp.decrypted.encryption'), value: PgpRowValue(encryptionSummary(message), mono: true)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        Rise(
          delay: const Duration(milliseconds: 240),
          child: Row(
            children: [
              if (text != null)
                Expanded(
                  child: OutlinedButton(
                    style: largeButtonStyle,
                    onPressed: () => unawaited(_copy(text)),
                    child: Text(context.t('pgp.decrypted.copy')),
                  ),
                )
              else ...[
                Expanded(
                  child: OutlinedButton(
                    style: largeButtonStyle,
                    onPressed: () => unawaited(files.saveFileFrom(shown.path!, shown.name!)),
                    child: Text(context.t('pgp.decrypted.save')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: largeButtonStyle,
                    onPressed: () => unawaited(files.shareFileFrom(shown.path!, shown.name!)),
                    child: Text(context.t('pgp.decrypted.share')),
                  ),
                ),
              ],
              if (text != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(style: largeButtonStyle, onPressed: _reply, child: Text(context.t('pgp.decrypted.reply'))),
                ),
              ],
            ],
          ),
        ),
        if (text == null) ...[
          const SizedBox(height: 10),
          FilledButton(style: largeButtonStyle, onPressed: _reply, child: Text(context.t('pgp.decrypted.reply'))),
        ],
        const SizedBox(height: 10),
        Text(
          context.t(text != null ? 'pgp.decrypted.nothingSaved' : 'pgp.decrypted.nothingSavedFile'),
          textAlign: TextAlign.center,
          style: AppType.caption.copyWith(color: p.textSecondary),
        ),
      ],
    );
  }
}
