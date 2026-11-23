/// Adding a card's keys to the vault, and generating keys on the card
/// (openspec: add-openpgp-card, design decisions 5 and 11).
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/security_keys.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../security_key/openpgp_card/card_data.dart';
import '../../security_key/openpgp_card/card_operations.dart';
import '../../security_key/openpgp_card/card_public_key.dart';
import '../../security_key/openpgp_card/card_session.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../keys/card_keys.dart';
import '../pgp/pgp_people.dart';
import 'card_pin_change.dart';
import 'card_pin_forms.dart';
import 'key_widgets.dart';
import 'openpgp_card_controller.dart';
import 'openpgp_card_sheet.dart' show cardErrorText;

/// Asks for [pins] up front, each with the tries the card reported, and
/// gives them to [card] for the connection: for work that must not stop
/// half way to ask. False when the person gave up or a PIN is blocked.
Future<bool> askCardPins(BuildContext context, OpenPgpCardController card, List<CardPin> pins) async {
  final status = card.snapshot?.pinStatus;
  for (final pin in pins) {
    final tries = status == null ? cardFullTries : OpenPgpCardSession.triesOf(status, pin);
    if (tries == 0) {
      showToast(context, cardErrorText(context, CardPinBlocked(pin))!, severity: ToastSeverity.error);
      return false;
    }
    final typed = await showCardPinPrompt(context, pin: pin, triesLeft: tries);
    if (typed == null || !context.mounted) return false;
    card.givePin(pin, typed);
  }
  return true;
}

/// Adds the card's key to the vault, unless the vault holds it already.
Future<bool> _addCardKey(WidgetRef ref, VaultKey key) => ref.read(vaultControllerProvider.notifier).addKey(key);

// ─── Add to vault ─────────────────────────────────────────────────────────────

/// Opens the "Add to vault" sheet of [card]'s keys: the ways of design
/// decision 5.
Future<void> showCardAddToVault(BuildContext context, OpenPgpCardController card) => showAppBottomSheet<void>(
  context,
  label: context.t('securityKeys.openpgp.add.title'),
  builder: (_) => CardAddToVaultSheet(card: card),
);

class CardAddToVaultSheet extends ConsumerStatefulWidget {
  const CardAddToVaultSheet({super.key, required this.card});

  final OpenPgpCardController card;

  @override
  ConsumerState<CardAddToVaultSheet> createState() => _CardAddToVaultSheetState();
}

enum _AddWay { choose, import, make }

class _CardAddToVaultSheetState extends ConsumerState<CardAddToVaultSheet> {
  final _pasted = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  _AddWay _way = _AddWay.choose;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    for (final field in [_pasted, _name, _email]) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in [_pasted, _name, _email]) {
      field.dispose();
    }
    super.dispose();
  }

  CardSnapshot? get _snapshot => widget.card.snapshot;

  Future<void> _done(VaultKey key) async {
    final messages = context.messages;
    if (await _addCardKey(ref, key) && mounted) {
      showToast(context, messages.t('securityKeys.openpgp.add.done', {'name': key.name}));
      Navigator.of(context).pop();
    }
  }

  /// The second way: a public key the person has, accepted only when one
  /// of its keys is on the card.
  Future<void> _import() async {
    final snapshot = _snapshot;
    if (snapshot == null || _working) return;
    final messages = context.messages;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final public = await ref.read(pgpPublicKeyReaderProvider)(_pasted.text);
      if (cardPlacesOfKey(public.transferableKey, snapshot).isEmpty) {
        setState(() => _error = messages.t('securityKeys.openpgp.add.notThisCard'));
        return;
      }
      await _done(
        cardVaultKey(
          id: newUuid(),
          name: userIdName(public.userId) ?? public.userId,
          publicKey: public.transferableKey,
          snapshot: snapshot,
          origin: KeyOrigin.imported,
        ),
      );
    } on pgp.PgpException {
      if (mounted) setState(() => _error = messages.t('securityKeys.openpgp.add.unreadable'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// The third way: a public key made from the card's own key material,
  /// certified for the name and email by the card, with its PIN.
  Future<void> _make() async {
    if (_working) return;
    final String userId;
    try {
      userId = crypto.pgpUserId(_name.text, _email.text);
    } on ArgumentError {
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final key = await makeCardKeyPublic(context, ref, widget.card, userId: userId, name: _name.text.trim(), origin: KeyOrigin.imported);
      if (key != null) await _done(key);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.openpgp.add.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.card.keys),
                if (_error != null) ...[
                  AppAlert(key: const ValueKey('card-add-error'), severity: AlertSeverity.error, child: Text(_error!)),
                  const SizedBox(height: 12),
                ],
                ...switch (_way) {
                  _AddWay.choose => [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
                      child: Text(context.t('securityKeys.openpgp.add.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                    ),
                    Group(
                      children: [
                        GroupRow(
                          key: const ValueKey('card-add-import'),
                          first: true,
                          icon: const Icon(Icons.file_open_outlined),
                          primary: context.t('securityKeys.openpgp.add.import'),
                          secondary: context.t('securityKeys.openpgp.add.import.detail'),
                          onTap: () => setState(() => _way = _AddWay.import),
                        ),
                        GroupRow(
                          key: const ValueKey('card-add-make'),
                          icon: const Icon(Icons.build_outlined),
                          primary: context.t('securityKeys.openpgp.add.make'),
                          secondary: context.t('securityKeys.openpgp.add.make.detail'),
                          onTap: () => setState(() => _way = _AddWay.make),
                        ),
                      ],
                    ),
                  ],
                  _AddWay.import => [
                    TextField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey('card-add-pasted'),
                      controller: _pasted,
                      minLines: 4,
                      maxLines: 8,
                      enabled: !_working,
                      decoration: InputDecoration(labelText: context.t('securityKeys.openpgp.add.pasted'), alignLabelWithHint: true),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      style: largeButtonStyle,
                      onPressed: _pasted.text.trim().isEmpty || _working ? null : () => unawaited(_import()),
                      child: Text(context.t('securityKeys.openpgp.addToVault')),
                    ),
                  ],
                  _AddWay.make => [
                    AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.openpgp.add.make.note'))),
                    const SizedBox(height: 14),
                    TextField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey('card-add-name'),
                      controller: _name,
                      enabled: !_working,
                      decoration: InputDecoration(labelText: context.t('keys.field.name')),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey('card-add-email'),
                      controller: _email,
                      enabled: !_working,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(labelText: context.t('securityKeys.openpgp.add.email')),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      style: largeButtonStyle,
                      onPressed: _name.text.trim().isEmpty || _email.text.trim().isEmpty || _working ? null : () => unawaited(_make()),
                      child: Text(context.t('securityKeys.openpgp.addToVault')),
                    ),
                  ],
                },
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Builds the public key of [card]'s keys from what the card reports,
/// writes a missing fingerprint and time with the admin PIN (finishing a
/// generation that was cut off), has the card certify it for [userId] with
/// its PIN, checks its self-signatures, and gives the vault key; null when
/// the person gave up or it failed, which is said.
Future<VaultKey?> makeCardKeyPublic(
  BuildContext context,
  WidgetRef ref,
  OpenPgpCardController card, {
  required String userId,
  required String name,
  required String origin,
}) async {
  final now = ref.read(clockProvider)();
  Uint8List? public;
  CardSnapshot? snapshot;
  final made = await runWithCardPin(context, card, (session) async {
    final packets = await cardKeyPackets(session, missingTime: now, writeMissing: true);
    public = await cardTransferablePublicKey(session, packets, userId: userId, now: now);
    snapshot = session.read;
  });
  final key = public;
  final read = snapshot;
  if (!made || key == null || read == null || !context.mounted) return null;
  if (!await crypto.verifyPgpSelfSignatures(key)) {
    if (context.mounted) showToast(context, context.t('securityKeys.openpgp.use.badSignature'), severity: ToastSeverity.error);
    return null;
  }
  return cardVaultKey(id: newUuid(), name: name, publicKey: key, snapshot: read, origin: origin);
}

// ─── Generating ───────────────────────────────────────────────────────────────

/// A kind of key the card can make in all three places.
enum CardKeyKind {
  ed25519('Ed25519'),
  rsa2048('RSA 2048'),
  rsa3072('RSA 3072'),
  rsa4096('RSA 4096'),
  nistp256('NIST P-256'),
  nistp384('NIST P-384');

  const CardKeyKind(this.label);

  final String label;

  /// Whether the card can make this kind only while plugged in: big RSA
  /// keys take longer than an NFC session lasts.
  bool get needsUsb => this == rsa3072 || this == rsa4096;

  /// The attributes of this kind for [place].
  CardAlgorithm attributes(CardPlace place) => switch (this) {
    ed25519 => CardAlgorithm.parse(
      place == CardPlace.decryption
          ? const [0x12, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01]
          : const [0x16, 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01],
    ),
    rsa2048 => RsaAttributes.ofBits(2048),
    rsa3072 => RsaAttributes.ofBits(3072),
    rsa4096 => RsaAttributes.ofBits(4096),
    nistp256 => EccAttributes.of(place == CardPlace.decryption ? 0x12 : 0x13, const [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]),
    nistp384 => EccAttributes.of(place == CardPlace.decryption ? 0x12 : 0x13, const [0x2b, 0x81, 0x04, 0x00, 0x22]),
  };

  /// Whether [algorithm] is this kind for [place], whatever import form an
  /// RSA attribute names.
  bool matches(CardPlace place, CardAlgorithm algorithm) => switch ((attributes(place), algorithm)) {
    (RsaAttributes(:final modulusBits), RsaAttributes(modulusBits: final bits)) => modulusBits == bits,
    (EccAttributes(:final id, :final curve), EccAttributes(id: final otherId, curve: final otherCurve)) =>
      id == otherId && curve == otherCurve,
    _ => false,
  };
}

/// The kinds [snapshot]'s card can make, Kemlock can use, in the order
/// offered: those its algorithm list has for every place, or, for a card
/// without the list (before version 3.4), the one its places are set to.
List<CardKeyKind> cardKeyKinds(CardSnapshot snapshot) {
  final list = snapshot.algorithms;
  if (list == null) {
    final current = [
      for (final kind in CardKeyKind.values)
        if (CardPlace.values.every(
          (place) => snapshot.data.attributes[place] != null && kind.matches(place, snapshot.data.attributes[place]!),
        ))
          kind,
    ];
    return current;
  }
  return [
    for (final kind in CardKeyKind.values)
      if (CardPlace.values.every((place) => list.of(place).any((a) => a.usable && kind.matches(place, a)))) kind,
  ];
}

/// Opens the Generate sheet of [card].
Future<void> showCardGenerate(BuildContext context, OpenPgpCardController card) => showAppBottomSheet<void>(
  context,
  label: context.t('securityKeys.openpgp.generate.title'),
  builder: (_) => CardGenerateSheet(card: card),
);

class CardGenerateSheet extends ConsumerStatefulWidget {
  const CardGenerateSheet({super.key, required this.card});

  final OpenPgpCardController card;

  @override
  ConsumerState<CardGenerateSheet> createState() => _CardGenerateSheetState();
}

class _CardGenerateSheetState extends ConsumerState<CardGenerateSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  CardKeyKind? _kind;
  bool _working = false;
  bool _incomplete = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final kinds = widget.card.snapshot == null ? const <CardKeyKind>[] : cardKeyKinds(widget.card.snapshot!);
    _kind = kinds.firstOrNull;
    for (final field in [_name, _email]) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  bool get _overNfc => widget.card.keys.key?.isNfc ?? false;

  Future<void> _generate() async {
    final kind = _kind;
    final snapshot = widget.card.snapshot;
    if (kind == null || snapshot == null || _working) return;
    final String userId;
    try {
      userId = crypto.pgpUserId(_name.text, _email.text);
    } on ArgumentError {
      return;
    }
    final messages = context.messages;
    // A place in use loses its key: said, and confirmed, before anything is sent
    if (CardPlace.values.any(snapshot.data.holdsKey)) {
      final sure = await showConfirmDialog(
        context,
        icon: const Icon(Icons.warning_amber_rounded),
        title: messages.t('securityKeys.openpgp.generate.replace.title'),
        body: Text(messages.t('securityKeys.openpgp.generate.replace.body')),
        confirmLabel: messages.t('securityKeys.openpgp.generate.replace.confirm'),
        cancelLabel: messages.t('export.cancel'),
      );
      if (!sure || !mounted) return;
    }
    if (!await askCardPins(context, widget.card, const [CardPin.admin, CardPin.pin]) || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
      _incomplete = false;
    });
    final now = ref.read(clockProvider)();
    var started = false;
    Uint8List? public;
    CardSnapshot? read;
    try {
      // Only on the card whose places the warning was about
      await widget.card.run((session) async {
        for (final place in CardPlace.values) {
          final wanted = kind.attributes(place);
          final current = session.read.data.attributes[place];
          if (current == null || !kind.matches(place, current)) await session.setAlgorithm(place, wanted);
        }
        for (final place in CardPlace.values) {
          await session.generate(place);
          started = true;
        }
        await session.refresh();
        final packets = await cardKeyPackets(session, missingTime: now, writeMissing: true);
        public = await cardTransferablePublicKey(session, packets, userId: userId, now: now);
        // One test signature, checked as every card signature is
        final digest = Uint8List.fromList(hash.sha512.convert([for (var i = 0; i < 32; i++) Random.secure().nextInt(256)]).bytes);
        await cardSign(session, packets[CardPlace.signature]!, digest);
        read = session.read;
      }, only: snapshot);
    } on SecurityKeyCancelled {
      if (started && mounted) setState(() => _incomplete = true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _incomplete = started;
          _error = started ? null : cardErrorText(context, error);
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
    final key = public;
    final snapshotAfter = read;
    if (key == null || snapshotAfter == null || !mounted) return;
    if (!await crypto.verifyPgpSelfSignatures(key)) {
      if (mounted) setState(() => _error = messages.t('securityKeys.openpgp.use.badSignature'));
      return;
    }
    final vaultKey = cardVaultKey(
      id: newUuid(),
      name: _name.text.trim(),
      publicKey: key,
      snapshot: snapshotAfter,
      origin: KeyOrigin.generated,
    );
    if (await _addCardKey(ref, vaultKey) && mounted) {
      showToast(context, messages.t('securityKeys.openpgp.add.done', {'name': vaultKey.name}));
      Navigator.of(context).pop();
    }
  }

  /// "Finish setting up": the card's new keys get their public key, as
  /// when adding a card's keys to the vault with none at hand.
  Future<void> _finish() async {
    final String userId;
    try {
      userId = crypto.pgpUserId(_name.text, _email.text);
    } on ArgumentError {
      return;
    }
    final messages = context.messages;
    final key = await makeCardKeyPublic(context, ref, widget.card, userId: userId, name: _name.text.trim(), origin: KeyOrigin.generated);
    if (key == null || !mounted) return;
    if (await _addCardKey(ref, key) && mounted) {
      showToast(context, messages.t('securityKeys.openpgp.add.done', {'name': key.name}));
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.card.snapshot;
    final kinds = snapshot == null ? const <CardKeyKind>[] : cardKeyKinds(snapshot);
    final kind = _kind;
    final blockedByNfc = kind != null && kind.needsUsb && _overNfc;
    final ready = kind != null && !blockedByNfc && _name.text.trim().isNotEmpty && _email.text.trim().isNotEmpty && !_working;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.openpgp.generate.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.card.keys),
                if (_incomplete) ...[
                  AppAlert(
                    key: const ValueKey('card-generate-incomplete'),
                    severity: AlertSeverity.warning,
                    child: Text(context.t('securityKeys.openpgp.generate.incomplete')),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey('card-generate-finish'),
                    style: largeButtonStyle,
                    onPressed: _working ? null : () => unawaited(_finish()),
                    child: Text(context.t('securityKeys.openpgp.generate.finish')),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_error != null) ...[AppAlert(severity: AlertSeverity.error, child: Text(_error!)), const SizedBox(height: 12)],
                if (kinds.isEmpty)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.openpgp.generate.none')))
                else ...[
                  // Six kinds do not fit a segmented control's width: a menu, as the vault's Generate sheet has
                  DropdownButtonFormField<CardKeyKind>(
                    key: const ValueKey('card-generate-kind'),
                    isExpanded: true,
                    initialValue: kind ?? kinds.first,
                    decoration: InputDecoration(labelText: context.t('securityKeys.openpgp.generate.kind')),
                    items: [for (final k in kinds) DropdownMenuItem(value: k, child: Text(k.label))],
                    onChanged: (k) => setState(() => _kind = k ?? _kind),
                  ),
                  if (blockedByNfc) ...[
                    const SizedBox(height: 12),
                    AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.openpgp.generate.usbOnly'))),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    key: const ValueKey('card-generate-name'),
                    controller: _name,
                    enabled: !_working,
                    decoration: InputDecoration(labelText: context.t('keys.field.name')),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    key: const ValueKey('card-generate-email'),
                    controller: _email,
                    enabled: !_working,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(labelText: context.t('securityKeys.openpgp.add.email')),
                  ),
                  const SizedBox(height: 14),
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('securityKeys.openpgp.generate.noBackup'))),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('card-generate-button'),
                    style: largeButtonStyle,
                    onPressed: ready ? () => unawaited(_generate()) : null,
                    child: Text(context.t('securityKeys.openpgp.generate.button')),
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
