import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/git_signature.dart';
import '../../crypto/keys/pkcs8.dart';
import '../../crypto/keys/sshsig.dart';
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../notes/note_files.dart';

/// Opens the sheet that signs a file or text with the SSH key [key].
Future<void> showSignSheet(BuildContext context, VaultKey key) => showAppBottomSheet<void>(
  context,
  label: context.t('keys.sign.title', {'name': key.name}),
  builder: (_) => SignSheet(keyId: key.id),
);

/// The largest file signed or verified: 64 MB. A file is read whole into
/// memory before it is hashed.
const maxSignedFileBytes = 64 * 1024 * 1024;

/// Signs [message] for [namespace] with the SSH key whose private half is
/// the PKCS#8 DER [pkcs8], off the UI isolate: hashing a large file and an
/// RSA signature both take a moment.
Future<String> sshSignInBackground(Uint8List pkcs8, String namespace, Uint8List message) =>
    Isolate.run(() async => sshsigSign(await readPkcs8(pkcs8), namespace, message), debugName: 'sshsigSign');

/// Makes an SSH signature; tests replace it with one that needs no isolate.
final sshSignerProvider = Provider<Future<String> Function(Uint8List pkcs8, String namespace, Uint8List message)>(
  (ref) => sshSignInBackground,
);

/// What is signed: a file, or typed text.
enum SignSource { file, text }

/// What a signature is for: its namespace.
enum SignPurpose {
  file('keys.sign.for.file'),
  git('keys.sign.for.git'),
  other('keys.sign.for.other');

  const SignPurpose(this.labelId);

  final String labelId;
}

/// The "What is it for?" choice of the sign and verify sheets: a file, a
/// git commit or tag, or another namespace typed in [controller]. The three
/// are radio rows, one under the other: "A git commit or tag" does not fit
/// a third of a phone's width, in English or in French.
class NamespaceChoice extends StatelessWidget {
  const NamespaceChoice({super.key, required this.purpose, required this.onChanged, required this.controller});

  final SignPurpose purpose;
  final ValueChanged<SignPurpose> onChanged;

  /// The namespace typed under "Other".
  final TextEditingController controller;

  /// The namespace chosen; empty or with a space in it when "Other" is not filled in properly.
  static String namespaceOf(SignPurpose purpose, String typed) => switch (purpose) {
    SignPurpose.file => 'file',
    SignPurpose.git => gitSshsigNamespace,
    SignPurpose.other => typed,
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(context.t('keys.sign.for'), style: AppType.caption.copyWith(color: context.palette.textSecondary)),
      // Its own Material, so the tiles' ink shows over the sheet's paper
      Material(
        type: MaterialType.transparency,
        child: RadioGroup<SignPurpose>(
          groupValue: purpose,
          onChanged: (chosen) {
            if (chosen != null) onChanged(chosen);
          },
          child: Column(
            children: [
              for (final purpose in SignPurpose.values)
                RadioListTile<SignPurpose>(
                  value: purpose,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.t(purpose.labelId), style: AppType.body1.copyWith(color: context.palette.text)),
                ),
            ],
          ),
        ),
      ),
      if (purpose == SignPurpose.other) ...[
        const SizedBox(height: 6),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: controller,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          style: AppType.mono(fontSize: 13, color: context.palette.text),
          decoration: InputDecoration(labelText: context.t('keys.sign.namespace')),
        ),
      ],
    ],
  );
}

/// Signs a file or typed text with an SSH key of the vault, and hands out
/// the armored signature `ssh-keygen -Y sign` would write: to copy, share
/// or save as `<file>.sig`.
///
/// The key is used where it is: nothing of its private half is shown,
/// copied or exported, so no warning or biometrics come first, and nothing
/// is stored. The data, the signature and the choices live in this sheet
/// and go with it.
class SignSheet extends ConsumerStatefulWidget {
  const SignSheet({super.key, required this.keyId});

  final String keyId;

  @override
  ConsumerState<SignSheet> createState() => _SignSheetState();
}

class _SignSheetState extends ConsumerState<SignSheet> {
  final _text = TextEditingController();
  final _namespace = TextEditingController();
  var _source = SignSource.file;
  var _purpose = SignPurpose.file;
  PickedFile? _file;
  var _tooLarge = false;
  var _signing = false;

  /// The armored signature, and the name of the file that was signed.
  ({String text, String? fileName})? _signed;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    _namespace.addListener(_changed);
  }

  @override
  void dispose() {
    _text.dispose();
    _namespace.dispose();
    super.dispose();
  }

  /// What is to be signed changed: a signature shown is no longer its.
  void _changed() => setState(() => _signed = null);

  String get _chosenNamespace => NamespaceChoice.namespaceOf(_purpose, _namespace.text);

  bool get _ready =>
      !_signing &&
      isSshsigNamespace(_chosenNamespace) &&
      (_source == SignSource.file ? _file != null && !_tooLarge : _text.text.isNotEmpty);

  Future<void> _pick() async {
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    setState(() {
      _signed = null;
      _tooLarge = picked.bytes.length > maxSignedFileBytes;
      _file = _tooLarge ? null : picked;
    });
  }

  Future<void> _sign(VaultKey key) async {
    final file = _file;
    final fromFile = _source == SignSource.file;
    // Text is signed as its UTF-8 bytes, exactly as typed
    final message = fromFile ? file!.bytes : Uint8List.fromList(utf8.encode(_text.text));
    final namespace = _chosenNamespace;
    setState(() => _signing = true);
    try {
      final signature = await ref.read(sshSignerProvider)(unb64(key.privateKey), namespace, message);
      if (mounted) setState(() => _signed = (text: signature, fileName: fromFile ? file!.name : null));
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  void _toast(String id, [Map<String, Object?> args = const {}]) => ref.read(toastsProvider.notifier).show(context.t(id, args));

  /// `<file>.sig`, as `ssh-keygen` names it, or `signature.sig` for text.
  String _sigName(String? fileName) => fileName == null || fileName.isEmpty ? 'signature.sig' : '$fileName.sig';

  /// A signature is not a secret: it goes on the plain clipboard.
  Future<void> _copy(String signature) async {
    await Clipboard.setData(ClipboardData(text: signature.trimRight()));
    if (mounted) _toast('keys.sign.copied');
  }

  Future<void> _share(({String text, String? fileName}) signed) => ref
      .read(fileServiceProvider)
      .shareFile(_sigName(signed.fileName), Uint8List.fromList(utf8.encode(signed.text)), mimeType: 'text/plain');

  Future<void> _save(({String text, String? fileName}) signed) async {
    final result = await ref
        .read(fileServiceProvider)
        .saveFile(_sigName(signed.fileName), Uint8List.fromList(utf8.encode(signed.text)), mimeType: 'application/octet-stream');
    if (result is Saved && mounted) _toast('notes.copy.saved', {'location': result.location});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final key = ref.watch(vaultControllerProvider.select((state) => state.keys.firstWhereOrNull((key) => key.id == widget.keyId)));
    if (key == null || key.kind != KeyKind.ssh) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('keys.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final signed = _signed;
    final file = _file;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.draw_outlined), title: context.t('keys.sign.title', {'name': key.name})),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedControl<SignSource>(
                  options: [
                    SegmentOption(value: SignSource.file, label: context.t('keys.sign.file')),
                    SegmentOption(value: SignSource.text, label: context.t('keys.sign.text')),
                  ],
                  value: _source,
                  onChanged: (source) => setState(() {
                    _source = source;
                    _signed = null;
                  }),
                  semanticLabel: context.t('keys.sign.action'),
                ),
                const SizedBox(height: 12),
                if (_source == SignSource.file) ...[
                  OutlinedButton.icon(
                    onPressed: _signing ? null : () => unawaited(_pick()),
                    icon: const Icon(Icons.folder_open_rounded),
                    label: Text(
                      file == null ? context.t('keys.sign.chooseFile') : '${file.name} · ${fileSizeText(context, file.bytes.length)}',
                    ),
                  ),
                  if (_tooLarge) ...[
                    const SizedBox(height: 12),
                    AppAlert(
                      key: const ValueKey('sign-too-large'),
                      severity: AlertSeverity.error,
                      child: Text(context.t('keys.sign.tooLarge', {'size': fileSizeText(context, maxSignedFileBytes)})),
                    ),
                  ],
                ] else
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _text,
                    minLines: 3,
                    maxLines: 8,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: context.t('keys.sign.text'),
                      helperText: context.t('keys.sign.textHint'),
                      helperMaxLines: 2,
                      alignLabelWithHint: true,
                    ),
                  ),
                const SizedBox(height: 16),
                NamespaceChoice(
                  purpose: _purpose,
                  onChanged: (purpose) => setState(() {
                    _purpose = purpose;
                    _signed = null;
                  }),
                  controller: _namespace,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('sign-submit'),
                  style: largeButtonStyle,
                  onPressed: _ready ? () => unawaited(_sign(key)) : null,
                  icon: const Icon(Icons.draw_outlined),
                  label: Text(context.t('keys.sign.submit')),
                ),
                if (_signing) ...[const SizedBox(height: 12), const Center(child: Spinner())],
                if (signed != null) ...[
                  const SizedBox(height: 16),
                  AppAlert(severity: AlertSeverity.success, child: Text(context.t('keys.sign.done'))),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: context.bmc.raised, borderRadius: BorderRadius.circular(12)),
                    child: SelectableText(
                      signed.text.trimRight(),
                      key: const ValueKey('signature'),
                      style: AppType.mono(fontSize: 11, color: p.text),
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => unawaited(_copy(signed.text)),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: Text(context.t('keys.public.copy')),
                      ),
                      TextButton.icon(
                        onPressed: () => unawaited(_share(signed)),
                        icon: const Icon(Icons.ios_share_rounded, size: 18),
                        label: Text(context.t('notes.copy.share')),
                      ),
                      TextButton.icon(
                        onPressed: () => unawaited(_save(signed)),
                        icon: const Icon(Icons.file_download_outlined, size: 18),
                        label: Text(context.t('notes.save')),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
