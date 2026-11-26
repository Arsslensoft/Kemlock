import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/custom_field.dart';
import '../../models/json.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../platform/secret_clipboard.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/tag_input.dart';
import '../export/space_export.dart';
import '../fields/custom_fields_editor.dart';
import '../links/linked_items_section.dart';
import '../spaces/hidden_passwords.dart';
import '../sync/kemlock/km_kinds.dart';
import '../sync/space_picker.dart';
import '../sync/sync_store.dart';
import '../vault/owner_check.dart';
import 'card_keys.dart';
import 'key_bridge.dart';
import 'key_expiry_sheet.dart';
import 'key_revoke_sheet.dart';
import 'key_subkey_sheet.dart';
import 'key_user_id_sheet.dart';
import 'key_widgets.dart';
import 'sign_sheet.dart';
import 'verify_sheet.dart';

/// Opens a key from the Vault tab.
Future<void> showKeySheet(BuildContext context, VaultKey key) => showAppBottomSheet<void>(
  context,
  label: key.name,
  builder: (_) => KeySheet(keyId: key.id),
);

/// Writes a key's private half out; tests replace it with one that needs no isolate.
final keyExporterProvider = Provider<Future<String> Function(crypto.ParsedKey key, {String? passphrase, String? comment})>(
  (ref) => exportKeyInBackground,
);

/// What to do with the private half once the person has agreed.
enum _PrivateAction { show, copy, export }

/// A key: what it is, its fingerprint, and its public half to copy, share
/// or show as a QR code, without asking. An SSH key also signs a file or
/// text, which uses its private half where it is and needs no asking
/// either, and opens the sheet that verifies a signature. Its private half stays hidden:
/// showing, copying or exporting it says first that the key will also live
/// outside the vault, then asks who it is: biometrics when the vault opens
/// with them, its master password otherwise. Its name, note and tags can
/// change. A PGP key can be changed too,
/// in its "Change this key" section: a subkey, a user ID, its expiry or a
/// revocation, each in its own sheet (openspec: add-pgp-key-editing);
/// other keys' halves never change. Delete has Undo in the toast.
class KeySheet extends ConsumerStatefulWidget {
  const KeySheet({super.key, required this.keyId});

  final String keyId;

  @override
  ConsumerState<KeySheet> createState() => _KeySheetState();
}

class _KeySheetState extends ConsumerState<KeySheet> {
  late final VaultKey? _initial = ref.read(vaultControllerProvider).keys.firstWhereOrNull((key) => key.id == widget.keyId);
  late final _name = TextEditingController(text: _initial?.name ?? '');
  late final _note = TextEditingController(text: _initial?.note ?? '');
  late var _tags = <String>[...?_initial?.tags];

  /// The custom fields, as the editor last gave them.
  late var _customFields = <CustomField>[...?_initial?.fields];
  late String? _spaceId = _initial?.spaceId;

  /// A change was saved while the sheet is open (openspec: add-pgp-key-editing).
  var _changed = false;
  String? _refusalFor;
  crypto.PgpEditRefusal? _refusal;
  var _unreadable = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  VaultKey _edited(VaultKey key) {
    final name = _name.text.trim();
    final note = _note.text.trim();
    return key.copyWith(
      name: name.isEmpty ? key.name : name,
      note: note.isEmpty ? unset : note,
      tags: _tags.isEmpty ? unset : [..._tags],
      spaceId: _spaceId ?? unset,
      fields: _customFields,
    );
  }

  void _toast(String id, [Map<String, Object?> args = const {}]) => ref.read(toastsProvider.notifier).show(context.t(id, args));

  Future<void> _copyPublic(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _toast('keys.public.copied');
  }

  Future<void> _sharePublic(VaultKey key, String text, String extension) => ref
      .read(fileServiceProvider)
      .shareFile(
        '${exportedKeyFileName(key).replaceAll(RegExp(r'\.(pem|asc)$'), '')}$extension',
        Uint8List.fromList(utf8.encode(text)),
        mimeType: 'text/plain',
      );

  /// The warning, then the check that the person is the vault's owner, as
  /// an export asks it ([checkOwner]): biometrics when the vault has them,
  /// its master password otherwise. True when they may go on to the
  /// private half.
  Future<bool> _mayTakePrivate() async {
    final agreed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.warning_amber_rounded),
      title: context.t('keys.private.warning.title'),
      body: Text(context.t('keys.private.warning.body')),
      confirmLabel: context.t('keys.private.warning.confirm'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!agreed || !mounted) return false;
    return ref.read(ownerCheckProvider)(context, ref, context.t('keys.private.biometric'));
  }

  /// Whether the space [key] belongs to keeps it out of a file: its verified chain forbids exporting its items, or it is a
  /// server space whose chain this phone hasn't read since the vault opened, so its policy isn't known and the key stays out as
  /// the file exports leave it (`space_export.dart`). Says why, and the private key is written nowhere.
  bool _exportRefused(VaultKey key) {
    final rule = ref.read(spaceExportRuleProvider);
    final space = key.spaceId;
    final String reason;
    if (rule.forbids(space)) {
      reason = 'blocked';
    } else if (rule.unknown(space)) {
      reason = 'unknown';
    } else {
      return false;
    }
    _toast('keys.export.space', {'reason': reason, 'space': rule.nameOf?.call(space!) ?? space});
    return true;
  }

  Future<void> _private(VaultKey key, _PrivateAction action) async {
    // Show and Copy stay as they are: a key on screen or on the secret clipboard is no file. A file is what a space's rule is about
    if (action == _PrivateAction.export && _exportRefused(key)) return;
    if (!await _mayTakePrivate() || !mounted) return;
    final parsed = parsedKeyOf(key);
    final export = ref.read(keyExporterProvider);
    switch (action) {
      case _PrivateAction.show:
        final text = await export(parsed, comment: key.name);
        if (!mounted) return;
        await showAppDialog<void>(
          context,
          builder: (dialog) => AppDialog(
            heading: DialogHeading(title: dialog.t('keys.private.show')),
            // Selected and copied, the private key goes through the secret clipboard as Copy does
            content: SecretSelection(
              child: SelectableText(
                text,
                style: AppType.mono(fontSize: 11, color: dialog.palette.text),
                contextMenuBuilder: secretTextMenu,
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(dialog.t('notes.file.close')))],
          ),
        );
      case _PrivateAction.copy:
        final text = await export(parsed, comment: key.name);
        if (await ref.read(secretClipboardProvider).copy(text) && mounted) {
          // On iOS the copy is local only, kept off Universal Clipboard
          _toast(defaultTargetPlatform == TargetPlatform.iOS ? 'keys.private.copiedIos' : 'keys.private.copied');
        }
      case _PrivateAction.export:
        // A PGP key with its own passphrase leaves as it came; any other gets one unless the person says not to.
        // Read from the key itself: a stub is no protection, whatever a key stored before said.
        final own = parsed.pgp?.protected ?? false;
        final passphrase = own ? null : await _askPassphrase(partly: parsed.pgp?.partlyProtected ?? false);
        if (passphrase == null && !own) return;
        if (!mounted || _exportRefused(key)) return;
        final text = await export(parsed, passphrase: passphrase == '' ? null : passphrase, comment: key.name);
        final result = await ref
            .read(fileServiceProvider)
            .saveFile(exportedKeyFileName(key), Uint8List.fromList(utf8.encode(text)), mimeType: 'application/octet-stream');
        if (result is Saved && mounted) _toast('notes.copy.saved', {'location': result.location});
    }
  }

  /// The passphrase to export with, '' for none once the person confirmed
  /// that twice, or null when they cancelled.
  Future<String?> _askPassphrase({bool partly = false}) async {
    final chosen = await showAppDialog<String>(context, builder: (_) => _PassphraseDialog(partly: partly));
    if (chosen != '' || !mounted) return chosen;
    final sure = await showConfirmDialog(
      context,
      icon: const Icon(Icons.lock_open_rounded),
      title: context.t('keys.export.none.title'),
      body: Text(context.t('keys.export.none.body')),
      confirmLabel: context.t('keys.export.none.confirm'),
      cancelLabel: context.t('export.cancel'),
    );
    return sure ? '' : null;
  }

  /// Opens a change's sheet; once it saved, the sheet says the public key
  /// must go out again until it closes.
  Future<void> _change(Future<bool> Function() open) async {
    if (await open() && mounted) setState(() => _changed = true);
  }

  /// Why [key] can't be changed, read once for each private half. A key on
  /// a security key never can: no change is signed on a card (openspec:
  /// add-openpgp-card).
  crypto.PgpEditRefusal? _refusalOf(VaultKey key) {
    if (_refusalFor != key.privateKey) {
      _refusalFor = key.privateKey;
      _unreadable = false;
      try {
        _refusal =
            crypto.editRefusal(unb64(key.privateKey)) ??
            (key.isOnCard ? const crypto.PgpEditRefusal(crypto.PgpEditBlock.noPrimarySecret) : null);
      } on crypto.KeyFormatException {
        _refusal = const crypto.PgpEditRefusal(crypto.PgpEditBlock.algorithm, '');
        _unreadable = true;
      } on FormatException {
        _refusal = const crypto.PgpEditRefusal(crypto.PgpEditBlock.algorithm, '');
        _unreadable = true;
      }
    }
    return _refusal;
  }

  String _refusalText(crypto.PgpEditRefusal refusal, VaultKey key) {
    if (_unreadable) return context.t('keys.change.blocked.unreadable');
    return switch (refusal.block) {
      crypto.PgpEditBlock.revoked => context.t('keys.change.blocked.revoked'),
      crypto.PgpEditBlock.version6 => context.t('keys.change.blocked.version6'),
      crypto.PgpEditBlock.noPrimarySecret when key.isOnCard => context.t('keys.card.change'),
      crypto.PgpEditBlock.noPrimarySecret => context.t('keys.change.blocked.noPrimarySecret'),
      crypto.PgpEditBlock.algorithm => context.t('keys.change.blocked.algorithm', {'algorithm': refusal.detail ?? ''}),
      crypto.PgpEditBlock.protection => context.t('keys.change.blocked.protection', {'name': refusal.detail ?? ''}),
    };
  }

  /// The section that changes a PGP key: four rows, or why it can't be changed.
  Widget _changeSection(VaultKey key, crypto.ParsedKey parsed, String locale) {
    final refusal = _refusalOf(key);
    if (refusal != null) {
      return AppAlert(key: const ValueKey('key-change-refused'), severity: AlertSeverity.info, child: Text(_refusalText(refusal, key)));
    }
    final expires = parsed.pgp?.primary.expires;
    return Group(
      key: const ValueKey('key-change'),
      children: [
        GroupRow(
          first: true,
          icon: const Icon(Icons.add_moderator_outlined),
          primary: context.t('keys.change.addSubkey'),
          onTap: () => unawaited(_change(() => showKeySubkeySheet(context, key))),
        ),
        GroupRow(
          icon: const Icon(Icons.person_add_alt_outlined),
          primary: context.t('keys.change.addUserId'),
          onTap: () => unawaited(_change(() => showKeyUserIdSheet(context, key))),
        ),
        GroupRow(
          icon: const Icon(Icons.event_outlined),
          primary: context.t('keys.change.expiry'),
          value: Text(expires == null ? context.t('keys.change.expiryNever') : DateFormat.yMMMd(locale).format(expires.toLocal())),
          onTap: () => unawaited(_change(() => showKeyExpirySheet(context, key))),
        ),
        GroupRow(
          icon: const Icon(Icons.gpp_maybe_outlined),
          primary: context.t('keys.change.revoke'),
          onTap: () => unawaited(_change(() => showKeyRevokeSheet(context, key))),
        ),
      ],
    );
  }

  Future<void> _save(VaultKey key) async {
    if (await ref.read(vaultControllerProvider.notifier).updateKey(_edited(key)) && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete(VaultKey key) async {
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deleteKey(key);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final key = ref.watch(vaultControllerProvider.select((state) => state.keys.firstWhereOrNull((key) => key.id == widget.keyId)));
    if (key == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('keys.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final parsed = parsedKeyOf(key);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final sshLine = key.kind == KeyKind.ssh ? crypto.sshPublicKeyLine(parsed, comment: key.name) : null;
    final pem = crypto.publicKeyPem(parsed);
    final changed = _edited(key) != key;
    final allTags = {for (final other in ref.watch(vaultControllerProvider.select((state) => state.keys))) ...?other.tags}.toList()..sort();
    final hasSpaces = ref.watch(syncProvider.select((sync) => sync.settings?.spaces.isNotEmpty ?? false));

    // A PGP key too long for one code shows its fingerprint there instead (openspec: add-pgp-contacts)
    Widget publicRow(String label, String text, String extension, {String? fingerprint}) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: AppType.caption.copyWith(color: p.textSecondary)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: context.bmc.raised, borderRadius: BorderRadius.circular(12)),
            child: Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: AppType.mono(fontSize: 11, color: p.text),
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => unawaited(_copyPublic(text)),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(context.t('keys.public.copy')),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_sharePublic(key, text, extension)),
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(context.t('notes.copy.share')),
              ),
              TextButton.icon(
                onPressed: () => unawaited(showPublicKeyQr(context, text, fingerprint: fingerprint)),
                icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                label: Text(context.t('keys.public.qr')),
              ),
            ],
          ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: Icon(key.kind == KeyKind.pgp ? Icons.verified_user_outlined : Icons.key_rounded), title: key.name),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_changed && pem != null) ...[
                  AppAlert(
                    key: const ValueKey('key-changed'),
                    severity: AlertSeverity.info,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.t('keys.change.sendPublic')),
                        TextButton.icon(
                          onPressed: () => unawaited(_sharePublic(key, pem, '.pub.asc')),
                          icon: const Icon(Icons.ios_share_rounded, size: 18),
                          label: Text(context.t('keys.change.sharePublic')),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                KeyFacts(
                  parsed: parsed,
                  onSubkey: key.kind == KeyKind.pgp && _refusalOf(key) == null
                      ? (i) => unawaited(_change(() => showKeyExpirySheet(context, key, subkey: parsed.pgp!.subkeys[i].fingerprint)))
                      : null,
                  now: ref.watch(clockProvider)(),
                  cardSerial: key.isOnCard ? cardKeySerial(key) ?? '' : null,
                  cardGone: key.isOnCard && cardNoLongerHolds(key, ref.watch(cardsSeenProvider)),
                  extra: [
                    GroupRow(
                      icon: const Icon(Icons.event_outlined),
                      primary: context.t('keys.field.added'),
                      value: Text(DateFormat.yMMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(key.addedAt))),
                    ),
                    GroupRow(
                      icon: Icon(key.origin == KeyOrigin.generated ? Icons.auto_awesome_rounded : Icons.file_open_outlined),
                      primary: context.t('keys.field.origin'),
                      value: Text(context.t(key.origin == KeyOrigin.generated ? 'keys.origin.generated' : 'keys.origin.imported')),
                    ),
                  ],
                ),
                if (sshLine != null) publicRow(context.t('keys.public.ssh'), sshLine, '.pub'),
                if (pem != null)
                  publicRow(
                    context.t(key.kind == KeyKind.pgp ? 'keys.public.pgp' : 'keys.public.pem'),
                    pem,
                    key.kind == KeyKind.pgp ? '.pub.asc' : '.pub.pem',
                    fingerprint: key.kind == KeyKind.pgp ? parsed.pgp?.primary.fingerprintHex : null,
                  ),
                if (key.kind == KeyKind.ssh) ...[
                  const SizedBox(height: 12),
                  Group(
                    key: const ValueKey('ssh-signatures'),
                    children: [
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.draw_outlined),
                        primary: context.t('keys.sign.action'),
                        onTap: () => unawaited(showSignSheet(context, key)),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.verified_outlined),
                        primary: context.t('keys.verify.action'),
                        onTap: () => unawaited(showVerifySheet(context)),
                      ),
                    ],
                  ),
                ],
                // A key on a security key has no private half here to show, copy or export
                if (!key.isOnCard) ...[
                  SectionLabel(context.t('keys.private.title')),
                  Group(
                    children: [
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.visibility_outlined),
                        primary: context.t('keys.private.show'),
                        onTap: () => unawaited(_private(key, _PrivateAction.show)),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.copy_rounded),
                        primary: context.t('keys.private.copy'),
                        onTap: () => unawaited(_private(key, _PrivateAction.copy)),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.file_download_outlined),
                        primary: context.t('keys.private.export'),
                        secondary: context.t(parsed.pgp?.protected ?? false ? 'keys.private.export.own' : 'keys.private.export.body'),
                        onTap: () => unawaited(_private(key, _PrivateAction.export)),
                      ),
                    ],
                  ),
                ],
                if (key.kind == KeyKind.pgp) ...[SectionLabel(context.t('keys.change.title')), _changeSection(key, parsed, locale)],
                const SizedBox(height: 18),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  decoration: InputDecoration(labelText: context.t('keys.field.name')),
                ),
                const SizedBox(height: 14),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('passkeys.note'), alignLabelWithHint: true),
                ),
                const SizedBox(height: 14),
                CustomFieldsEditor(
                  kind: itemKindOf(key),
                  fields: _customFields,
                  onChanged: (next) => setState(() => _customFields = next),
                  hideSecrets: hidesSecretsOf(ref, key),
                ),
                const SizedBox(height: 14),
                TagInput(value: _tags, onChanged: (tags) => setState(() => _tags = tags), suggestions: allTags),
                // A space's members get the key, private half and all, as they get an account
                if (hasSpaces || _spaceId != null) ...[
                  const SizedBox(height: 14),
                  SpacePicker(value: _spaceId, onChanged: (id) => setState(() => _spaceId = id)),
                ],
                LinkedItemsSection(entry: key),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t('keys.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(key)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: changed ? () => unawaited(_save(key)) : null,
                  child: Text(context.t('passkeys.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Asks for the passphrase an exported key is protected with, typed twice,
/// or for none: pops the passphrase, '' for none, or null when cancelled.
/// For a PGP key [partly] protected by its own passphrase, it says that
/// part stays behind it.
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({this.partly = false});

  final bool partly;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  var _none = false;

  @override
  void initState() {
    super.initState();
    _first.addListener(() => setState(() {}));
    _second.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  bool get _mismatch => _second.text.isNotEmpty && _first.text != _second.text;
  bool get _ready => _none || (_first.text.isNotEmpty && _first.text == _second.text);

  @override
  Widget build(BuildContext context) => AppDialog(
    semanticLabel: context.t('keys.export.title'),
    heading: DialogHeading(title: context.t('keys.export.title')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.t('keys.export.body')),
        if (widget.partly) ...[const SizedBox(height: 8), Text(context.t('keys.export.partly'), key: const ValueKey('export-partly'))],
        const SizedBox(height: 12),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _first,
          enabled: !_none,
          obscureText: true,
          decoration: InputDecoration(labelText: context.t('keys.export.passphrase')),
        ),
        const SizedBox(height: 10),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _second,
          enabled: !_none,
          obscureText: true,
          decoration: InputDecoration(
            labelText: context.t('keys.export.again'),
            errorText: _mismatch ? context.t('export.field.mismatch') : null,
          ),
        ),
        // Its own Material, so the tile's ink shows over the dialog's paper
        Material(
          type: MaterialType.transparency,
          child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _none,
            onChanged: (value) => setState(() => _none = value ?? false),
            title: Text(context.t('keys.export.none')),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.cancel'))),
      FilledButton(
        onPressed: _ready ? () => Navigator.of(context).pop(_none ? '' : _first.text) : null,
        child: Text(context.t('keys.export.button')),
      ),
    ],
  );
}
