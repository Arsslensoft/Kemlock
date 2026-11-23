/// The Sign sheet (openspec: add-pgp-messages): a typed message becomes
/// clear-signed text, which stays readable; a file gets a detached
/// signature beside it, named after it with `.sig` added, and is not
/// changed. Either is handed to the share sheet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../keys/card_key_use.dart';
import '../notes/note_files.dart' show fileSizeText;
import '../vault/add_to_vault_sheet.dart';
import 'encrypt_sheet.dart' show showPgpSignerPicker, vaultKeyOfPerson;
import 'pgp_controller.dart';
import 'pgp_job.dart';
import 'pgp_people.dart';
import 'pgp_widgets.dart';

/// Opens the Sign sheet, with [text] or [file] to sign already in place
/// (something shared to Kemlock).
Future<void> showSignSheet(BuildContext context, {String? text, PickedPath? file}) => showAppBottomSheet<void>(
  context,
  label: context.t('pgp.sign.title'),
  builder: (_) => SignSheet(text: text, file: file),
);

class SignSheet extends ConsumerStatefulWidget {
  const SignSheet({super.key, this.text, this.file});

  /// The message to start with.
  final String? text;

  /// The file to start with, which the sheet then deletes as it does a
  /// picker's copy.
  final PickedPath? file;

  @override
  ConsumerState<SignSheet> createState() => _SignSheetState();
}

class _SignSheetState extends ConsumerState<SignSheet> with ClosesOnLock {
  late final PgpJobController _jobs;
  final _message = TextEditingController();
  PickedPath? _file;
  String? _signerId;
  String? _error;

  /// What the last run made, to share again.
  String? _signedText;
  ({Uint8List bytes, String name})? _signature;

  @override
  void initState() {
    super.initState();
    _jobs = ref.read(pgpJobControllerProvider.notifier);
    // Every PGP key of the vault can be chosen; one that may not sign says why when it is used
    final own = ref.read(pgpOwnPeopleProvider).where((person) => person.canSign).toList();
    final last = ref.read(pgpLastSignerProvider);
    _signerId = own.any((person) => person.vaultKeyId == last)
        ? last
        : (own.where((person) => person.isUsable).firstOrNull ?? own.firstOrNull)?.vaultKeyId;
    _message.text = widget.text ?? '';
    if (widget.file case final file?) {
      _jobs.adopt(file.path);
      _file = file;
    }
    _message.addListener(_edited);
    closeOnLock();
  }

  @override
  void dispose() {
    unawaited(_jobs.discard());
    _message.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
    _error = null;
    _signedText = null;
    _signature = null;
  });

  Future<void> _pickFile() async {
    final picked = await ref.read(fileServiceProvider).pickFilePath();
    if (picked == null) return;
    _jobs.adopt(picked.path);
    if (!mounted) return;
    await _dropFile();
    _file = picked;
    _edited();
  }

  Future<void> _dropFile() async {
    final file = _file;
    if (file == null) return;
    _file = null;
    await _jobs.forget(file.path);
    if (mounted) _edited();
  }

  Future<void> _pickSigner() async {
    final own = ref.read(pgpOwnPeopleProvider).where((person) => person.canSign).toList();
    if (own.length < 2) return;
    final chosen = await showPgpSignerPicker(context, own, selected: _signerId);
    if (chosen == null || !mounted) return;
    ref.read(pgpLastSignerProvider.notifier).choose(chosen.vaultKeyId!);
    _signerId = chosen.vaultKeyId;
    _edited();
  }

  void _addKey() {
    final under = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    unawaited(showAddToVaultSheet(under));
  }

  Future<void> _share() async {
    final files = ref.read(fileServiceProvider);
    final text = _signedText;
    final signature = _signature;
    if (text != null) await files.shareText(text);
    if (signature != null) await files.shareFile(signature.name, signature.bytes, mimeType: 'application/pgp-signature');
  }

  Future<void> _sign(PgpPerson signer) async {
    final key = vaultKeyOfPerson(ref, signer);
    if (key == null || _jobs.isRunning) return;
    final messages = context.messages;
    final file = _file;
    final text = file == null ? Uint8List.fromList(utf8.encode(_message.text)) : null;
    if (text != null && text.length > pgp.maxPgpTextLength) {
      setState(() => _error = messages.t('pgp.error.textTooLarge'));
      return;
    }
    // The passphrase of the key is asked for once a run says it is needed: a
    // key that cannot sign at all says so without a prompt
    String? passphrase;
    // A key on a security key signs there (openspec: add-openpgp-card)
    final card = key.isOnCard ? CardKeyBridge(context, ref) : null;
    while (true) {
      final outcome = await _jobs.run(
        SignRequest(
          now: ref.read(clockProvider)(),
          text: text,
          inputPath: file?.path,
          signer: jobKeyOf(key, passphrase: passphrase),
        ),
        pickedCopy: file?.path,
        card: card,
      );
      if (!mounted) return;
      switch (outcome) {
        case PgpSignedOutcome(:final bytes):
          setState(() {
            _error = null;
            _file = null;
            _signedText = file == null ? utf8.decode(bytes) : null;
            _signature = file == null ? null : (bytes: bytes, name: '${file.name}.sig');
          });
          await _share();
          return;
        case PgpFailedOutcome(:final error):
          if (error.problem == pgp.PgpProblem.wrongPassphrase || error.problem == pgp.PgpProblem.passphraseNeeded) {
            passphrase = await askPgpPassphrase(
              context,
              title: messages.t('pgp.keyPassphrase.title', {'name': signer.name}),
              body: messages.t('pgp.keyPassphrase.body'),
              error: error.problem == pgp.PgpProblem.wrongPassphrase ? messages.t('pgp.error.wrongKeyPassphrase') : null,
            );
            if (passphrase == null || !mounted) return;
            continue;
          }
          setState(() => _error = pgpErrorText(messages, error, name: signer.name));
          return;
        default:
          if (card?.failureText(context) case final text?) setState(() => _error = text);
          return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // A key of an algorithm the app does not sign with is not offered
    final own = ref.watch(pgpOwnPeopleProvider).where((person) => person.canSign).toList();
    // With no key that can still sign, there is nothing to choose from
    final signer = own.any((person) => person.isUsable)
        ? own.where((person) => person.vaultKeyId == _signerId).firstOrNull ?? own.first
        : null;
    final working = ref.watch(pgpJobControllerProvider) != null;
    final file = _file;
    final made = _signedText != null || _signature != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.draw_outlined), title: context.t('pgp.sign.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: signer == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppAlert(severity: AlertSeverity.info, child: Text(context.t('pgp.sign.needKey'))),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        style: largeButtonStyle,
                        onPressed: _addKey,
                        icon: const Icon(Icons.add_rounded),
                        label: Text(context.t('pgp.sign.addKey')),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Rise(
                        child: file == null
                            ? TextField(
                                enableIMEPersonalizedLearning: false,
                                controller: _message,
                                enabled: !working,
                                minLines: 5,
                                maxLines: 10,
                                textCapitalization: TextCapitalization.sentences,
                                decoration: InputDecoration(labelText: context.t('pgp.sign.message'), alignLabelWithHint: true),
                              )
                            : Group(
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
                      ),
                      Rise(
                        delay: const Duration(milliseconds: 60),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: working ? null : () => unawaited(file == null ? _pickFile() : _dropFile()),
                            child: Text(context.t(file == null ? 'pgp.encrypt.chooseFile' : 'pgp.encrypt.writeMessage')),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Rise(
                        delay: const Duration(milliseconds: 120),
                        child: Group(
                          children: [
                            GroupRow(
                              first: true,
                              primary: context.t('pgp.sign.signAs'),
                              secondary: signer.ed25519Signatures ? context.t('pgp.sign.ed25519Only') : null,
                              value: PgpRowValue(signer.name),
                              onTap: own.length > 1 && !working ? () => unawaited(_pickSigner()) : null,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                        child: Text(context.t('pgp.sign.body'), style: AppType.caption.copyWith(color: p.textSecondary)),
                      ),
                      const SizedBox(height: 20),
                      if (_error != null) PgpErrorLine(_error!),
                      if (made && !working)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: AppAlert(
                            severity: AlertSeverity.success,
                            child: Row(
                              children: [
                                Expanded(child: Text(context.t('pgp.sign.done'))),
                                TextButton(onPressed: () => unawaited(_share()), child: Text(context.t('pgp.encrypt.shareAgain'))),
                              ],
                            ),
                          ),
                        ),
                      Rise(
                        delay: const Duration(milliseconds: 180),
                        child: PgpWorkButton(
                          label: context.t('pgp.sign.button'),
                          onPressed: file != null || _message.text.isNotEmpty ? () => unawaited(_sign(signer)) : null,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
