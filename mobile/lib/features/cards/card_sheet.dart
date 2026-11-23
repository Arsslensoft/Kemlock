import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/payment_card.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../lock/gate_widgets.dart';
import '../settings/prefs.dart';
import '../vault/owner_check.dart';
import 'card_edit_sheet.dart';
import 'card_number.dart';

/// What a hidden security code or PIN shows.
const _dots = '••••';

/// Opens a card from the Vault tab.
Future<void> showCardSheet(BuildContext context, PaymentCard card) => showAppBottomSheet<void>(
  context,
  label: card.name,
  builder: (_) => CardSheet(cardId: card.id),
);

/// A card (the add-cards-identities-and-websites plan): its cardholder, its
/// number showing the last four digits until revealed, its brand and expiry,
/// its security code and PIN hidden until shown, each with Copy through the
/// clipboard that clears itself; a note, Edit and Delete.
class CardSheet extends ConsumerStatefulWidget {
  const CardSheet({super.key, required this.cardId});

  final String cardId;

  @override
  ConsumerState<CardSheet> createState() => _CardSheetState();
}

/// The secrets of a card that can be revealed.
enum _Secret { number, code, pin }

class _CardSheetState extends ConsumerState<CardSheet> {
  final _shown = <_Secret>{};

  Future<void> _copy(String text, String messageId) async {
    if (await ref.read(secretClipboardProvider).copy(text) && mounted) {
      ref.read(toastsProvider.notifier).show(context.t(messageId));
    }
  }

  /// Whether a secret may show: at once, unless Settings asks first who it
  /// is. Copying it asks nothing.
  Future<bool> _mayReveal() async {
    if (!ref.read(prefsProvider).askBeforeSecret) return true;
    final reason = context.t('cards.reveal.confirm');
    return ref.read(ownerCheckProvider)(context, ref, reason);
  }

  Future<void> _toggle(_Secret secret) async {
    if (!_shown.contains(secret) && !await _mayReveal()) return;
    if (mounted) setState(() => _shown.contains(secret) ? _shown.remove(secret) : _shown.add(secret));
  }

  Future<void> _delete(PaymentCard card) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('cards.delete.title'),
      body: Text(context.t('cards.delete.body', {'name': card.name})),
      confirmLabel: context.t('cards.delete.confirm'),
      cancelLabel: context.t('cards.cancel'),
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deleteCard(card);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final card = ref.watch(vaultControllerProvider.select((state) => state.cards.firstWhereOrNull((c) => c.id == widget.cardId)));
    if (card == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('cards.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final mono = AppType.mono();
    final expired = card.isExpired(ref.watch(clockProvider)());
    final number = card.number;
    final expiry = monthYearText(card.expMonth, card.expYear);
    final validFrom = monthYearText(card.validFromMonth, card.validFromYear);

    Widget copyButton(String text, String messageId, String label) =>
        IconButton(tooltip: label, icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () => unawaited(_copy(text, messageId)));

    /// A row for a secret: hidden until shown, with Show and Copy.
    GroupRow secretRow({
      required bool first,
      required IconData icon,
      required String title,
      required String text,
      required String hidden,
      required _Secret secret,
      required String copiedId,
      required String copyLabel,
      String? copyText,
      String? caption,
    }) => GroupRow(
      first: first,
      icon: Icon(icon),
      primary: caption ?? title,
      secondary: _shown.contains(secret) ? text : hidden,
      secondaryStyle: mono,
      secondarySemanticsLabel: _shown.contains(secret) ? null : context.t('cards.hidden'),
      control: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevealPasswordButton(shown: _shown.contains(secret), onPressed: () => unawaited(_toggle(secret))),
          copyButton(copyText ?? text, copiedId, copyLabel),
        ],
      ),
    );

    final rows = <GroupRow Function(bool first)>[
      if (card.cardholder case final holder? when holder.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.person_outline_rounded),
          primary: context.t('cards.cardholder'),
          secondary: holder,
        ),
      if (number != null && number.isNotEmpty)
        (first) => secretRow(
          first: first,
          icon: Icons.credit_card_rounded,
          title: context.t('cards.number'),
          caption: card.brand == null ? null : '${context.t('cards.number')} · ${card.brand}',
          text: groupedCardNumber(number),
          hidden: maskedCardNumber(number),
          secret: _Secret.number,
          copiedId: 'cards.copied.number',
          copyLabel: context.t('cards.copy.number'),
          copyText: number,
        ),
      if (expiry != null)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.event_outlined),
          primary: context.t('cards.expiry'),
          secondary: expired ? '$expiry · ${context.t('cards.expired')}' : expiry,
          secondaryStyle: expired ? TextStyle(color: p.error) : null,
        ),
      if (validFrom != null)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.event_available_outlined),
          primary: context.t('cards.validFrom'),
          secondary: validFrom,
        ),
      if (card.code case final code? when code.isNotEmpty)
        (first) => secretRow(
          first: first,
          icon: Icons.lock_outline_rounded,
          title: context.t('cards.code'),
          text: code,
          hidden: _dots,
          secret: _Secret.code,
          copiedId: 'cards.copied.code',
          copyLabel: context.t('cards.copy.code'),
        ),
      if (card.pin case final pin? when pin.isNotEmpty)
        (first) => secretRow(
          first: first,
          icon: Icons.dialpad_rounded,
          title: context.t('cards.pin'),
          text: pin,
          hidden: _dots,
          secret: _Secret.pin,
          copiedId: 'cards.copied.pin',
          copyLabel: context.t('cards.copy.pin'),
        ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.credit_card_rounded), title: card.name),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rows.isNotEmpty) Group(children: [for (final (i, row) in rows.indexed) row(i == 0)]),
                if (card.note case final note? when note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionLabel(context.t('cards.note')),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
                    child: Text(note, style: AppType.body2.copyWith(color: p.text)),
                  ),
                ],
                if (card.tags case final tags? when tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                    child: Text(tags.join(' · '), style: AppType.caption.copyWith(color: p.textSecondary)),
                  ),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: largeButtonStyle,
                  onPressed: () => unawaited(showCardEditSheet(context, card: card)),
                  child: Text(context.t('cards.edit')),
                ),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t('cards.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(card)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
