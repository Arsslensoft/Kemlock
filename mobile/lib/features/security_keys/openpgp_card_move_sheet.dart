/// Moving a vault PGP key onto an OpenPGP card (openspec:
/// add-openpgp-card, design decision 12): which part goes where, shown
/// first; the choice to keep a copy in the vault, and what is lost without
/// one; the key's own passphrase; the move and its proofs; and, without a
/// copy, the vault's entry becoming the card key under the same id.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' show readPgpKeyInfo;
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/security_keys.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../security_key/openpgp_card/card_data.dart';
import '../../security_key/openpgp_card/card_move.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../export/export_sheet.dart';
import '../keys/card_keys.dart';
import '../pgp/pgp_widgets.dart' show askPgpPassphrase;
import 'key_widgets.dart';
import 'openpgp_card_controller.dart';
import 'openpgp_card_keys_sheets.dart' show askCardPins;
import 'openpgp_card_sheet.dart' show cardErrorText, shortCardFingerprint;

/// Opens the Move sheet of [card].
Future<void> showCardMove(BuildContext context, OpenPgpCardController card) => showAppBottomSheet<void>(
  context,
  label: context.t('securityKeys.openpgp.move.title'),
  builder: (_) => CardMoveSheet(card: card),
);

class CardMoveSheet extends ConsumerStatefulWidget {
  const CardMoveSheet({super.key, required this.card});

  final OpenPgpCardController card;

  @override
  ConsumerState<CardMoveSheet> createState() => _CardMoveSheetState();
}

class _CardMoveSheetState extends ConsumerState<CardMoveSheet> {
  String? _keyId;
  bool _keep = false;
  bool _working = false;
  String? _error;

  /// The vault's PGP keys that hold their secret here.
  List<VaultKey> _movable(List<VaultKey> keys) => [
    for (final key in keys)
      if (key.kind == KeyKind.pgp && !key.isOnCard) key,
  ];

  CardMovePlan? _plan(VaultKey key) {
    final snapshot = widget.card.snapshot;
    if (snapshot == null) return null;
    try {
      return cardMovePlan(unb64(key.privateKey), snapshot, ref.read(clockProvider)());
    } on Object {
      return null;
    }
  }

  Future<void> _move(VaultKey key, CardMovePlan plan) async {
    // The card the plan was made for: its places are written over, and no other card's
    final shown = widget.card.snapshot;
    if (_working || shown == null) return;
    final messages = context.messages;
    final secretKey = unb64(key.privateKey);
    // A key that keeps its own passphrase is opened first: a wrong one sends nothing to the card
    CardMoveSecrets? secrets;
    String? passphraseError;
    while (true) {
      String? passphrase;
      if (key.protected ?? false) {
        passphrase = await askPgpPassphrase(
          context,
          title: messages.t('pgp.keyPassphrase.title', {'name': key.name}),
          body: messages.t('pgp.keyPassphrase.body'),
          error: passphraseError,
        );
        if (passphrase == null || !mounted) return;
      }
      try {
        secrets = CardMoveSecrets.unlock(secretKey, plan, passphrase: passphrase);
        break;
      } on pgp.PgpException catch (e) {
        if (e.problem == pgp.PgpProblem.wrongPassphrase && (key.protected ?? false)) {
          passphraseError = messages.t('pgp.error.wrongKeyPassphrase');
          continue;
        }
        setState(() => _error = messages.t('securityKeys.openpgp.move.incomplete'));
        return;
      }
    }
    if (!await askCardPins(context, widget.card, const [CardPin.admin, CardPin.pin]) || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.card.run((session) => cardImportPlan(session, plan, secrets!.of), only: shown);
    } on CardIncompleteMove {
      if (mounted) setState(() => _error = messages.t('securityKeys.openpgp.move.incomplete'));
      return;
    } on SecurityKeyCancelled {
      return;
    } catch (error) {
      if (mounted) setState(() => _error = cardErrorText(context, error) ?? messages.t('securityKeys.openpgp.move.incomplete'));
      return;
    } finally {
      if (mounted) setState(() => _working = false);
    }
    final snapshot = widget.card.snapshot;
    if (!mounted || snapshot == null) return;
    if (!_keep) {
      // The entry becomes the card key under the same id, last of all, once the card was proved
      final moved = key.movedToCard(
        stub: b64(cardMovedStub(unb64(key.publicKey!), snapshot.aid.bytes, plan)),
        card: cardObject(snapshot.aid.hex, cardMovePlaces(plan)),
        at: ref.read(clockProvider)().millisecondsSinceEpoch,
      );
      if (!await ref.read(vaultControllerProvider.notifier).updateKey(moved) || !mounted) return;
    }
    showToast(context, messages.t(_keep ? 'securityKeys.openpgp.move.copied' : 'securityKeys.openpgp.move.done', {'name': key.name}));
    Navigator.of(context).pop();
  }

  /// The part's kind, named as the card's sheet names it, and its fingerprint.
  String _partText(BuildContext context, String fingerprint, CardAlgorithm algorithm, bool primary) => [
    context.t(primary ? 'securityKeys.openpgp.move.primary' : 'securityKeys.openpgp.move.subkey', {
      'algorithm': cardAlgorithmLabel(algorithm),
    }),
    shortCardFingerprint(fingerprint),
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final keys = _movable(ref.watch(vaultControllerProvider.select((state) => state.keys)));
    final key = keys.firstWhereOrNull((k) => k.id == _keyId) ?? keys.firstOrNull;
    final plan = key == null ? null : _plan(key);
    final primaryFingerprint = key == null || key.publicKey == null ? null : readPgpKeyInfo(unb64(key.publicKey!)).primary.fingerprintHex;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.openpgp.move.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.card.keys),
                if (_error != null) ...[
                  AppAlert(key: const ValueKey('card-move-error'), severity: AlertSeverity.error, child: Text(_error!)),
                  const SizedBox(height: 12),
                ],
                if (key == null)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.openpgp.move.none')))
                else ...[
                  Group(
                    label: context.t('securityKeys.openpgp.move.choose'),
                    children: [
                      for (final (i, k) in keys.indexed)
                        GroupRow(
                          key: ValueKey('card-move-key-${k.id}'),
                          first: i == 0,
                          icon: const Text('PGP'),
                          primary: k.name,
                          value: k.id == key.id ? const Icon(Icons.check_rounded) : null,
                          onTap: _working || keys.length == 1 ? null : () => setState(() => _keyId = k.id),
                        ),
                    ],
                  ),
                  Group(
                    label: context.t('securityKeys.openpgp.move.plan'),
                    children: [
                      if (plan == null || !plan.fits)
                        GroupRow(
                          key: const ValueKey('card-move-cannot'),
                          first: true,
                          muted: true,
                          primary: context.t('securityKeys.openpgp.move.cannotHold'),
                        )
                      else
                        for (final (i, MapEntry(key: place, value: (packet, algorithm))) in plan.parts.entries.indexed)
                          GroupRow(
                            key: ValueKey('card-move-place-${place.name}'),
                            first: i == 0,
                            icon: Text(place.letter),
                            primary: context.t('securityKeys.openpgp.place.${place.name}'),
                            secondary: _partText(
                              context,
                              cardHex(packet.fingerprint),
                              algorithm,
                              cardHex(packet.fingerprint) == primaryFingerprint,
                            ),
                            secondaryStyle: AppType.mono(fontSize: 12),
                          ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Group(
                    children: [
                      GroupRow(
                        key: const ValueKey('card-move-keep'),
                        first: true,
                        primary: context.t('securityKeys.openpgp.move.keep'),
                        control: AppSwitch(value: _keep, onChanged: _working ? null : (keep) => setState(() => _keep = keep)),
                      ),
                    ],
                  ),
                  if (!_keep) ...[
                    const SizedBox(height: 12),
                    AppAlert(
                      key: const ValueKey('card-move-warning'),
                      severity: AlertSeverity.warning,
                      child: Text(context.t('securityKeys.openpgp.move.warning')),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const ValueKey('card-move-export'),
                      onPressed: _working ? null : () => unawaited(showExportSheet(context)),
                      child: Text(context.t('securityKeys.openpgp.move.export')),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey('card-move-button'),
                    style: largeButtonStyle,
                    onPressed: plan == null || !plan.fits || _working ? null : () => unawaited(_move(key, plan)),
                    child: Text(context.t(_keep ? 'securityKeys.openpgp.move.copyButton' : 'securityKeys.openpgp.move.button')),
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
