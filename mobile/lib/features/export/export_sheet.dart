import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/providers.dart';
import '../../core/time.dart';
import '../../crypto/attachment_format.dart';
import '../../crypto/bytes.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/attachment_store.dart';
import '../../vault/export_archive.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_export.dart';
import '../../vault/vault_providers.dart';
import '../settings/prefs.dart';
import '../spaces/hidden_passwords.dart';
import '../spaces/remembered_export_policies.dart';
import '../vault/owner_check.dart';
import 'credential_export_sheet.dart';
import 'export_key.dart';
import 'space_export.dart';
import 'transfer_widgets.dart';

/// Saves an encrypted or plain backup file of the open vault, `ExportDialog.tsx`.
Future<void> showExportSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('export.title'), builder: (_) => const ExportSheet());

/// `kemlock-export-2026-10-16T09-00-00.json`: the time the export was made,
/// in UTC; `.zip` for an archive with attached files.
String exportFileName(DateTime now, {bool archive = false}) =>
    'kemlock-export-${isoString(now).replaceAll(RegExp('[:.]'), '-').substring(0, 19)}.${archive ? 'zip' : 'json'}';

/// Where an export archive is built before it is saved, and deleted from
/// once it is saved, or with an encrypted one once the export sheet closes;
/// what a killed app leaves there is swept at the next start
/// (`platform/scratch.dart`). Tests give it a folder of their own.
final exportScratchProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}export').create(recursive: true),
);

/// What an export was made of, for the check that the file opens.
typedef ExportedCounts = ({int accounts, int services, int keys, int notes, int passkeys, int files, int contacts});

/// The export sheet: encrypted by default, under an export password typed
/// twice (and, when the vault has a Recovery Kit, also openable with the
/// kit), or plain JSON. It holds the codes, keys, notes and passkeys; a
/// vault with attached files exports as a `.zip` of the export and the
/// files. Before it is made the person shows it is them ([checkOwner]).
/// The file goes through the system's save dialog or share sheet;
/// an encrypted one counts as the vault's latest backup, and the sheet then
/// offers to prove it opens with the password retyped, files and all.
class ExportSheet extends ConsumerStatefulWidget {
  const ExportSheet({super.key});

  @override
  ConsumerState<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<ExportSheet> {
  ExportMode _mode = ExportMode.encrypted;
  String _password = '';
  String _confirm = '';
  bool _loading = false;
  String? _error;
  bool _done = false;
  String? _savedPath;

  /// Whether the encrypted backup just saved left out items of server spaces whose policy isn't known: a partial backup,
  /// which Vault health doesn't count.
  bool _partial = false;

  /// The encrypted file just saved, with what it holds, so the person can
  /// prove they can open it; [archive] is the archive's path when there was one.
  ({String json, String? archive, ExportedCounts counts})? _exported;

  /// The archive built for this export, in the cache. A plain one is deleted
  /// as soon as it is saved, and any when the save is cancelled or fails; an
  /// encrypted one that was saved stays for the check that it opens, until
  /// the sheet goes.
  File? _scratch;

  @override
  void dispose() {
    _dropScratch();
    super.dispose();
  }

  /// Deletes the archive built for the last export, if one is left. It goes
  /// at once, before anything else is awaited: a plain archive holds every
  /// secret in the clear, and a delete left to the file system's thread
  /// could still be waiting when the export is reported as saved.
  void _dropScratch() {
    final scratch = _scratch;
    _scratch = null;
    if (scratch == null) return;
    try {
      scratch.deleteSync();
    } on FileSystemException {
      // Gone already, or swept at the next lock or start
    }
  }

  /// The open vault has a Recovery Kit, whose wrap encrypted exports carry.
  late final bool _hasKit = ref.read(vaultControllerProvider).session != null && ref.read(vaultStoreProvider).recoveryKitInfo() != null;

  bool get _encrypted => _mode == ExportMode.encrypted;
  bool get _mismatch => _confirm.isNotEmpty && _password != _confirm;
  bool get _canExport => !_encrypted || (_password.isNotEmpty && _confirm.isNotEmpty && !_mismatch);

  Future<void> _export() async {
    if (_loading) return;
    final encrypted = _encrypted;
    final problem = !encrypted
        ? null
        : _password != _confirm
        ? 'export.error.mismatch'
        : _password.length < 8
        ? 'export.error.tooShort'
        : null;
    if (problem != null) {
      setState(() => _error = context.t(problem));
      return;
    }
    // Every secret of the vault leaves in it, encrypted or not: whoever holds the open vault shows it is them first
    setState(() => _error = null);
    if (!await ref.read(ownerCheckProvider)(context, ref, context.t('export.confirm')) || !mounted) return;
    setState(() => _loading = true);
    // What the vault remembers of the spaces' policies is read as it opens, and the export follows it once it is
    await ref.read(rememberedExportPoliciesProvider.notifier).ready;
    if (!mounted) return;
    final vault = ref.read(vaultControllerProvider);
    // The items of a space that forbids export stay out, and so do the items of a server space whose rules aren't known
    final exportable = ExportableVault.of(vault, ref.read(spaceExportRuleProvider));
    // A backup that leaves items out for want of their rules is partial, and no full backup was made
    final partial = encrypted && exportable.unknown > 0;
    // A login whose password a space hides from this member stays out: the file would carry the password
    final logins = ref.read(hiddenPasswordsProvider).withoutHidden(exportable.logins);
    final store = ref.read(vaultStoreProvider);
    final deriveKey = ref.read(exportDeriveKeyProvider);
    final files = ref.read(fileServiceProvider);
    final prefs = ref.read(prefsProvider.notifier);
    final now = ref.read(clockProvider)();
    try {
      final String json;
      if (encrypted) {
        final session = vault.session;
        final recoveryKey = session == null ? null : await store.loadRecoveryKey(session);
        json = await exportVault(
          exportable.accounts,
          exportable.backupServices,
          _password,
          keys: exportable.keys,
          notes: exportable.notes,
          passkeys: exportable.passkeys,
          keyAccounts: vault.keyAccounts,
          contacts: vault.contacts,
          logins: logins,
          cards: exportable.cards,
          identities: exportable.identities,
          recoveryKey: recoveryKey,
          deriveKey: deriveKey,
          now: now,
        );
      } else {
        json = exportVaultPlaintext(
          exportable.accounts,
          exportable.backupServices,
          keys: exportable.keys,
          notes: exportable.notes,
          passkeys: exportable.passkeys,
          keyAccounts: vault.keyAccounts,
          contacts: vault.contacts,
          logins: logins,
          cards: exportable.cards,
          identities: exportable.identities,
          now: now,
        );
      }
      final attached = [for (final note in exportable.notes) ...note.files];
      final SaveResult result;
      String? archive;
      if (attached.isEmpty) {
        result = await files.saveFile(exportFileName(now), utf8.encode(json));
      } else {
        final attachments = ref.read(attachmentStoreProvider);
        final vaultId = vault.vault.id;
        final name = exportFileName(now, archive: true);
        // One archive at a time: what an earlier try left goes before the next is built
        _dropScratch();
        final scratch = _scratch = File('${(await ref.read(exportScratchProvider)()).path}${Platform.pathSeparator}$name');
        await writeExportArchive(
          scratch.path,
          exportJson: json,
          files: [
            for (final file in attached)
              encrypted
                  ? (id: file.id, name: null, bytes: () => attachments.readSealed(vaultId, file.id))
                  : (id: file.id, name: file.name, bytes: () => _plainOrNull(attachments, vaultId, file.id, file.key)),
          ],
        );
        archive = scratch.path;
        result = await files.saveFileFrom(scratch.path, name, mimeType: 'application/zip');
      }
      // Closed without saving: nothing was exported, so the sheet stays as it was, and no archive stays behind.
      if (result is SaveCancelled) {
        _dropScratch();
        return;
      }
      // A plain archive holds every secret in the clear, and nothing reads it again
      if (!encrypted) _dropScratch();
      // Feeds the "Encrypted backup" item of Vault health, unless the backup left items out that it couldn't read the rules of
      if (encrypted && !partial) prefs.recordBackup();
      if (!mounted) return;
      setState(() {
        _done = true;
        _partial = partial;
        _savedPath = result is Saved ? result.location : null;
        _password = '';
        _confirm = '';
        if (encrypted) {
          _exported = (
            json: json,
            archive: archive,
            counts: (
              accounts: exportable.accounts.length,
              services: exportable.backupServices.length,
              keys: exportable.keys.length,
              notes: exportable.notes.length,
              passkeys: exportable.passkeys.length,
              files: attached.length,
              contacts: vault.contacts.length,
            ),
          );
        }
      });
    } catch (error) {
      _dropScratch();
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// An attached file decrypted for a plain export, or null when it isn't
  /// on this phone or doesn't open.
  static Future<Uint8List?> _plainOrNull(AttachmentStore store, String vaultId, String id, String key) async {
    try {
      return await store.read(vaultId, id, unb64(key));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final vault = ref.watch(vaultControllerProvider);
    final exportable = ExportableVault.of(vault, ref.watch(spaceExportRuleProvider));
    final accounts = exportable.accounts.length;
    final services = exportable.backupServices.length;
    final keys = exportable.keys.length;
    final notes = exportable.notes.length;
    final passkeys = exportable.passkeys.length;
    final contacts = vault.contacts.length;
    final logins = ref.watch(hiddenPasswordsProvider).withoutHidden(exportable.logins).length;
    final cards = exportable.cards.length;
    final identities = exportable.identities.length;
    final attached = exportable.notes.fold(0, (count, note) => count + note.files.length);
    final items = keys + notes + passkeys > 0;

    return TransferSheet(
      icon: Icons.file_download_outlined,
      title: context.t('export.title'),
      actions: [
        SheetCloseButton(label: context.t(_done ? 'export.close' : 'export.cancel')),
        if (!_done)
          FilledButton.icon(
            onPressed: _loading || !_canExport ? null : _export,
            icon: const Icon(Icons.file_download_outlined, size: 20),
            label: Text(context.t(_encrypted ? 'export.button' : 'export.plaintext.button')),
          ),
      ],
      children: spaced([
        Text(context.t('export.body'), style: AppType.body1.copyWith(color: p.textSecondary)),
        if (_hasKit && _encrypted) AppAlert(severity: AlertSeverity.info, child: Text(context.t('export.kit'))),
        ExportModeControl(
          value: _mode,
          enabled: !_done,
          semanticLabel: context.t('export.title'),
          onChanged: (mode) => setState(() => _mode = mode),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_encrypted) ...const [TransferTag('ML-KEM-1024', tone: TagTone.accent), TransferTag('AES-256-GCM', tone: TagTone.accent)],
            TransferTag(context.t('export.chip.accounts', {'count': accounts})),
            if (services > 0) TransferTag(context.t('export.chip.backupServices', {'count': services})),
            if (keys > 0) TransferTag(context.t('export.chip.keys', {'count': keys})),
            if (notes > 0) TransferTag(context.t('export.chip.notes', {'count': notes})),
            if (attached > 0) TransferTag(context.t('export.chip.files', {'count': attached})),
            if (passkeys > 0) TransferTag(context.t('export.chip.passkeys', {'count': passkeys})),
            if (contacts > 0) TransferTag(context.t('export.chip.contacts', {'count': contacts})),
            if (logins > 0) TransferTag(context.t('export.chip.logins', {'count': logins})),
            if (cards > 0) TransferTag(context.t('export.chip.cards', {'count': cards})),
            if (identities > 0) TransferTag(context.t('export.chip.identities', {'count': identities})),
          ],
        ),
        // The accounts kept on a security key: their names ride along, their secrets do not.
        if (vault.keyAccounts.isNotEmpty)
          Text(context.t('export.onKey', {'count': vault.keyAccounts.length}), style: AppType.caption.copyWith(color: p.textSecondary)),
        if (items && !_done)
          Text(
            context.t(attached > 0 ? 'export.items.archive' : 'export.items.older'),
            style: AppType.caption.copyWith(color: p.textSecondary),
          ),
        // A version from before logins reads the rest of the file, and passes them over
        if (logins > 0 && !_done) Text(context.t('export.logins.older'), style: AppType.caption.copyWith(color: p.textSecondary)),
        // The same for cards and identities, and a plain file shows their numbers and codes
        if (cards + identities > 0 && !_done)
          Text(context.t('export.cards.older'), style: AppType.caption.copyWith(color: p.textSecondary)),
        if (cards + identities > 0 && !_done && !_encrypted)
          AppAlert(
            severity: AlertSeverity.warning,
            icon: const Icon(Icons.lock_open_rounded, size: 20),
            child: Text(context.t('export.plaintext.warning.cards')),
          ),
        // What a space's rules keep out of the file, by space, and the server spaces whose rules haven't been read
        for (final MapEntry(:key, :value) in exportable.blocked.entries)
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('export.cxf.space', {'count': value, 'name': key}))),
        if (exportable.unknown > 0 && !_done)
          AppAlert(
            severity: AlertSeverity.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.t('export.space.unknown', {'count': exportable.unknown})),
                if (_encrypted) Padding(padding: const EdgeInsets.only(top: 4), child: Text(context.t('export.space.partial'))),
              ],
            ),
          ),
        // Sending to another app on the phone: shown only once export is switched on (plan task 8.6)
        if (!_done) const CredentialExportRow(),
        Divider(height: 1, color: p.divider),
        if (_error != null) AppAlert(severity: AlertSeverity.error, child: Text(_error!)),
        if (_done) ...[
          AppAlert(
            severity: AlertSeverity.success,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.t('export.success')),
                if (_savedPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Opacity(opacity: 0.85, child: Text(_savedPath!, style: AppType.caption)),
                  ),
              ],
            ),
          ),
          if (_partial) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('export.space.partial'))),
          if (_exported case final exported?) VerifyBackup(exported: exported.json, archive: exported.archive, counts: exported.counts),
        ] else if (!_encrypted)
          AppAlert(
            severity: AlertSeverity.warning,
            icon: const Icon(Icons.lock_open_rounded, size: 20),
            child: Text(
              items
                  ? context.t('export.plaintext.warning.items', {'keys': keys, 'passkeys': passkeys, 'files': attached})
                  : context.t('export.plaintext.warning'),
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: spaced([
              PasswordField(
                label: context.t('export.field.password'),
                helperText: context.t('export.field.passwordHelper'),
                enabled: !_loading,
                autofocus: true,
                textInputAction: TextInputAction.next,
                onChanged: (value) => setState(() => _password = value),
              ),
              PasswordField(
                label: context.t('export.field.confirm'),
                errorText: _mismatch ? context.t('export.field.mismatch') : null,
                enabled: !_loading,
                revealable: false,
                onChanged: (value) => setState(() => _confirm = value),
                onSubmitted: (_) {
                  if (!_loading && _password.isNotEmpty && !_mismatch) unawaited(_export());
                },
              ),
              if (_loading) WorkingNote(caption: context.t('export.loading')),
            ]),
          ),
      ]),
    );
  }
}

/// Whether the password typed again opened the backup with everything in it.
enum _Verdict { ok, wrongPassword, mismatch, missingFile }

/// Decrypts the file just saved with a password the person types from
/// memory, so a backup nobody can open is caught now rather than on
/// restore day. With an [archive], every attached file must be in it and
/// open with its key.
class VerifyBackup extends ConsumerStatefulWidget {
  const VerifyBackup({super.key, required this.exported, this.archive, required this.counts});

  final String exported;

  /// The archive's path, when the export was one.
  final String? archive;
  final ExportedCounts counts;

  @override
  ConsumerState<VerifyBackup> createState() => _VerifyBackupState();
}

class _VerifyBackupState extends ConsumerState<VerifyBackup> {
  String _password = '';
  bool _checking = false;
  _Verdict? _verdict;

  /// The first attached file that isn't in the archive or doesn't open: its note and name.
  ({String note, String file})? _missing;
  final _verdictKey = GlobalKey();

  Future<void> _verify() async {
    if (_password.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _verdict = null;
    });
    _Verdict verdict;
    ({String note, String file})? missing;
    try {
      final restored = await importVault(widget.exported, _password, deriveKey: ref.read(exportDeriveKeyProvider));
      final counts = widget.counts;
      final matches =
          restored.accounts.length == counts.accounts &&
          restored.backupServices.length == counts.services &&
          restored.keys.length == counts.keys &&
          restored.notes.length == counts.notes &&
          restored.passkeys.length == counts.passkeys &&
          restored.contacts.length == counts.contacts &&
          restored.fileCount == counts.files;
      verdict = matches ? _Verdict.ok : _Verdict.mismatch;
      if (matches && widget.archive != null) {
        missing = await _firstMissing(restored, widget.archive!);
        if (missing != null) verdict = _Verdict.missingFile;
      }
    } catch (_) {
      verdict = _Verdict.wrongPassword;
    }
    if (mounted) {
      setState(() {
        _verdict = verdict;
        _missing = missing;
        _checking = false;
      });
      revealAfterFrame(_verdictKey);
    }
  }

  /// Opens the archive and each attached file in it with its key.
  static Future<({String note, String file})?> _firstMissing(VaultExportPayload restored, String archive) async {
    final ExportArchive opened;
    try {
      opened = await readExportArchiveFile(archive);
    } catch (_) {
      final first = restored.notes.firstWhere((note) => note.files.isNotEmpty);
      return (note: first.title, file: first.files.first.name);
    }
    for (final note in restored.notes) {
      for (final file in note.files) {
        final sealed = opened.files[file.id];
        try {
          if (sealed == null) return (note: note.title, file: file.name);
          kma1DecryptSync(sealed(), unb64(file.key));
        } catch (_) {
          return (note: note.title, file: file.name);
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final verdict = _verdict;
    final counts = widget.counts;
    final items = counts.keys + counts.notes + counts.passkeys > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 20, color: b.accentText),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    context.t('export.verify.title'),
                    style: AppType.body1.copyWith(fontWeight: FontWeight.w600, color: p.text),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(context.t('export.verify.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          if (verdict != _Verdict.ok) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PasswordField(
                    label: context.t('export.verify.field'),
                    dense: true,
                    revealable: false,
                    enabled: !_checking,
                    onChanged: (value) => setState(() => _password = value),
                    onSubmitted: (_) => unawaited(_verify()),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _password.isEmpty || _checking ? null : _verify, child: Text(context.t('export.verify.button'))),
              ],
            ),
          ],
          if (_checking) ...[const SizedBox(height: 8), const WorkingBar()],
          if (verdict != null) ...[
            const SizedBox(height: 12),
            AppAlert(
              key: _verdictKey,
              severity: verdict == _Verdict.ok ? AlertSeverity.success : AlertSeverity.error,
              child: Text(
                [
                  context.t('export.verify.${verdict.name}', {
                    'accounts': counts.accounts,
                    'services': counts.services,
                    'note': _missing?.note ?? '',
                    'file': _missing?.file ?? '',
                  }),
                  if (items && verdict == _Verdict.ok)
                    context.t('export.verify.items', {
                      'keys': counts.keys,
                      'notes': counts.notes,
                      'files': counts.files,
                      'passkeys': counts.passkeys,
                    }),
                  if (counts.contacts > 0 && verdict == _Verdict.ok) context.t('export.verify.contacts', {'count': counts.contacts}),
                ].join(' '),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
