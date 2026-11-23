/// The Encrypt sheet (openspec: add-pgp-messages, `Encrypt.dc.html`): a
/// message or a file, to people or with a passphrase, signed by one of the
/// vault's keys unless told not to, and handed to the share sheet. Nothing
/// of it is kept: closing the sheet forgets the text, the recipients given
/// for it and the passphrase.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../contacts/recipients.dart';
import '../keys/card_key_use.dart';
import '../keys/key_bridge.dart' show pgpEncryptsPostQuantum;
import '../notes/note_files.dart' show fileSizeText;
import 'add_someone_sheet.dart';
import 'pgp_controller.dart';
import 'pgp_job.dart';
import 'pgp_people.dart';
import 'pgp_widgets.dart';

/// Opens the Encrypt sheet, with [to] as its first recipient when given
/// (a reply to whoever signed a decrypted message), and with [text] or
/// [file] to encrypt already in place (something shared to Kemlock).
Future<void> showEncryptSheet(BuildContext context, {PgpPerson? to, String? text, PickedPath? file}) => showAppBottomSheet<void>(
  context,
  label: context.t('pgp.encrypt.title'),
  builder: (_) => EncryptSheet(to: to, text: text, file: file),
);

enum _Mode { people, passphrase }

class EncryptSheet extends ConsumerStatefulWidget {
  const EncryptSheet({super.key, this.to, this.text, this.file});

  final PgpPerson? to;

  /// The message to start with.
  final String? text;

  /// The file to start with, which the sheet then deletes as it does a
  /// picker's copy.
  final PickedPath? file;

  @override
  ConsumerState<EncryptSheet> createState() => _EncryptSheetState();
}

class _EncryptSheetState extends ConsumerState<EncryptSheet> with ClosesOnLock {
  late _Mode _mode;
  late final PgpJobController _jobs;
  final _recipients = <PgpPerson>[];
  final _message = TextEditingController();
  final _passphrase = TextEditingController();
  final _passphraseAgain = TextEditingController();
  PickedPath? _file;
  var _sign = true;
  var _alsoToMe = true;
  var _passphraseShown = false;
  String? _signerId;
  String? _error;

  /// What the last run made, kept to share again until the sheet closes.
  String? _armored;
  ({String path, String name})? _encryptedFile;

  @override
  void initState() {
    super.initState();
    _jobs = ref.read(pgpJobControllerProvider.notifier);
    final own = ref.read(pgpOwnPeopleProvider);
    final usable = own.where((person) => person.isUsable && person.canSign);
    // Without a key of one's own, a passphrase is what works at once
    _mode = own.isEmpty && widget.to == null ? _Mode.passphrase : _Mode.people;
    final last = ref.read(pgpLastSignerProvider);
    _signerId = usable.any((person) => person.vaultKeyId == last) ? last : usable.firstOrNull?.vaultKeyId;
    if (widget.to != null) _recipients.add(widget.to!);
    _message.text = widget.text ?? '';
    if (widget.file case final file?) {
      _jobs.adopt(file.path);
      _file = file;
    }
    for (final controller in [_message, _passphrase, _passphraseAgain]) {
      controller.addListener(_edited);
    }
    closeOnLock();
  }

  @override
  void dispose() {
    // The text, the recipients and the passphrase go with the sheet; so do its files
    unawaited(_jobs.discard());
    _message.dispose();
    _passphrase.dispose();
    _passphraseAgain.dispose();
    super.dispose();
  }

  /// Something changed: what was made before is no longer what is shown.
  void _edited() => setState(() {
    _error = null;
    _armored = null;
    _encryptedFile = null;
  });

  PgpPerson? get _me => ref.read(pgpOwnPeopleProvider).where((person) => person.isUsable && person.vaultKeyId == _signerId).firstOrNull;

  /// What the sheet says of the keys a message to people goes to (design
  /// decision 12 of add-post-quantum-pgp): post-quantum protected when each
  /// one, the person's own included, is encrypted to with a post-quantum
  /// subkey, else not, naming the first that is not; nothing without a
  /// recipient. The text, and whether it is good news.
  (String, bool)? _postQuantumLine(BuildContext context) {
    final now = ref.read(clockProvider)();
    final me = _me;
    final keys = [..._recipients, if (_alsoToMe && me != null) me];
    if (keys.isEmpty) return null;
    for (final person in keys) {
      final crypto.PgpKeyInfo info;
      try {
        info = crypto.readPgpKeyInfo(person.publicKey);
      } on crypto.KeyFormatException {
        continue;
      }
      if (!pgpEncryptsPostQuantum(info, now)) return (context.t('pgp.encrypt.notPostQuantum', {'name': person.name}), false);
    }
    return (context.t('pgp.encrypt.postQuantum'), true);
  }

  bool get _passphrasesDiffer => _passphraseAgain.text.isNotEmpty && _passphrase.text != _passphraseAgain.text;

  bool get _hasContent => _file != null || _message.text.isNotEmpty;

  bool get _hasRecipient => switch (_mode) {
    _Mode.people => _recipients.isNotEmpty || (_alsoToMe && _me != null),
    _Mode.passphrase => _passphrase.text.isNotEmpty && _passphrase.text == _passphraseAgain.text,
  };

  Future<void> _addSomeone() async {
    final person = await showAddSomeoneSheet(context, exclude: {for (final r in _recipients) r.fingerprint});
    if (person == null || !mounted) return;
    _recipients.add(person);
    _edited();
  }

  Future<void> _pickFile() async {
    final picked = await ref.read(fileServiceProvider).pickFilePath();
    if (picked == null) return;
    // The picker's copy is plain text on disk: it is deleted with the sheet at the latest
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
    final usable = ref.read(pgpOwnPeopleProvider).where((person) => person.isUsable && person.canSign).toList();
    if (usable.length < 2) return;
    final chosen = await showPgpSignerPicker(context, usable, selected: _signerId);
    if (chosen == null || !mounted) return;
    ref.read(pgpLastSignerProvider.notifier).choose(chosen.vaultKeyId!);
    _signerId = chosen.vaultKeyId;
    _edited();
  }

  Future<void> _share() async {
    final files = ref.read(fileServiceProvider);
    final armored = _armored;
    final file = _encryptedFile;
    if (armored != null) await files.shareText(armored);
    if (file != null) await files.shareFileFrom(file.path, file.name);
  }

  Future<void> _encrypt() async {
    if (!_hasContent || !_hasRecipient || _jobs.isRunning) return;
    final messages = context.messages;
    final me = _me;
    final signer = _sign && me != null ? ref.read(vaultControllerProvider).keys.where((key) => key.id == me.vaultKeyId).firstOrNull : null;
    final file = _file;
    final text = file == null ? Uint8List.fromList(utf8.encode(_message.text)) : null;
    if (text != null && text.length > pgp.maxPgpTextLength) {
      setState(() => _error = messages.t('pgp.error.textTooLarge'));
      return;
    }
    // Each person once, however they got in
    final recipients = <String, PgpPerson>{
      if (_mode == _Mode.people) ...{
        for (final person in _recipients) person.fingerprint: person,
        if (_alsoToMe && me != null) me.fingerprint: me,
      },
    };
    final passphrase = _mode == _Mode.passphrase ? _passphrase.text : null;

    // The signing key's passphrase is asked for once a run says it is
    // needed: a key that cannot sign at all says so without a prompt
    String? signerPassphrase;
    // A signing key on a security key signs there (openspec: add-openpgp-card)
    final card = signer != null && signer.isOnCard ? CardKeyBridge(context, ref) : null;
    while (true) {
      final directory = file == null ? null : await _jobs.newDirectory();
      final outputName = file == null ? null : '${file.name}.gpg';
      final outcome = await _jobs.run(
        EncryptRequest(
          now: ref.read(clockProvider)(),
          text: text,
          inputPath: file?.path,
          fileName: file?.name ?? '',
          outputPath: directory == null ? null : '${directory.path}${Platform.pathSeparator}$outputName',
          recipients: [for (final person in recipients.values) person.publicKey],
          passphrase: passphrase,
          signer: signer == null ? null : jobKeyOf(signer, passphrase: signerPassphrase),
        ),
        directory: directory,
        // The copy the picker left is plain text: gone as soon as it is encrypted
        pickedCopy: file?.path,
        card: card,
      );
      if (!mounted) return;
      switch (outcome) {
        case PgpEncryptedOutcome(:final armored):
          setState(() {
            _error = null;
            _file = null;
            _armored = armored == null ? null : utf8.decode(armored);
            _encryptedFile = armored == null ? (path: '${directory!.path}${Platform.pathSeparator}$outputName', name: outputName!) : null;
          });
          await _share();
          return;
        case PgpFailedOutcome(:final error):
          final aboutSigner = signer != null && vaultKeyHas(ref, signer, error.fingerprint);
          if (aboutSigner && (error.problem == pgp.PgpProblem.wrongPassphrase || error.problem == pgp.PgpProblem.passphraseNeeded)) {
            // Asked, and asked again after a wrong one, with nothing encrypted
            signerPassphrase = await askPgpPassphrase(
              context,
              title: messages.t('pgp.keyPassphrase.title', {'name': me!.name}),
              body: messages.t('pgp.keyPassphrase.body'),
              error: error.problem == pgp.PgpProblem.wrongPassphrase ? messages.t('pgp.error.wrongKeyPassphrase') : null,
            );
            if (signerPassphrase == null || !mounted) return;
            continue;
          }
          setState(() => _error = pgpErrorText(messages, error, name: personWith(ref, error.fingerprint, _recipients)?.name));
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
    final own = ref.watch(pgpOwnPeopleProvider);
    final usable = own.where((person) => person.isUsable && person.canSign).toList();
    final me = usable.where((person) => person.vaultKeyId == _signerId).firstOrNull;
    final working = ref.watch(pgpJobControllerProvider) != null;
    // A contact that isn't checked is warned about by the contacts' own
    // warning, which offers to check it now; this sheet's line is for a key
    // given for this message alone, so nobody is warned about twice
    final unchecked = _recipients.where((person) => !person.isContact && !person.isChecked).toList();
    final contactIds = [for (final person in _recipients) ?person.contactId];
    // As the contacts are now, not as they were when chosen: one checked
    // from the warning is checked here too
    final uncheckedContact = ref
        .watch(pgpContactPeopleProvider)
        .any((person) => contactIds.contains(person.contactId) && !person.isChecked);
    final file = _file;
    final made = _armored != null || _encryptedFile != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.lock_outline_rounded), title: context.t('pgp.encrypt.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Rise(
                  child: SegmentedControl<_Mode>(
                    options: [
                      SegmentOption(value: _Mode.people, label: context.t('pgp.encrypt.toPeople')),
                      SegmentOption(value: _Mode.passphrase, label: context.t('pgp.encrypt.withPassphrase')),
                    ],
                    value: _mode,
                    onChanged: working
                        ? (_) {}
                        : (mode) {
                            _mode = mode;
                            _edited();
                          },
                    semanticLabel: context.t('pgp.encrypt.mode'),
                  ),
                ),
                if (_mode == _Mode.people) ...[
                  Rise(delay: const Duration(milliseconds: 60), child: SectionLabel(context.t('pgp.encrypt.to'))),
                  Rise(
                    delay: const Duration(milliseconds: 60),
                    child: GroupCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final (i, person) in _recipients.indexed)
                              PopIn(
                                key: ValueKey('recipient:${person.fingerprint}'),
                                delay: Duration(milliseconds: 60 * i),
                                child: InputChip(
                                  label: Text(person.name),
                                  onDeleted: working
                                      ? null
                                      : () {
                                          _recipients.remove(person);
                                          _edited();
                                        },
                                  deleteButtonTooltipMessage: context.t('pgp.encrypt.remove', {'name': person.name}),
                                ),
                              ),
                            TextButton(
                              onPressed: working ? null : () => unawaited(_addSomeone()),
                              child: Text(context.t('pgp.encrypt.addSomeone')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (unchecked.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                      child: Text(
                        unchecked.length == 1
                            ? context.t('pgp.encrypt.unchecked', {'name': unchecked.single.name})
                            : context.t('pgp.encrypt.uncheckedMany', {'count': unchecked.length}),
                        style: AppType.body2.copyWith(color: p.warning),
                      ),
                    ),
                  if (_postQuantumLine(context) case (final text, final good))
                    Padding(
                      key: const ValueKey('post-quantum-line'),
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                      child: Text(text, style: AppType.body2.copyWith(color: good ? p.success : p.warning)),
                    ),
                  if (own.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                      child: Text(context.t('pgp.encrypt.noKey'), style: AppType.body2.copyWith(color: p.textSecondary)),
                    )
                  else if (!_hasRecipient)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                      child: Text(context.t('pgp.encrypt.noRecipient'), style: AppType.body2.copyWith(color: p.textSecondary)),
                    ),
                ] else ...[
                  const SizedBox(height: 16),
                  PassphraseField(
                    controller: _passphrase,
                    label: context.t('pgp.encrypt.passphrase'),
                    shown: _passphraseShown,
                    onToggle: () => setState(() => _passphraseShown = !_passphraseShown),
                    enabled: !working,
                  ),
                  const SizedBox(height: 10),
                  PassphraseField(
                    controller: _passphraseAgain,
                    label: context.t('pgp.encrypt.passphraseAgain'),
                    shown: _passphraseShown,
                    onToggle: () => setState(() => _passphraseShown = !_passphraseShown),
                    enabled: !working,
                    error: _passphrasesDiffer ? context.t('pgp.encrypt.passphraseMismatch') : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                    child: Text(context.t('pgp.encrypt.passphraseBody'), style: AppType.caption.copyWith(color: p.textSecondary)),
                  ),
                ],
                // The field carries its own label, "Message", as the mockup has it over the field
                const SizedBox(height: 20),
                Rise(
                  delay: const Duration(milliseconds: 120),
                  child: file == null
                      ? TextField(
                          enableIMEPersonalizedLearning: false,
                          controller: _message,
                          enabled: !working,
                          minLines: 5,
                          maxLines: 10,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(labelText: context.t('pgp.encrypt.message'), alignLabelWithHint: true),
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
                  delay: const Duration(milliseconds: 180),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: working ? null : () => unawaited(file == null ? _pickFile() : _dropFile()),
                      child: Text(context.t(file == null ? 'pgp.encrypt.chooseFile' : 'pgp.encrypt.writeMessage')),
                    ),
                  ),
                ),
                if (me != null) ...[
                  const SizedBox(height: 8),
                  Rise(
                    delay: const Duration(milliseconds: 240),
                    child: GroupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PgpSwitchRow(
                            first: true,
                            primary: context.t('pgp.encrypt.signAs', {'name': me.name}),
                            secondary: context.t('pgp.encrypt.signAs.body'),
                            value: _sign,
                            onChanged: working
                                ? null
                                : (value) {
                                    _sign = value;
                                    _edited();
                                  },
                            onTap: usable.length > 1 && !working ? () => unawaited(_pickSigner()) : null,
                          ),
                          if (_mode == _Mode.people)
                            PgpSwitchRow(
                              primary: context.t('pgp.encrypt.alsoToMe'),
                              value: _alsoToMe,
                              onChanged: working
                                  ? null
                                  : (value) {
                                      _alsoToMe = value;
                                      _edited();
                                    },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (_mode == _Mode.people && uncheckedContact)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: UncheckedRecipientsWarning(contactIds: contactIds),
                  ),
                if (_error != null) PgpErrorLine(_error!),
                if (made && !working)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: AppAlert(
                      severity: AlertSeverity.success,
                      child: Row(
                        children: [
                          Expanded(child: Text(context.t('pgp.encrypt.done'))),
                          TextButton(onPressed: () => unawaited(_share()), child: Text(context.t('pgp.encrypt.shareAgain'))),
                        ],
                      ),
                    ),
                  ),
                Rise(
                  delay: const Duration(milliseconds: 300),
                  child: PgpWorkButton(
                    label: context.t('pgp.encrypt.button'),
                    onPressed: _hasContent && _hasRecipient ? () => unawaited(_encrypt()) : null,
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

/// A row with a switch whose words can also be tapped, as the "Sign as"
/// row is to choose the key: [GroupRow] is a button or holds a control,
/// not both.
class PgpSwitchRow extends StatelessWidget {
  const PgpSwitchRow({
    super.key,
    required this.primary,
    this.secondary,
    required this.value,
    required this.onChanged,
    this.onTap,
    this.first = false,
  });

  final String primary;
  final String? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Makes the words a button, with a chevron after them.
  final VoidCallback? onTap;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final words = Padding(
      padding: EdgeInsets.symmetric(vertical: secondary != null ? 8 : 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  primary,
                  style: AppType.body1.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0, color: p.text),
                ),
                if (secondary != null) Text(secondary!, style: AppType.caption.copyWith(color: p.textSecondary)),
              ],
            ),
          ),
          if (onTap != null) ExcludeSemantics(child: Icon(Icons.chevron_right_rounded, size: 20, color: context.bmc.faint)),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: p.divider)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: Row(
          children: [
            Expanded(
              child: onTap == null
                  ? Padding(padding: const EdgeInsets.only(left: 14), child: words)
                  : Semantics(
                      button: true,
                      child: InkWell(
                        onTap: onTap,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 54),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 14),
                            child: Center(child: words),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: primary,
              child: Switch(value: value, onChanged: onChanged),
            ),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}

/// Lets the person choose which of [keys], the vault's keys that can
/// sign, to sign as. Gives the one chosen, or null.
Future<PgpPerson?> showPgpSignerPicker(BuildContext context, List<PgpPerson> keys, {String? selected}) => showAppBottomSheet<PgpPerson>(
  context,
  label: context.t('pgp.signer.title'),
  builder: (sheet) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DialogHeading(icon: const Icon(Icons.draw_outlined), title: sheet.t('pgp.signer.title')),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Group(
            children: [
              for (final (i, person) in keys.indexed)
                GroupRow(
                  key: ValueKey('signer:${person.vaultKeyId}'),
                  first: i == 0,
                  icon: const Text('PGP'),
                  accent: true,
                  primary: person.name,
                  secondary: person.ed25519Signatures ? sheet.t('pgp.sign.ed25519Only') : personLine(person),
                  tag: person.vaultKeyId == selected ? Icon(Icons.check_rounded, size: 20, color: sheet.bmc.accentText) : null,
                  onTap: () => Navigator.of(sheet).pop(person),
                ),
            ],
          ),
        ),
      ),
    ],
  ),
);

/// The vault key a person stands for, when it is one of the vault's own.
VaultKey? vaultKeyOfPerson(WidgetRef ref, PgpPerson? person) =>
    person?.vaultKeyId == null ? null : ref.read(vaultControllerProvider).keys.where((key) => key.id == person!.vaultKeyId).firstOrNull;
