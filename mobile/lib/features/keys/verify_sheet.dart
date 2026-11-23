import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/keys/git_signature.dart';
import '../../crypto/keys/keys.dart' show KeyFormatException;
import '../../crypto/keys/sshsig.dart';
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../notes/note_files.dart';
import 'sign_sheet.dart';
import 'ssh_fingerprint.dart';

/// Opens the sheet that checks an SSH signature. It needs no key of the
/// vault, so it opens from the Keys filter as well as from an SSH key.
Future<void> showVerifySheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('keys.verify.entry'), builder: (_) => const VerifySheet());

/// Why there was no signature to check.
enum SshCheckProblem {
  /// No `SSH SIGNATURE` block: a PGP signature, plain text, another kind of block.
  notSsh,

  /// An `SSH SIGNATURE` block that is cut short or has bytes after its end.
  damaged,

  /// A commit or tag that carries no signature.
  gitUnsigned,

  /// A commit or tag signed with PGP.
  gitPgp,

  /// Not the raw text of a commit or a tag.
  notGit,
}

/// What checking found: a [problem] that kept it from being checked, or
/// the [signature] and how it stands.
class SshCheck {
  const SshCheck.failed(SshCheckProblem this.problem) : signature = null, result = null;

  const SshCheck.checked(SshSignature this.signature, SshsigResult this.result) : problem = null;

  final SshCheckProblem? problem;
  final SshSignature? signature;
  final SshsigResult? result;
}

/// Checks the armored [signature] over [message] for [namespace]; or, with
/// [git], takes the signature out of the raw commit or tag [message] and
/// checks it for git. Never throws for what a person can give it.
Future<SshCheck> sshCheck({String? signature, required Uint8List message, String namespace = gitSshsigNamespace, bool git = false}) async {
  try {
    if (git) {
      final found = await verifyGitSignature(message);
      return switch (found.kind) {
        GitSignatureKind.ssh => SshCheck.checked(found.signature!, found.result!),
        GitSignatureKind.pgp => const SshCheck.failed(SshCheckProblem.gitPgp),
        GitSignatureKind.other => const SshCheck.failed(SshCheckProblem.notSsh),
        GitSignatureKind.unsigned => const SshCheck.failed(SshCheckProblem.gitUnsigned),
      };
    }
    final read = readSshsig(signature ?? '');
    return SshCheck.checked(read, await sshsigVerify(read, namespace, message));
  } on NotAGitObjectException {
    return const SshCheck.failed(SshCheckProblem.notGit);
  } on SshsigFormatException catch (error) {
    return SshCheck.failed(error.problem == SshsigProblem.damaged ? SshCheckProblem.damaged : SshCheckProblem.notSsh);
  }
}

/// [sshCheck] off the UI isolate: hashing a large file takes a moment.
Future<SshCheck> sshCheckInBackground({
  String? signature,
  required Uint8List message,
  String namespace = gitSshsigNamespace,
  bool git = false,
}) => Isolate.run(
  () => sshCheck(signature: signature, message: message, namespace: namespace, git: git),
  debugName: 'sshsigVerify',
);

/// Checks an SSH signature; tests replace it with one that needs no isolate.
final sshCheckerProvider = Provider<Future<SshCheck> Function({String? signature, required Uint8List message, String namespace, bool git})>(
  (ref) => sshCheckInBackground,
);

/// What is checked: a signature beside its file or text, or a git object
/// that carries its own.
enum VerifyMode { data, git }

/// What the sheet says once it has checked: the alert's colour and words,
/// and the signer to show under it.
typedef _Verdict = ({AlertSeverity severity, String id, Map<String, Object?> args, SshSignature? signer});

/// Checks an OpenSSH signature against a file or text and a namespace, or
/// the signature a git commit or tag carries, and says who signed.
///
/// A good signature is a success only when Kemlock can say whose key made
/// it: an SSH key of this vault, or the public key the person pasted. A
/// good signature by any other key is a warning that shows the fingerprint
/// to compare, and one by a key other than the pasted one is an error.
/// Everything else says why: not what was signed, made for another
/// namespace, a key type Kemlock does not check, RSA with SHA-1, not an
/// SSH signature, or a damaged one.
///
/// Nothing is stored: what was given and the answer go with the sheet.
class VerifySheet extends ConsumerStatefulWidget {
  const VerifySheet({super.key});

  @override
  ConsumerState<VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends ConsumerState<VerifySheet> {
  final _signature = TextEditingController();
  final _text = TextEditingController();
  final _namespace = TextEditingController();
  final _git = TextEditingController();
  final _signer = TextEditingController();
  var _mode = VerifyMode.data;
  var _source = SignSource.file;
  var _purpose = SignPurpose.file;
  PickedFile? _file;
  PickedFile? _gitFile;
  var _tooLarge = false;
  var _checking = false;
  _Verdict? _verdict;

  @override
  void initState() {
    super.initState();
    for (final controller in [_signature, _text, _namespace, _git, _signer]) {
      controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final controller in [_signature, _text, _namespace, _git, _signer]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// What is checked changed: the answer shown is no longer its.
  void _changed() => setState(() => _verdict = null);

  String get _chosenNamespace => NamespaceChoice.namespaceOf(_purpose, _namespace.text);

  bool get _ready {
    if (_checking) return false;
    if (_mode == VerifyMode.git) return _gitFile != null || _git.text.trim().isNotEmpty;
    return _signature.text.trim().isNotEmpty &&
        isSshsigNamespace(_chosenNamespace) &&
        (_source == SignSource.file ? _file != null : _text.text.isNotEmpty);
  }

  /// A picked file, or null when none was picked or it is over the limit.
  Future<PickedFile?> _pick() async {
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return null;
    final tooLarge = picked.bytes.length > maxSignedFileBytes;
    setState(() {
      _verdict = null;
      _tooLarge = tooLarge;
    });
    return tooLarge ? null : picked;
  }

  Future<void> _openSignature() async {
    final picked = await _pick();
    if (picked != null) _signature.text = utf8.decode(picked.bytes, allowMalformed: true);
  }

  Future<void> _pickFile() async {
    final picked = await _pick();
    if (picked != null) setState(() => _file = picked);
  }

  Future<void> _pickGit() async {
    final picked = await _pick();
    if (picked == null) return;
    _git.clear();
    setState(() => _gitFile = picked);
  }

  Future<void> _verify() async {
    // The key the person expects, read before anything is checked
    final Uint8List? expected;
    try {
      expected = _signer.text.trim().isEmpty ? null : readSshPublicLine(_signer.text);
    } on KeyFormatException {
      setState(() => _verdict = (severity: AlertSeverity.error, id: 'keys.verify.badKey', args: const {}, signer: null));
      return;
    }
    final git = _mode == VerifyMode.git;
    final message = git
        // Text typed after a file was opened is what is checked
        ? (_git.text.trim().isEmpty ? _gitFile?.bytes : null) ?? Uint8List.fromList(utf8.encode(_git.text))
        : _source == SignSource.file
        ? _file!.bytes
        : Uint8List.fromList(utf8.encode(_text.text));
    final namespace = git ? gitSshsigNamespace : _chosenNamespace;
    setState(() => _checking = true);
    try {
      final check = await ref.read(sshCheckerProvider)(
        signature: git ? null : _signature.text,
        message: message,
        namespace: namespace,
        git: git,
      );
      if (mounted) setState(() => _verdict = _verdictOf(check, namespace, expected));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  _Verdict _verdictOf(SshCheck check, String namespace, Uint8List? expected) {
    _Verdict error(String id, [Map<String, Object?> args = const {}]) => (severity: AlertSeverity.error, id: id, args: args, signer: null);
    final signature = check.signature;
    final result = check.result;
    if (signature == null || result == null) {
      return error(switch (check.problem!) {
        SshCheckProblem.notSsh => 'keys.verify.notSsh',
        SshCheckProblem.damaged => 'keys.verify.damaged',
        SshCheckProblem.gitUnsigned => 'keys.verify.git.unsigned',
        SshCheckProblem.gitPgp => 'keys.verify.git.pgp',
        SshCheckProblem.notGit => 'keys.verify.git.notGit',
      });
    }
    switch (result.verdict) {
      case SshsigVerdict.bad:
        return error('keys.verify.bad');
      case SshsigVerdict.wrongNamespace:
        return error('keys.verify.namespace', {'made': result.detail ?? '', 'wanted': namespace});
      case SshsigVerdict.unsupported:
        return error('keys.verify.unsupported', {'type': result.detail ?? signature.keyType});
      case SshsigVerdict.weak:
        return error('keys.verify.weak');
      case SshsigVerdict.weakKey:
        return error('keys.verify.weakKey', {'name': result.detail ?? ''});
      case SshsigVerdict.good:
        if (expected != null) {
          return listEquals(expected, signature.publicKeyBlob)
              ? (severity: AlertSeverity.success, id: 'keys.verify.good.given', args: const {}, signer: signature)
              : (severity: AlertSeverity.error, id: 'keys.verify.otherKey', args: const {}, signer: signature);
        }
        final own = _vaultKeyWith(signature.fingerprint);
        return own != null
            ? (severity: AlertSeverity.success, id: 'keys.verify.good.own', args: {'name': own.name}, signer: signature)
            : (severity: AlertSeverity.warning, id: 'keys.verify.good.unknown', args: const {}, signer: signature);
    }
  }

  /// The vault's SSH key with [fingerprint], when it has one.
  VaultKey? _vaultKeyWith(String fingerprint) {
    for (final key in ref.read(vaultControllerProvider).keys) {
      if (key.kind == KeyKind.ssh && ref.read(sshFingerprintProvider(key.id)) == fingerprint) return key;
    }
    return null;
  }

  Widget _fileButton(String label, PickedFile? file, VoidCallback onPressed, {Key? key}) => OutlinedButton.icon(
    key: key,
    onPressed: _checking ? null : onPressed,
    icon: const Icon(Icons.folder_open_rounded),
    label: Text(file == null ? label : '${file.name} · ${fileSizeText(context, file.bytes.length)}'),
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final verdict = _verdict;
    final mono = AppType.mono(fontSize: 12, color: p.text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.verified_outlined), title: context.t('keys.verify.entry')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedControl<VerifyMode>(
                  options: [
                    SegmentOption(value: VerifyMode.data, label: context.t('keys.verify.mode.data')),
                    SegmentOption(value: VerifyMode.git, label: context.t('keys.verify.mode.git')),
                  ],
                  value: _mode,
                  onChanged: (mode) => setState(() {
                    _mode = mode;
                    _verdict = null;
                    _tooLarge = false;
                  }),
                  semanticLabel: context.t('keys.verify.entry'),
                ),
                const SizedBox(height: 12),
                if (_mode == VerifyMode.data) ...[
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _signature,
                    minLines: 3,
                    maxLines: 6,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: mono,
                    decoration: InputDecoration(
                      labelText: context.t('keys.verify.signature'),
                      hintText: '-----BEGIN SSH SIGNATURE-----',
                      alignLabelWithHint: true,
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: _checking ? null : () => unawaited(_openSignature()),
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: Text(context.t('keys.verify.openSig')),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SegmentedControl<SignSource>(
                    options: [
                      SegmentOption(value: SignSource.file, label: context.t('keys.sign.file')),
                      SegmentOption(value: SignSource.text, label: context.t('keys.sign.text')),
                    ],
                    value: _source,
                    onChanged: (source) => setState(() {
                      _source = source;
                      _verdict = null;
                    }),
                    semanticLabel: context.t('keys.verify.mode.data'),
                    size: SegmentSize.small,
                  ),
                  const SizedBox(height: 10),
                  if (_source == SignSource.file)
                    _fileButton(context.t('keys.sign.chooseFile'), _file, () => unawaited(_pickFile()), key: const ValueKey('verify-file'))
                  else
                    TextField(
                      enableIMEPersonalizedLearning: false,
                      controller: _text,
                      minLines: 3,
                      maxLines: 8,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      decoration: InputDecoration(labelText: context.t('keys.sign.text'), alignLabelWithHint: true),
                    ),
                  const SizedBox(height: 16),
                  NamespaceChoice(
                    purpose: _purpose,
                    onChanged: (purpose) => setState(() {
                      _purpose = purpose;
                      _verdict = null;
                    }),
                    controller: _namespace,
                  ),
                ] else ...[
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _git,
                    minLines: 4,
                    maxLines: 8,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    style: mono,
                    decoration: InputDecoration(
                      labelText: context.t('keys.verify.mode.git'),
                      helperText: context.t('keys.verify.gitHint'),
                      helperMaxLines: 2,
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _fileButton(
                    context.t('keys.sign.chooseFile'),
                    _gitFile,
                    () => unawaited(_pickGit()),
                    key: const ValueKey('verify-git-file'),
                  ),
                ],
                if (_tooLarge) ...[
                  const SizedBox(height: 12),
                  AppAlert(
                    key: const ValueKey('verify-too-large'),
                    severity: AlertSeverity.error,
                    child: Text(context.t('keys.verify.tooLarge', {'size': fileSizeText(context, maxSignedFileBytes)})),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _signer,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  style: mono,
                  decoration: InputDecoration(labelText: context.t('keys.verify.signer'), hintText: 'ssh-ed25519 AAAA…'),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('verify-submit'),
                  style: largeButtonStyle,
                  onPressed: _ready ? () => unawaited(_verify()) : null,
                  icon: const Icon(Icons.verified_outlined),
                  label: Text(context.t('keys.verify.submit')),
                ),
                if (_checking) ...[const SizedBox(height: 12), const Center(child: Spinner())],
                if (verdict != null) ...[
                  const SizedBox(height: 16),
                  AppAlert(
                    key: const ValueKey('verify-result'),
                    severity: verdict.severity,
                    child: Text(context.t(verdict.id, verdict.args)),
                  ),
                  if (verdict.signer case final signer?) ...[
                    const SizedBox(height: 12),
                    Text(context.t('keys.verify.fingerprint'), style: AppType.caption.copyWith(color: p.textSecondary)),
                    const SizedBox(height: 4),
                    Text(
                      signer.keyType,
                      key: const ValueKey('signer-type'),
                      style: AppType.body2.copyWith(color: p.text),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      signer.fingerprint,
                      key: const ValueKey('signer-fingerprint'),
                      style: AppType.mono(fontSize: 13, color: p.text),
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
