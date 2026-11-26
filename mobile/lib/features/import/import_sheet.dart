import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../core/public_suffixes.dart';
import '../../crypto/aes_gcm.dart';
import '../../crypto/attachment_format.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../models/otp_account.dart';
import '../../models/secure_note.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/attachment_store.dart';
import '../../vault/export_archive.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_export.dart';
import '../contacts/contact_keys.dart';
import '../contacts/contact_standing.dart';
import '../duplicates/duplicate_sites.dart';
import '../export/export_key.dart';
import '../export/transfer_widgets.dart';
import '../recovery/piece_collector.dart';
import 'credential_exchange.dart';
import 'formats/cxf.dart';
import 'formats/import_extras.dart';
import 'import_merge.dart';
import 'import_widgets.dart';
import 'importers.dart';

/// Imports a backup file or another app's export, `ImportDialog.tsx`. With a [transfer] it opens on
/// what another app on this phone hands over (iOS: the export that launched Kemlock) in place of a file.
Future<void> showImportSheet(BuildContext context, {ImportTransfer? transfer}) => showAppBottomSheet<void>(
  context,
  label: context.t('import.title'),
  builder: (_) => ImportSheet(transfer: transfer),
);

/// What a chosen file turned out to be: a Kemlock export when [source]
/// is null, or another app's.
class _Detected {
  const _Detected(this.source, {required this.encrypted, this.name});

  final ImportSource? source;
  final bool encrypted;

  /// The exporter a Credential Exchange file names in its header.
  final String? name;

  bool get foreign => source != null;
}

const _appNames = {
  ImportSource.google: 'Google Authenticator',
  ImportSource.aegis: 'Aegis',
  ImportSource.twoFas: '2FAS',
  ImportSource.bitwarden: 'Bitwarden',
};

/// What each importer error says. A missing password reads as a wrong one, as in the dialog.
const _errorIds = {
  ImportErrorCode.unsupported: 'import.error.unsupported',
  ImportErrorCode.empty: 'import.error.empty',
  ImportErrorCode.passwordRequired: 'import.error.badPassword',
  ImportErrorCode.badPassword: 'import.error.badPassword',
  ImportErrorCode.bitwardenEncrypted: 'import.error.bitwardenEncrypted',
};

_Detected? _detect(String text) {
  try {
    return _Detected(null, encrypted: isEncryptedExport(text));
  } catch (_) {
    // Not one of ours; maybe another app's
  }
  final found = detectFormat(text);
  if (found == null) {
    return null;
  }
  return _Detected(found.source, encrypted: found.encrypted, name: found.source == ImportSource.cxf ? _exporterOf(text) : null);
}

/// The exporter named in the header of a Credential Exchange file.
String? _exporterOf(String text) {
  try {
    return switch (jsonDecode(text)) {
      final Map<String, Object?> json => cxfExporterName(json),
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// What a Credential Exchange file that can't be read says.
String _cxfError(BuildContext context, CxfException error) => switch (error.problem) {
  CxfProblem.tooLarge => context.t('import.error.cxf.tooLarge'),
  CxfProblem.unsupportedVersion => context.t('import.error.cxf.version', {'version': error.version ?? ''}),
  CxfProblem.malformed => context.t('import.error.cxf.malformed', {'position': error.position ?? ''}),
  _ => context.t('import.error.unsupported'),
};

/// The import sheet, in three steps: choose a file, open it (with its
/// password, or a Kemlock export with its vault's Recovery Kit), then
/// review what it holds, with the accounts the vault has already marked,
/// and merge it in or replace the vault's accounts with it. Other people's
/// keys it brings are listed by name and fingerprint and come in not
/// checked, unless the person keeps the checks the file says were made.
///
/// It reads Kemlock exports, encrypted or plain, and what the importers
/// read: Aegis, 2FAS and Bitwarden backups and lists of otpauth:// links.
class ImportSheet extends ConsumerStatefulWidget {
  const ImportSheet({super.key, this.transfer});

  /// What to read in place of a file, as soon as the sheet is open; none to start from a file.
  final ImportTransfer? transfer;

  @override
  ConsumerState<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<ImportSheet> {
  final _password = TextEditingController();
  final _reviewKey = GlobalKey();
  String? _content;

  /// The archive the export came in, with the notes' files, when it came in one.
  ExportArchive? _archive;
  String? _fileName;
  _Detected? _detected;
  bool _loading = false;
  String? _error;
  ImportPreview? _preview;
  ImportMode _mode = ImportMode.merge;

  /// The kit an encrypted Kemlock export also opens with, if it has one.
  ({String kitId, int threshold})? _kit;

  /// Opening the export with its vault's Recovery Kit instead of the password.
  bool _withKit = false;

  /// The content came from another app on this phone, not from a file.
  bool _transferred = false;

  /// Bumped when the kit's pieces didn't open the file, so the collector starts over.
  int _kitAttempt = 0;

  /// The contacts come in marked checked where the file says they were.
  /// Off unless the person turns it on: a file can say a key was compared
  /// with its owner when it never was.
  bool _keepChecks = false;

  @override
  void initState() {
    super.initState();
    final transfer = widget.transfer;
    if (transfer != null) {
      // After the frame, and only now that a vault is open: nothing of the export is read before
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_receive(transfer));
        }
      });
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  String _appName(BuildContext context, ImportSource? source) => switch (source) {
    null => 'Kemlock',
    ImportSource.uris => context.t('import.source.uris'),
    ImportSource.cxf => context.t('import.source.cxf'),
    final source => _appNames[source]!,
  };

  /// What the tag beside the file's name says it is.
  String _detectedLabel(BuildContext context, _Detected detected) {
    if (detected.source == ImportSource.cxf) {
      final name = detected.name;
      if (_transferred) {
        return name == null ? context.t('import.detected.transferAnonymous') : context.t('import.detected.transfer', {'app': name});
      }
      return name == null ? context.t('import.detected.cxfAnonymous') : context.t('import.detected.cxf', {'app': name});
    }
    return context.t(detected.encrypted ? 'import.detected.encrypted' : 'import.detected', {'app': _appName(context, detected.source)});
  }

  void _clearFile() {
    _password.clear();
    setState(() {
      _content = null;
      _archive = null;
      _fileName = null;
      _detected = null;
      _error = null;
      _preview = null;
      _kit = null;
      _withKit = false;
      _keepChecks = false;
      _transferred = false;
    });
  }

  Future<void> _browse() async {
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    ExportArchive? archive;
    if (isExportArchive(picked.bytes)) {
      try {
        archive = readExportArchive(picked.bytes);
      } on ExportArchiveError catch (error) {
        _clearFile();
        setState(() {
          _fileName = picked.name;
          _error = context.t('import.error.archive.${error.problem.name}', {'entry': error.entry ?? ''});
        });
        return;
      }
    }
    var content = archive?.exportJson ?? utf8.decode(picked.bytes, allowMalformed: true);
    // FileReader.readAsText dropped a byte order mark; so does this.
    if (content.startsWith('\u{FEFF}')) content = content.substring(1);
    final detected = _detect(content);
    // An archive holds a Kemlock export or nothing this sheet reads
    final found = archive != null && (detected?.foreign ?? false) ? null : detected;
    _clearFile();
    setState(() {
      _fileName = picked.name;
      _content = content;
      _archive = archive;
      _detected = found;
      _kit = found != null && !found.foreign && found.encrypted ? exportRecoveryKit(content) : null;
      if (found == null) _error = context.t('import.error.unsupported');
    });
  }

  /// Asks another app on this phone for its export, and opens what it sends as a Credential Exchange
  /// file: the same preview, the same duplicate step. Closing Android's list is no error and changes
  /// nothing. What the exporter sent is held only in this sheet, which drops it with the sheet.
  Future<void> _receive(ImportTransfer transfer) async {
    if (_loading) {
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    final String? json;
    try {
      json = await fetchTransfer(ref, transfer);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = transferError(context, error);
          _loading = false;
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    if (json == null) {
      setState(() => _loading = false);
      return;
    }
    final detected = _detect(json);
    _clearFile();
    final cxf = detected?.source == ImportSource.cxf;
    setState(() {
      _loading = false;
      _transferred = true;
      _content = cxf ? json : null;
      _detected = cxf ? detected : null;
      if (!cxf) {
        _error = context.t('import.error.unsupported');
      }
    });
    if (cxf) {
      unawaited(_open());
    }
  }

  Future<ImportPreview> _readKemlock(String content, bool encrypted) async {
    final result = encrypted
        ? await importVault(content, _password.text, deriveKey: ref.read(exportDeriveKeyProvider))
        : importVaultPlaintext(content);
    return ImportPreview.of(result);
  }

  Future<ImportPreview> _readForeign(String content) async {
    final password = _password.text;
    final now = ref.read(clockProvider)().millisecondsSinceEpoch;
    final result = await parseForeignExport(content, password: password.isEmpty ? null : password);
    // A Credential Exchange payload comes with its entries' ids, times and remarks
    if (result.source == ImportSource.cxf) {
      return ImportPreview.ofForeign(result);
    }
    return ImportPreview(
      accounts: [for (final a in result.accounts) a.copyWith(id: newUuid(), addedAt: now)],
      backupServices: const [],
      skipped: result.skipped,
      passkeys: [
        for (final passkey in result.passkeys) passkey.copyWith(id: newUuid(), addedAt: passkey.addedAt == 0 ? now : passkey.addedAt),
      ],
    );
  }

  Future<void> _open() async {
    final content = _content;
    final detected = _detected;
    if (content == null || detected == null || _loading || (detected.encrypted && _password.text.isEmpty)) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final preview = detected.foreign ? await _readForeign(content) : await _readKemlock(content, detected.encrypted);
      if (!mounted) return;
      setState(() => _preview = preview);
      revealAfterFrame(_reviewKey);
    } on CxfException catch (error) {
      if (mounted) {
        setState(() => _error = _cxfError(context, error));
      }
    } on ImportError catch (error) {
      if (mounted) setState(() => _error = context.t(_errorIds[error.code]!));
    } on AesGcmAuthError {
      if (mounted) setState(() => _error = context.t('import.error.badPassword'));
    } catch (error) {
      if (!mounted) return;
      final message = '$error';
      setState(() => _error = message.toLowerCase().contains('decrypt') ? context.t('import.error.badPassword') : message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openWithKit(String kitId, Uint8List key) async {
    final content = _content;
    if (content == null) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final result = await importVaultWithRecoveryKey(content, key);
      if (!mounted) return;
      setState(() {
        _preview = ImportPreview.of(result);
        _withKit = false;
      });
      revealAfterFrame(_reviewKey);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = context.t('import.kit.wrong');
          _kitAttempt++;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    final preview = _preview;
    if (preview == null) return;
    final vault = ref.read(vaultControllerProvider);
    final merged = mergeImport(
      preview,
      accounts: vault.accounts,
      services: vault.backupServices,
      mode: _mode,
      // Other apps' backups hold no backup codes, so replacing must not wipe ours
      keepServices: _detected?.foreign ?? false,
    );
    final passkeys = newPasskeys(preview, vault.passkeys);
    final keys = [...newKeys(preview, vault.keys), ...keysToCombine(preview, vault.keys)];
    final notes = newNotes(preview, vault.notes);
    final keyAccounts = newKeyAccounts(preview, vault.keyAccounts);
    final sites = siteResolver(suffixes: ref.read(publicSuffixListProvider).value);
    final logins = newLogins(preview, vault.logins, accounts: vault.accounts, mode: _mode, sites: sites);
    // A card from another app matches on its number and expiry too, as the cleaner shows them
    final cards = _detected?.source == ImportSource.cxf ? planCards(preview, vault.cards).adds : newCards(preview, vault.cards);
    final identities = newIdentities(preview, vault.identities);
    final files = newFiles(preview, vault.files);
    final controller = ref.read(vaultControllerProvider.notifier);
    final attachments = ref.read(attachmentStoreProvider);
    final reader = ref.read(publicKeyReaderProvider);
    final archive = _archive;
    final plain = !(_detected?.encrypted ?? true);
    final keepChecks = _keepChecks;
    Navigator.of(context).pop();
    // The new notes' files first, so a note never names a file the store could have had
    if (archive != null) {
      final attached = [for (final note in notes) ...note.files, for (final item in files) item.file];
      await _storeFiles(attachments, vault.vault.id, attached, archive, plain: plain);
    }
    // A file is outside input: each key it brings is read and checked again before it is kept,
    // and comes in not checked unless the person kept the checks the file records
    final contacts = [
      for (final contact in await soundContacts(newContacts(preview, vault.contacts), reader)) keepChecks ? contact : contact.unchecked(),
    ];
    await controller.imported(
      merged.accounts,
      merged.backupServices,
      passkeys: passkeys,
      keys: keys,
      notes: notes,
      keyAccounts: keyAccounts,
      contacts: contacts,
      logins: logins,
      cards: cards,
      identities: identities,
      files: files,
    );
  }

  /// Stores each file of [attached], the files of notes and File items, that the archive holds and its key opens: as it
  /// is from an encrypted export, encrypted under its key from a plain one.
  /// A file that is missing or doesn't open is left out, and its note
  /// shows it as missing.
  static Future<void> _storeFiles(
    AttachmentStore store,
    String vaultId,
    List<NoteAttachment> attached,
    ExportArchive archive, {
    required bool plain,
  }) async {
    for (final file in attached) {
      final read = archive.files[file.id];
      if (read == null || await store.exists(vaultId, file.id)) continue;
      try {
        final bytes = read();
        final key = unb64(file.key);
        if (plain) {
          await store.write(vaultId, file.id, bytes, key);
        } else {
          await kma1Decrypt(bytes, key);
          await store.writeSealed(vaultId, file.id, bytes);
        }
      } catch (_) {
        // Damaged, or no room: the note or File item comes in without it
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final vault = ref.watch(vaultControllerProvider);
    final sites = siteResolver(suffixes: ref.watch(publicSuffixListProvider).value);
    final detected = _detected;
    final preview = _preview;
    final appName = detected == null ? '' : _appName(context, detected.source);
    final cxf = detected?.source == ImportSource.cxf;
    final counts = preview == null ? null : countImport(preview, accounts: vault.accounts, services: vault.backupServices, mode: _mode);
    final addedPasskeys = preview == null ? 0 : newPasskeys(preview, vault.passkeys).length;
    // The contacts the file brings, each with what its key holds, and whether it says any was checked
    final bringing = [
      if (preview != null)
        for (final contact in newContacts(preview, vault.contacts)) (contact: contact, info: contactKeyInfo(contact)),
    ];
    final addedContacts = bringing.length;
    final checksInFile = bringing.any((c) => _recordsCheck(c.contact, c.info));
    final addedItems = preview == null
        ? 0
        : newKeys(preview, vault.keys).length + newNotes(preview, vault.notes).length + newPasskeys(preview, vault.passkeys).length;
    // What a file of contacts, on-key accounts or logins alone adds, which is reason enough to import it.
    final addedAll =
        addedItems +
        addedContacts +
        (preview == null
            ? 0
            : newKeyAccounts(preview, vault.keyAccounts).length +
                  newLogins(preview, vault.logins, accounts: vault.accounts, mode: _mode, sites: sites).length +
                  newCards(preview, vault.cards).length +
                  newIdentities(preview, vault.identities).length +
                  newFiles(preview, vault.files).length);
    final missingFiles = preview == null
        ? const <String>[]
        : [
            for (final note in preview.notes)
              for (final file in note.files)
                if (!(_archive?.files.containsKey(file.id) ?? false)) '${note.title} › ${file.name}',
            for (final item in newFiles(preview, vault.files))
              if (!(_archive?.files.containsKey(item.file.id) ?? false)) item.name,
          ];
    final merge = _mode == ImportMode.merge;
    final codes = preview != null && preview.accounts.length + preview.backupServices.length > 0;
    final canImport =
        preview != null &&
        counts != null &&
        // Replacing with nothing would wipe the vault's codes; a file of passkeys alone can only add
        (codes ? !(merge && counts.newAccounts == 0 && counts.newServices == 0 && addedAll == 0) : addedAll > 0 && merge);

    return TransferSheet(
      icon: Icons.file_upload_outlined,
      title: context.t('import.title'),
      actions: [
        SheetCloseButton(label: context.t('import.cancel')),
        FilledButton.icon(
          style: merge ? null : filledButtonColors(background: p.warning, foreground: p.onWarning),
          onPressed: canImport ? _import : null,
          icon: const Icon(Icons.file_upload_outlined, size: 20),
          label: Text(
            !merge
                ? context.t('import.button.replace')
                : (counts?.newAccounts ?? 0) == 0 && addedAll > 0 && addedAll == addedPasskeys
                ? context.t('import.button.passkeys', {'count': addedPasskeys})
                : (counts?.newAccounts ?? 0) == 0 && addedAll > 0
                ? context.t('import.button.items')
                : context.t('import.button.merge', {'count': counts?.newAccounts ?? 0}),
          ),
        ),
      ],
      children: [
        Text(context.t('import.body'), style: AppType.body1.copyWith(color: p.textSecondary)),
        const SizedBox(height: 8),
        Text(context.t('import.googleHint'), style: AppType.caption.copyWith(color: p.textSecondary)),
        const SizedBox(height: 16),
        if (_error != null) ...[AppAlert(severity: AlertSeverity.error, child: Text(_error!)), const SizedBox(height: 16)],

        // Another app on this phone: a button, the steps to start it there, or why there is none
        ExchangeRows(onStart: () => unawaited(_receive(const PhoneTransfer())), busy: _loading),

        // Step 1 – File
        StepOverline(context.t('import.step1')),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              style: smallButtonStyle,
              onPressed: _loading ? null : _browse,
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              label: Text(context.t('import.browse')),
            ),
            if (_fileName != null) TransferTag(_fileName!, onDelete: _loading ? null : _clearFile),
            if (detected != null) TransferTag(_detectedLabel(context, detected), tone: TagTone.accent),
          ],
        ),
        const SizedBox(height: 16),
        Divider(height: 1, color: p.divider),
        const SizedBox(height: 16),

        // Step 2 – Password or plain read
        StepOverline(context.t('import.step2')),
        if (detected != null && !detected.encrypted) ...[
          const SizedBox(height: 8),
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('import.plaintext.detected'))),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: _loading || _content == null ? null : _open,
              icon: const Icon(Icons.key_rounded, size: 20),
              label: Text(context.t('import.read')),
            ),
          ),
        ],
        if (detected != null && detected.encrypted) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: PasswordField(
                  controller: _password,
                  label: detected.foreign ? context.t('import.field.appPassword', {'app': appName}) : context.t('import.field.password'),
                  dense: true,
                  enabled: !_loading && _content != null,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => unawaited(_open()),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _loading || _content == null || _password.text.isEmpty ? null : _open,
                icon: const Icon(Icons.key_rounded, size: 20),
                label: Text(context.t('import.decrypt')),
              ),
            ],
          ),
        ],
        if (_kit != null && preview == null && !_withKit) ...[
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              style: smallButtonStyle,
              onPressed: () => setState(() => _withKit = true),
              child: Text(context.t('import.kit.use')),
            ),
          ),
        ],
        if (_kit != null && preview == null && _withKit) ...[
          const SizedBox(height: 12),
          PieceCollector(key: ValueKey(_kitAttempt), onKey: (kitId, key) => unawaited(_openWithKit(kitId, key)), busy: _loading),
        ],
        if (_content == null) ...[
          const SizedBox(height: 4),
          Text(context.t('import.step2.hint'), style: AppType.caption.copyWith(color: p.textDisabled)),
        ],
        if (_loading) ...[
          const SizedBox(height: 10),
          WorkingNote(
            caption: detected != null && detected.encrypted
                ? context.t(detected.foreign ? 'import.loading.foreign' : 'import.loading')
                : null,
          ),
        ],

        // Step 3 – Preview & mode
        if (preview != null && counts != null) ...[
          const SizedBox(height: 16),
          Divider(height: 1, color: p.divider),
          const SizedBox(height: 16),
          StepOverline(context.t('import.step3')),
          if (preview.skipped > 0 && !cxf) ...[
            const SizedBox(height: 8),
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('import.skipped', {'count': preview.skipped}))),
          ],
          if (preview.accounts.isNotEmpty) ...[
            const SizedBox(height: 8),
            _PreviewList(accounts: preview.accounts, current: vault.accounts, markDuplicates: merge),
          ],
          // Another app's entries are only ever added: replacing the vault's codes with them would wipe the rest
          if (cxf) ...[
            _CxfSummary(preview),
          ] else ...[
            const SizedBox(height: 12),
            ImportModeControl(value: _mode, onChanged: (mode) => setState(() => _mode = mode)),
            const SizedBox(height: 8),
            AppAlert(
              severity: merge ? AlertSeverity.info : AlertSeverity.warning,
              child: Text(
                merge
                    ? context.t('import.info.merge', {'newCount': counts.newAccounts, 'dupCount': counts.duplicates})
                    : context.t('import.info.replace', {'existingCount': vault.accounts.length, 'importCount': preview.accounts.length}),
              ),
            ),
          ],
          if (preview.keys.isNotEmpty || preview.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (preview.keys.isNotEmpty) TransferTag(context.t('export.chip.keys', {'count': preview.keys.length})),
                if (preview.notes.isNotEmpty) TransferTag(context.t('export.chip.notes', {'count': preview.notes.length})),
                if (preview.notes.any((note) => note.files.isNotEmpty))
                  TransferTag(
                    context.t('export.chip.files', {'count': preview.notes.fold<int>(0, (count, note) => count + note.files.length)}),
                  ),
                if (preview.passkeys.isNotEmpty) TransferTag(context.t('export.chip.passkeys', {'count': preview.passkeys.length})),
              ],
            ),
            const SizedBox(height: 8),
            AppAlert(
              severity: AlertSeverity.info,
              child: Text(context.t('import.info.items', {'newCount': addedItems, 'dupCount': preview.items - addedItems})),
            ),
            if (missingFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              AppAlert(
                severity: AlertSeverity.warning,
                child: Text(context.t('import.missingFiles', {'count': missingFiles.length, 'files': missingFiles.join(', ')})),
              ),
            ],
          ] else if (preview.passkeys.isNotEmpty) ...[
            const SizedBox(height: 8),
            AppAlert(
              severity: AlertSeverity.info,
              child: Text(
                context.t('import.info.passkeys', {'newCount': addedPasskeys, 'dupCount': preview.passkeys.length - addedPasskeys}),
              ),
            ),
          ],
          if (preview.contacts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TransferTag(context.t('export.chip.contacts', {'count': preview.contacts.length})),
              ],
            ),
            const SizedBox(height: 8),
            AppAlert(
              key: const ValueKey('import-contacts'),
              severity: AlertSeverity.info,
              child: Text(
                context.t('import.info.contacts', {'newCount': addedContacts, 'dupCount': preview.contacts.length - addedContacts}),
              ),
            ),
            if (bringing.isNotEmpty) ...[const SizedBox(height: 8), _ContactPreviewList(contacts: bringing)],
            // Asked only of a file that says some key was checked; each comes in not checked otherwise
            if (checksInFile) ...[
              const SizedBox(height: 8),
              Group(
                children: [
                  GroupRow(
                    first: true,
                    icon: const Icon(Icons.verified_user_outlined),
                    primary: context.t('import.contacts.keepChecks'),
                    secondary: context.t('import.contacts.keepChecks.detail'),
                    control: Semantics(
                      label: context.t('import.contacts.keepChecks'),
                      child: AppSwitch(value: _keepChecks, onChanged: (on) => setState(() => _keepChecks = on)),
                    ),
                  ),
                ],
              ),
            ],
          ],
          if (preview.keyAccounts.isNotEmpty) ...[
            const SizedBox(height: 8),
            AppAlert(severity: AlertSeverity.info, child: Text(context.t('export.onKey', {'count': preview.keyAccounts.length}))),
          ],
          if (preview.backupServices.isNotEmpty) ...[
            const SizedBox(height: 8),
            AppAlert(
              severity: AlertSeverity.info,
              // In English only, as the dialog had it.
              child: Text(
                merge
                    ? 'Also importing ${counts.newServices} backup service${counts.newServices != 1 ? 's' : ''}.'
                    : 'Also replacing backup services with ${preview.backupServices.length} from file.',
              ),
            ),
          ],
          // The end of the review, which the sheet scrolls to once the file is open.
          SizedBox(key: _reviewKey, height: 1),
        ],
      ],
    );
  }
}

/// Whether the file marks [contact] checked for the key it holds, which
/// [info] describes: a mark for another key is no check.
bool _recordsCheck(Contact contact, crypto.PgpKeyInfo? info) =>
    info != null && contact.checkedFingerprint?.toUpperCase() == info.primary.fingerprintHex;

/// The contacts an import brings, each by its name and the end of its
/// fingerprint, the ones the file says were checked tagged so.
class _ContactPreviewList extends StatelessWidget {
  const _ContactPreviewList({required this.contacts});

  final List<({Contact contact, crypto.PgpKeyInfo? info})> contacts;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('import-contact-list'),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(appRadius),
        border: Border.all(color: p.divider),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(appRadius),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: contacts.length,
          itemBuilder: (context, i) {
            final (:contact, :info) = contacts[i];
            // The last four groups, a long key ID's sixteen digits
            final groups = info == null ? const <String>[] : crypto.fingerprintGroups(info.primary.fingerprintHex);
            final fingerprint = groups.skip(groups.length > 4 ? groups.length - 4 : 0).join(' ');
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.person_outline_rounded, size: 18, color: p.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          contact.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.body2.copyWith(color: p.text),
                        ),
                        // Left to right in every language, as a fingerprint is read
                        Text(
                          fingerprint,
                          maxLines: 1,
                          textDirection: TextDirection.ltr,
                          style: AppType.mono(fontSize: 12, color: p.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  if (_recordsCheck(contact, info)) ...[const SizedBox(width: 8), TransferTag(context.t('import.chip.checked'))],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The accounts an import holds, each with its issuer and label, the ones
/// the vault has already faded and marked as duplicates when [markDuplicates].
class _PreviewList extends StatelessWidget {
  const _PreviewList({required this.accounts, required this.current, required this.markDuplicates});

  final List<OtpAccount> accounts;
  final List<OtpAccount> current;
  final bool markDuplicates;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(appRadius),
        border: Border.all(color: p.divider),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(appRadius),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: accounts.length,
          itemBuilder: (context, i) {
            final account = accounts[i];
            final duplicate = markDuplicates && isDuplicateAccount(account, current);
            return Opacity(
              opacity: duplicate ? 0.45 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.key_rounded, size: 18, color: duplicate ? p.disabled : p.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.issuer.isNotEmpty ? account.issuer : account.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.body2.copyWith(color: p.text),
                          ),
                          Text(
                            account.issuer.isNotEmpty ? account.label : account.algorithm,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.caption.copyWith(color: p.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    if (duplicate) ...[const SizedBox(width: 8), TransferTag(context.t('import.chip.duplicate'))],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// What each skipped credential's reason says.
const _skipIds = {
  SkipReason.file: 'import.cxf.skip.file',
  SkipReason.wifi: 'import.cxf.skip.wifi',
  SkipReason.apiKey: 'import.cxf.skip.apiKey',
  SkipReason.generatedPassword: 'import.cxf.skip.generatedPassword',
  SkipReason.itemReference: 'import.cxf.skip.itemReference',
  SkipReason.unknownType: 'import.cxf.skip.unknownType',
  SkipReason.unreadable: 'import.cxf.skip.unreadable',
  SkipReason.totpAlgorithm: 'import.cxf.skip.totpAlgorithm',
  SkipReason.totpDigits: 'import.cxf.skip.totpDigits',
  SkipReason.totpSecret: 'import.cxf.skip.totpSecret',
  SkipReason.passkeyAlgorithm: 'import.cxf.skip.passkeyAlgorithm',
  SkipReason.passkeyKey: 'import.cxf.skip.passkeyKey',
  SkipReason.sshKey: 'import.cxf.skip.sshKey',
  SkipReason.nothingKept: 'import.cxf.skip.nothingKept',
};

/// The most skipped entries the preview lists by name; the rest are counted.
const _skipsListed = 50;

/// What a Credential Exchange import brings and what it leaves out: the
/// kinds it adds, the passkeys kept without their extra secrets, each
/// credential skipped with its reason, and what a limit cut.
class _CxfSummary extends StatelessWidget {
  const _CxfSummary(this.preview);

  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final cuts = preview.cuts;
    final skips = preview.skips;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (preview.logins.isNotEmpty) TransferTag(context.t('export.chip.logins', {'count': preview.logins.length})),
            if (preview.accounts.isNotEmpty) TransferTag(context.t('export.chip.accounts', {'count': preview.accounts.length})),
            if (preview.cards.isNotEmpty) TransferTag(context.t('export.chip.cards', {'count': preview.cards.length})),
            if (preview.identities.isNotEmpty) TransferTag(context.t('export.chip.identities', {'count': preview.identities.length})),
          ],
        ),
        for (final notice in preview.notices) ...[
          const SizedBox(height: 8),
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('import.cxf.notice.passkeyExtras', {'title': notice.title}))),
        ],
        if (skips.isNotEmpty) ...[
          const SizedBox(height: 8),
          AppAlert(
            severity: AlertSeverity.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.t('import.cxf.skipped', {'count': skips.length})),
                for (final skip in skips.take(_skipsListed))
                  Text('${skip.title.isEmpty ? '—' : skip.title}: ${context.t(_skipIds[skip.reason]!)}'),
                if (skips.length > _skipsListed) Text(context.t('import.cxf.skippedMore', {'count': skips.length - _skipsListed})),
              ],
            ),
          ),
        ],
        if (cuts != null && cuts.itemsLeftOut > 0) ...[
          const SizedBox(height: 8),
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('import.cxf.cut.items', {'count': cuts.itemsLeftOut}))),
        ],
        if (cuts != null && cuts.credentialsLeftOut > 0) ...[
          const SizedBox(height: 8),
          AppAlert(
            severity: AlertSeverity.warning,
            child: Text(context.t('import.cxf.cut.credentials', {'count': cuts.credentialsLeftOut})),
          ),
        ],
        if (cuts != null && cuts.urlsLeftOut > 0) ...[
          const SizedBox(height: 8),
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('import.cxf.cut.urls', {'count': cuts.urlsLeftOut}))),
        ],
        if (cuts != null && cuts.collectionsTooDeep > 0) ...[
          const SizedBox(height: 8),
          AppAlert(
            severity: AlertSeverity.warning,
            child: Text(context.t('import.cxf.cut.collections', {'count': cuts.collectionsTooDeep})),
          ),
        ],
        if (cuts != null && cuts.valuesTooLong > 0) ...[
          const SizedBox(height: 8),
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('import.cxf.cut.values', {'count': cuts.valuesTooLong}))),
        ],
      ],
    );
  }
}
