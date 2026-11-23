import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../platform/files.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../keys/import_key_sheet.dart';
import '../scan/qr_viewfinder.dart';
import 'contact_keys.dart';
import 'contact_review_sheet.dart';
import 'lookup/key_search_sheet.dart';

/// "Add someone's key": scan a QR code, choose a file, paste the key's text
/// or find it by email (openspec: add-key-lookup). With [replacingId], the
/// same ways in bring a newer copy of that contact's key, or another key to
/// put in its place, under [title].
Future<void> showAddContactSheet(BuildContext context, {String? replacingId, String? title}) => showAppBottomSheet<void>(
  context,
  label: title ?? context.t('contacts.add.title'),
  builder: (_) => AddContactSheet(replacingId: replacingId, title: title),
);

enum _Way { scan, paste }

/// The sheet [showAddContactSheet] opens. Whatever the way in, the key is
/// read and checked, then this sheet closes and the review opens: nothing
/// is stored here. What can't be taken says why, and a private key is
/// pointed to the sheet that imports the person's own keys.
class AddContactSheet extends ConsumerStatefulWidget {
  const AddContactSheet({super.key, this.replacingId, this.title});

  final String? replacingId;
  final String? title;

  @override
  ConsumerState<AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends ConsumerState<AddContactSheet> {
  final _paste = TextEditingController();
  _Way? _way;
  var _reading = false;
  ({String id, Map<String, Object?> args})? _error;
  var _privateKey = false;

  @override
  void initState() {
    super.initState();
    _paste.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _choose(_Way way) => setState(() {
    _way = _way == way ? null : way;
    _error = null;
    _privateKey = false;
  });

  Future<void> _pick() async {
    setState(() {
      _way = null;
      _error = null;
      _privateKey = false;
    });
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    await _read(picked.bytes, ContactSource.file);
  }

  /// Reads [input] and hands its keys to the review; says why when it holds none.
  Future<void> _read(Object input, String source) async {
    if (_reading) return;
    final scanned = source == ContactSource.qr;
    if (scanned && fingerprintOfCode(input as String) != null) {
      setState(() => _error = (id: 'contacts.add.fingerprintOnly', args: const {}));
      return;
    }
    setState(() {
      _reading = true;
      _error = null;
      _privateKey = false;
    });
    try {
      final keys = await ref.read(publicKeyReaderProvider)(input);
      if (!mounted) return;
      final root = Navigator.of(context, rootNavigator: true).context;
      Navigator.of(context).pop();
      if (root.mounted) unawaited(showContactReviewSheet(root, keys, source, replacingId: widget.replacingId));
    } on crypto.KeyFormatException catch (error) {
      if (!mounted) return;
      setState(() {
        // A code that is a web address or a set-up link is simply not a key
        _error = scanned && error.problem == crypto.KeyProblem.unrecognized
            ? (id: 'contacts.add.notAKey', args: const {})
            : contactProblem(error);
        _privateKey = error.problem == crypto.KeyProblem.privateKeyGiven;
      });
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _importOwn() {
    final root = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    unawaited(showImportKeySheet(root));
  }

  void _findByEmail() {
    final root = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    unawaited(showKeySearchSheet(root, replacingId: widget.replacingId));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final error = _error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.person_add_alt_1_outlined), title: widget.title ?? context.t('contacts.add.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
                  child: Text(context.t('contacts.add.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      accent: _way == _Way.scan,
                      primary: context.t('contacts.add.scan'),
                      secondary: context.t('contacts.add.scan.body'),
                      onTap: () => _choose(_Way.scan),
                    ),
                    GroupRow(
                      icon: const Icon(Icons.folder_open_rounded),
                      primary: context.t('contacts.add.file'),
                      secondary: context.t('contacts.add.file.body'),
                      onTap: _reading ? null : () => unawaited(_pick()),
                    ),
                    GroupRow(
                      icon: const Icon(Icons.content_paste_rounded),
                      accent: _way == _Way.paste,
                      primary: context.t('contacts.add.paste'),
                      secondary: context.t('contacts.add.paste.body'),
                      onTap: () => _choose(_Way.paste),
                    ),
                    GroupRow(
                      key: const ValueKey('add-contact-lookup'),
                      icon: const Icon(Icons.alternate_email_rounded),
                      primary: context.t('contacts.add.lookup'),
                      secondary: context.t(ref.watch(offlineProvider) ? 'contacts.add.lookup.paused' : 'contacts.add.lookup.body'),
                      onTap: _reading ? null : _findByEmail,
                    ),
                  ],
                ),
                if (_way == _Way.scan) ...[
                  const SizedBox(height: 14),
                  QrViewfinder(onScan: (code) => unawaited(_read(code, ContactSource.qr))),
                ],
                if (_way == _Way.paste) ...[
                  const SizedBox(height: 14),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _paste,
                    minLines: 3,
                    maxLines: 8,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: AppType.mono(fontSize: 12, color: p.text),
                    decoration: InputDecoration(
                      labelText: context.t('contacts.add.pasteField'),
                      hintText: '-----BEGIN PGP PUBLIC KEY BLOCK-----',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: _reading || _paste.text.trim().isEmpty ? null : () => unawaited(_read(_paste.text, ContactSource.paste)),
                      child: Text(context.t('contacts.add.read')),
                    ),
                  ),
                ],
                if (_reading) ...[const SizedBox(height: 12), const Center(child: Spinner())],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  AppAlert(
                    key: const ValueKey('add-contact-error'),
                    severity: AlertSeverity.error,
                    child: Text(context.t(error.id, error.args)),
                  ),
                ],
                if (_privateKey) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _importOwn,
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(context.t('contacts.add.importOwn')),
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
