/// The Verify sheet (openspec: add-pgp-messages): clear-signed text or a
/// signed message pasted in, or a file with its detached signature, and
/// one answer per signature: good from one of the vault's keys, good from
/// a key given for this check and not checked, bad, or made by a key that
/// is not at hand, whose owner's public key can then be given.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../notes/note_files.dart' show fileSizeText;
import 'add_someone_sheet.dart';
import 'pgp_controller.dart';
import 'pgp_job.dart';
import 'pgp_people.dart';
import 'pgp_widgets.dart';

/// Opens the Verify sheet, with [text], a signed [file] or a detached
/// [signature] already in place (something shared to Kemlock). With a
/// signature alone, the file it signs is still to choose.
Future<void> showVerifySheet(BuildContext context, {String? text, PickedPath? file, PickedPath? signature}) => showAppBottomSheet<void>(
  context,
  label: context.t('pgp.verify.title'),
  builder: (_) => VerifySheet(text: text, file: file, signature: signature),
);

class VerifySheet extends ConsumerStatefulWidget {
  const VerifySheet({super.key, this.text, this.file, this.signature});

  /// The signed message or armored signature to start with, as if pasted.
  final String? text;

  /// The signed file, or the detached signature, to start with, which the
  /// sheet then deletes as it does a picker's copy.
  final PickedPath? file;
  final PickedPath? signature;

  @override
  ConsumerState<VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends ConsumerState<VerifySheet> with ClosesOnLock {
  late final PgpJobController _jobs;
  final _input = TextEditingController();
  PickedPath? _file;
  PickedPath? _signature;
  String? _error;
  pgp.PgpVerified? _verified;
  final _given = <PgpPerson>[];

  @override
  void initState() {
    super.initState();
    _jobs = ref.read(pgpJobControllerProvider.notifier);
    _input.text = widget.text ?? '';
    for (final given in [widget.file, widget.signature]) {
      if (given != null) _jobs.adopt(given.path);
    }
    _file = widget.file;
    _signature = widget.signature;
    _input.addListener(_edited);
    closeOnLock();
  }

  @override
  void dispose() {
    unawaited(_jobs.discard());
    _input.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
    _error = null;
    _verified = null;
  });

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && mounted) _input.text = text;
  }

  Future<void> _pick({required bool signature}) async {
    final picked = await ref.read(fileServiceProvider).pickFilePath();
    if (picked == null) return;
    _jobs.adopt(picked.path);
    if (!mounted) return;
    final old = signature ? _signature : _file;
    if (signature) {
      _signature = picked;
    } else {
      _file = picked;
    }
    _edited();
    if (old != null) await _jobs.forget(old.path);
  }

  Future<void> _drop({required bool signature}) async {
    final old = signature ? _signature : _file;
    if (old == null) return;
    if (signature) {
      _signature = null;
    } else {
      _file = null;
      // A signature is of the file it was chosen for
      final its = _signature;
      _signature = null;
      if (its != null) await _jobs.forget(its.path);
    }
    await _jobs.forget(old.path);
    if (mounted) _edited();
  }

  Future<void> _verify() async {
    if (_jobs.isRunning) return;
    final messages = context.messages;
    final file = _file;
    final signature = _signature;
    final text = Uint8List.fromList(utf8.encode(_input.text));
    if (file == null && text.isEmpty) return;
    if (text.length > pgp.maxPgpTextLength) {
      setState(() => _error = messages.t('pgp.error.textTooLarge'));
      return;
    }
    // A file is checked against the signature chosen for it, or against one
    // pasted in armor; without either it is read as a signed message
    final PgpRequest request = file == null
        ? VerifyRequest(now: ref.read(clockProvider)(), text: text, verifiers: verifierKeys(ref, _given))
        : VerifyRequest(
            now: ref.read(clockProvider)(),
            inputPath: file.path,
            signaturePath: signature?.path,
            signature: signature == null && text.isNotEmpty ? text : null,
            verifiers: verifierKeys(ref, _given),
          );
    final outcome = await _jobs.run(request);
    if (!mounted) return;
    switch (outcome) {
      case PgpVerifiedOutcome(:final verified):
        setState(() {
          _error = null;
          _verified = verified;
        });
      case PgpFailedOutcome(:final error):
        setState(() {
          _verified = null;
          _error = pgpErrorText(messages, error);
        });
      default:
        break;
    }
  }

  Future<void> _giveKey() async {
    final person = await showAddSomeoneSheet(context, forSigner: true);
    if (person == null || !mounted) return;
    _given.add(person);
    await _verify();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final working = ref.watch(pgpJobControllerProvider) != null;
    final file = _file;
    final signature = _signature;
    final verified = _verified;
    final content = verified?.content;
    final text = content == null ? null : shownText(content);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.verified_user_outlined), title: context.t('pgp.verify.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (file == null && signature == null)
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _input,
                    enabled: !working,
                    minLines: 5,
                    maxLines: 9,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: AppType.mono(fontSize: 12, color: p.text),
                    decoration: InputDecoration(
                      labelText: context.t('pgp.verify.field'),
                      hintText: '-----BEGIN PGP SIGNED MESSAGE-----',
                      alignLabelWithHint: true,
                    ),
                  )
                else
                  Group(
                    children: [
                      if (file != null)
                        GroupRow(
                          first: true,
                          icon: const Icon(Icons.insert_drive_file_outlined),
                          primary: file.name,
                          secondary: fileSizeText(context, file.size),
                          control: IconButton(
                            onPressed: working ? null : () => unawaited(_drop(signature: false)),
                            tooltip: context.t('pgp.encrypt.removeFile'),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                      // A signature shared alone shows before the file it signs is chosen
                      if (signature != null)
                        GroupRow(
                          first: file == null,
                          icon: const Icon(Icons.draw_outlined),
                          primary: signature.name,
                          secondary: fileSizeText(context, signature.size),
                          control: IconButton(
                            onPressed: working ? null : () => unawaited(_drop(signature: true)),
                            tooltip: context.t('pgp.verify.removeSignature'),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 4),
                Wrap(
                  children: [
                    if (file == null && signature == null)
                      TextButton.icon(
                        onPressed: working ? null : () => unawaited(_paste()),
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        label: Text(context.t('pgp.decrypt.paste')),
                      ),
                    TextButton.icon(
                      onPressed: working ? null : () => unawaited(_pick(signature: false)),
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: Text(context.t('pgp.decrypt.chooseFile')),
                    ),
                    if (file != null)
                      TextButton.icon(
                        onPressed: working ? null : () => unawaited(_pick(signature: true)),
                        icon: const Icon(Icons.draw_outlined, size: 18),
                        label: Text(context.t('pgp.verify.chooseSignature')),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_error != null) PgpErrorLine(_error!),
                if (verified != null) ...[
                  SignatureBanners(results: verified.signatures, given: _given, onGiveKey: () => unawaited(_giveKey())),
                  if (text != null) ...[
                    SectionLabel(context.t('pgp.verify.signedText')),
                    GroupCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(text, style: AppType.body1.copyWith(height: 1.55, color: p.text)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
                PgpWorkButton(
                  label: context.t('pgp.verify.button'),
                  onPressed: file != null || _input.text.trim().isNotEmpty ? () => unawaited(_verify()) : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
