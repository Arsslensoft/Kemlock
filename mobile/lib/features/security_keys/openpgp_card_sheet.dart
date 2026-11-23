import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/security_keys.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../security_key/openpgp_card/card_data.dart';
import '../../security_key/openpgp_card/card_operations.dart';
import '../../security_key/openpgp_card/card_session.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../keys/key_standing.dart';
import 'card_pin_change.dart';
import 'key_widgets.dart';
import 'openpgp_card_controller.dart';
import 'openpgp_card_keys_sheets.dart';
import 'openpgp_card_move_sheet.dart';
import 'security_key_controller.dart';

/// What a person is told when talking to the card failed with [error];
/// null for a cancellation.
String? cardErrorText(BuildContext context, Object error) => switch (error) {
  CardWrongPin(:final triesLeft) =>
    '${context.t('securityKeys.pin.wrong')} ${context.t('securityKeys.pin.triesLeft', {'count': triesLeft})}',
  CardPinBlocked(pin: CardPin.admin) => context.t('securityKeys.openpgp.error.adminBlocked'),
  CardPinBlocked(pin: CardPin.resetCode) => context.t('securityKeys.openpgp.error.resetCodeBlocked'),
  CardPinBlocked() => context.t('securityKeys.openpgp.error.pinBlocked'),
  CardKdfUnreadable() => context.t('securityKeys.openpgp.error.kdf'),
  CardTerminated() => context.t('securityKeys.openpgp.terminated'),
  CardNotFound() => context.t('securityKeys.openpgp.error.notFound'),
  CardFormatError() => context.t('securityKeys.openpgp.error.format'),
  CardWrongCard() => context.t('securityKeys.openpgp.error.otherCard'),
  CardError() => context.t('securityKeys.openpgp.error.refused'),
  SecurityKeyNoApplication() => context.t('securityKeys.openpgp.error.noApplication'),
  _ => keyErrorText(context, error),
};

/// The words of the uses of the places of [snapshot] that hold a key,
/// "Sign, decrypt"; "Empty" when none does.
String cardSummary(BuildContext context, CardSnapshot snapshot) {
  final uses = [
    for (final place in CardPlace.values)
      if (snapshot.data.holdsKey(place)) context.t('securityKeys.openpgp.summary.${place.name}'),
  ];
  if (uses.isEmpty) return context.t('securityKeys.openpgp.summary.empty');
  final text = uses.join(', ');
  return '${text[0].toUpperCase()}${text.substring(1)}';
}

/// The "PGP keys" row of the Security key sheet's "Also on this key"
/// group: there only when the key has an OpenPGP card application, and
/// nothing otherwise, so it can sit among the group's other rows. [first] drops the
/// hairline above it.
class OpenPgpKeysRow extends StatelessWidget {
  const OpenPgpKeysRow({super.key, required this.keys, this.first = false});

  final SecurityKeyController keys;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final card = OpenPgpCardController.of(keys);
    if (card == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: card,
      builder: (context, _) {
        if (!card.present) return const SizedBox.shrink();
        final snapshot = card.snapshot;
        final String? summary = card.terminated
            ? context.t('securityKeys.openpgp.summary.terminated')
            : snapshot == null
            ? null
            : cardSummary(context, snapshot);
        return GroupRow(
          key: const ValueKey('openpgp-row'),
          first: first,
          primary: context.t('securityKeys.openpgp.row'),
          // Three uses take two lines rather than pushing the row past its edge
          value: summary == null
              ? null
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 170),
                  child: Text(summary, maxLines: 2, textAlign: TextAlign.end),
                ),
          onTap: keys.busy ? null : () => unawaited(showOpenPgpCardSheet(context, card)),
        );
      },
    );
  }
}

/// Opens the PGP keys sheet of [card].
Future<void> showOpenPgpCardSheet(BuildContext context, OpenPgpCardController card) => showAppBottomSheet<void>(
  context,
  label: context.t('securityKeys.openpgp.title'),
  builder: (_) => OpenPgpCardSheet(card: card),
);

/// The PGP keys on a security key (design decision 15): its three places
/// and what each holds, the codes that protect them, the touch settings
/// when the card reports them, the card's details, and what can be done
/// with it. Opening it reads the card without a PIN, when it was not read
/// before.
class OpenPgpCardSheet extends ConsumerStatefulWidget {
  const OpenPgpCardSheet({super.key, required this.card});

  final OpenPgpCardController card;

  @override
  ConsumerState<OpenPgpCardSheet> createState() => _OpenPgpCardSheetState();
}

class _OpenPgpCardSheetState extends ConsumerState<OpenPgpCardSheet> {
  Object? _error;

  OpenPgpCardController get card => widget.card;

  @override
  void initState() {
    super.initState();
    if (card.snapshot == null && !card.terminated) unawaited(_read());
  }

  Future<void> _read() async {
    try {
      await card.run((session) async {});
    } on SecurityKeyCancelled {
      return;
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      KeySheetHeader(title: context.t('securityKeys.openpgp.title')),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: ListenableBuilder(
            listenable: card,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: card.keys),
                if (_error == null ? null : cardErrorText(context, _error!) case final text?) ...[
                  AppAlert(severity: AlertSeverity.error, child: Text(text)),
                  const SizedBox(height: 12),
                ],
                ..._body(context),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  List<Widget> _body(BuildContext context) {
    final snapshot = card.snapshot;
    if (card.terminated) {
      // A factory reset was cut off: the card answers that it is terminated
      return [
        AppAlert(severity: AlertSeverity.warning, child: Text(context.t('securityKeys.openpgp.terminated'))),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('openpgp-finish-reset'),
          style: largeButtonStyle,
          onPressed: card.keys.busy ? null : () => unawaited(_finishReset()),
          child: Text(context.t('securityKeys.openpgp.reset.finish')),
        ),
      ];
    }
    if (snapshot == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: Spinner()),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
        child: Text(context.t('securityKeys.openpgp.caption'), style: AppType.caption.copyWith(color: context.palette.textSecondary)),
      ),
      Rise(
        child: _Places(snapshot: snapshot, onAdd: (place) => unawaited(_addToVault(place))),
      ),
      Rise(
        delay: const Duration(milliseconds: 60),
        child: _Codes(card: card, snapshot: snapshot),
      ),
      if (snapshot.touch.isNotEmpty)
        Rise(
          delay: const Duration(milliseconds: 120),
          child: _Touch(card: card, snapshot: snapshot),
        ),
      Rise(
        delay: const Duration(milliseconds: 180),
        child: _Details(snapshot: snapshot),
      ),
      const SizedBox(height: 22),
      Rise(
        delay: const Duration(milliseconds: 220),
        child: FilledButton(
          key: const ValueKey('openpgp-generate'),
          style: largeButtonStyle,
          onPressed: card.keys.busy ? null : () => unawaited(showCardGenerate(context, card)),
          child: Text(context.t('securityKeys.openpgp.generate.title')),
        ),
      ),
      const SizedBox(height: 12),
      Rise(
        delay: const Duration(milliseconds: 220),
        child: OutlinedButton(
          key: const ValueKey('openpgp-move'),
          style: largeButtonStyle,
          onPressed: card.keys.busy ? null : () => unawaited(showCardMove(context, card)),
          child: Text(context.t('securityKeys.openpgp.move.title')),
        ),
      ),
      const SizedBox(height: 12),
      // Offered only on a card that says it can be terminated and activated again
      if (snapshot.data.historical?.lifeCycleManagement ?? false)
        Rise(
          delay: const Duration(milliseconds: 240),
          child: FilledButton(
            key: const ValueKey('openpgp-reset'),
            style: largeButtonStyle.merge(filledButtonColors(background: context.palette.error, foreground: context.palette.onError)),
            onPressed: card.keys.busy ? null : () => unawaited(_reset()),
            child: Text(context.t('securityKeys.openpgp.reset.button')),
          ),
        ),
    ];
  }

  /// Erases the card's PGP keys and returns its PINs to the factory ones,
  /// once the person has typed the confirmation word (design decision 13).
  Future<void> _reset() async {
    // The card the warning is about: the reset runs on it and on no other
    final shown = card.snapshot;
    if (shown == null) return;
    final word = context.t('securityKeys.openpgp.reset.word');
    final sure = await showAppDialog<bool>(context, builder: (_) => _ResetConfirm(word: word));
    if (sure != true || !mounted) return;
    try {
      await card.run((session) => session.factoryReset(), only: shown);
      if (mounted) showToast(context, context.t('securityKeys.openpgp.reset.done'));
    } on SecurityKeyCancelled {
      return;
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _finishReset() async {
    try {
      await card.run((session) async {
        if (session.terminated) await session.finishReset();
      });
      if (mounted) showToast(context, context.t('securityKeys.openpgp.reset.done'));
    } on SecurityKeyCancelled {
      return;
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _addToVault(CardPlace place) => showCardAddToVault(context, card);
}

/// What a factory reset erases, and the word to type to start it.
class _ResetConfirm extends StatefulWidget {
  const _ResetConfirm({required this.word});

  final String word;

  @override
  State<_ResetConfirm> createState() => _ResetConfirmState();
}

class _ResetConfirmState extends State<_ResetConfirm> {
  final _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _typed.text.trim() == widget.word;
    return AppDialog(
      semanticLabel: context.t('securityKeys.openpgp.reset.title'),
      heading: DialogHeading(
        icon: const Icon(Icons.warning_amber_rounded),
        title: context.t('securityKeys.openpgp.reset.title'),
        tone: DialogTone.danger,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.t('securityKeys.openpgp.reset.body')),
          const SizedBox(height: 12),
          Text(context.t('securityKeys.openpgp.reset.type', {'word': widget.word})),
          const SizedBox(height: 8),
          TextField(
            enableIMEPersonalizedLearning: false,
            key: const ValueKey('openpgp-reset-word'),
            controller: _typed,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: widget.word),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('export.cancel'))),
        FilledButton(
          key: const ValueKey('openpgp-reset-confirm'),
          style: filledButtonColors(background: context.palette.error, foreground: context.palette.onError),
          onPressed: ready ? () => Navigator.of(context).pop(true) : null,
          child: Text(context.t('securityKeys.openpgp.reset.button')),
        ),
      ],
    );
  }
}

/// The vault key, if any, that holds a key of [fingerprint] (upper-case
/// hexadecimal), as its primary key or a subkey.
VaultKey? vaultKeyWithFingerprint(WidgetRef ref, String fingerprint) {
  final keys = ref.watch(vaultControllerProvider.select((state) => state.keys));
  return keys.firstWhereOrNull((key) {
    if (key.kind != KeyKind.pgp) return false;
    final info = ref.watch(pgpKeyInfoProvider(key.id));
    if (info == null) return false;
    return info.primary.fingerprintHex == fingerprint || info.subkeys.any((subkey) => subkey.fingerprintHex == fingerprint);
  });
}

/// The last 16 digits of [fingerprint], in groups of four.
String shortCardFingerprint(String fingerprint) {
  final end = fingerprint.length <= 16 ? fingerprint : fingerprint.substring(fingerprint.length - 16);
  return [for (var i = 0; i < end.length; i += 4) end.substring(i, i + 4 > end.length ? end.length : i + 4)].join(' ');
}

class _Places extends ConsumerWidget {
  const _Places({required this.snapshot, required this.onAdd});

  final CardSnapshot snapshot;
  final ValueChanged<CardPlace> onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = context.bmc;
    return Group(
      children: [
        for (final (i, place) in CardPlace.values.indexed)
          Builder(
            builder: (context) {
              final holds = snapshot.data.holdsKey(place);
              final algorithm = snapshot.data.attributes[place];
              final fingerprint = snapshot.fingerprintHex(place);
              final usable = algorithm?.usable ?? false;
              final inVault = fingerprint != null && vaultKeyWithFingerprint(ref, fingerprint) != null;
              final Widget? end;
              if (!holds || !usable) {
                end = null;
              } else if (inVault) {
                end = Text(context.t('securityKeys.openpgp.inVault'), style: AppType.caption.copyWith(color: b.accentText));
              } else {
                end = TextButton(onPressed: () => onAdd(place), child: Text(context.t('securityKeys.openpgp.addToVault')));
              }
              return GroupRow(
                key: ValueKey('openpgp-place-${place.name}'),
                first: i == 0,
                icon: Text(place.letter),
                accent: holds && usable,
                muted: !holds,
                primary: context.t('securityKeys.openpgp.place.${place.name}'),
                secondary: !holds
                    ? context.t('securityKeys.openpgp.place.empty')
                    : [
                        [
                          if (algorithm != null) cardAlgorithmLabel(algorithm),
                          if (fingerprint != null) shortCardFingerprint(fingerprint),
                        ].join(' · '),
                        // A kind Kemlock does not sign or decrypt with is named, and said so
                        if (!usable) context.t('securityKeys.openpgp.unusable'),
                      ].join('\n'),
                secondaryStyle: holds ? AppType.mono(fontSize: 12) : null,
                control: end,
              );
            },
          ),
      ],
    );
  }
}

/// The tries left on a PIN, as its row says them.
String cardTriesText(BuildContext context, int tries) =>
    tries == 0 ? context.t('securityKeys.openpgp.blocked') : context.t('securityKeys.pin.triesLeft', {'count': tries});

class _Codes extends StatelessWidget {
  const _Codes({required this.card, required this.snapshot});

  final OpenPgpCardController card;
  final CardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final status = snapshot.pinStatus;
    final busy = card.keys.busy;
    VoidCallback? open(CardPinChange change) => busy ? null : () => unawaited(showCardPinChange(context, card, change));
    // With both PINs blocked and no reset code, nothing but a factory reset is left
    final allBlocked = status.pinTries == 0 && status.adminPinTries == 0 && status.resetCodeTries == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Group(
          label: context.t('securityKeys.openpgp.section.codes'),
          children: [
            GroupRow(
              key: const ValueKey('openpgp-pin'),
              first: true,
              primary: context.t('securityKeys.openpgp.pin'),
              value: Text(cardTriesText(context, status.pinTries)),
              onTap: allBlocked ? null : open(status.pinTries == 0 ? CardPinChange.unblock : CardPinChange.pin),
            ),
            GroupRow(
              key: const ValueKey('openpgp-admin'),
              primary: context.t('securityKeys.openpgp.adminPin'),
              value: Text(cardTriesText(context, status.adminPinTries)),
              onTap: status.adminPinTries == 0 ? null : open(CardPinChange.admin),
            ),
            GroupRow(
              key: const ValueKey('openpgp-reset-code'),
              primary: context.t('securityKeys.openpgp.resetCode'),
              value: Text(status.resetCodeSet ? cardTriesText(context, status.resetCodeTries) : context.t('securityKeys.openpgp.notSet')),
              onTap: status.adminPinTries == 0 ? null : open(CardPinChange.resetCode),
            ),
            GroupRow(
              key: const ValueKey('openpgp-every-signature'),
              primary: context.t('securityKeys.openpgp.everySignature'),
              control: AppSwitch(
                value: status.pinForEverySignature,
                onChanged: busy || status.adminPinTries == 0
                    ? null
                    : (every) => unawaited(runWithCardPin(context, card, (session) => session.setPinForEverySignature(every))),
              ),
            ),
          ],
        ),
        if (allBlocked) ...[
          const SizedBox(height: 12),
          AppAlert(
            key: const ValueKey('openpgp-all-blocked'),
            severity: AlertSeverity.error,
            child: Text(context.t('securityKeys.openpgp.allBlocked')),
          ),
        ],
      ],
    );
  }
}

/// What a touch setting is called.
String touchPolicyText(BuildContext context, TouchPolicy? policy) =>
    context.t('securityKeys.openpgp.touch.${(policy ?? TouchPolicy.off).name}');

class _Touch extends StatelessWidget {
  const _Touch({required this.card, required this.snapshot});

  final OpenPgpCardController card;
  final CardSnapshot snapshot;

  @override
  Widget build(BuildContext context) => Group(
    label: context.t('securityKeys.openpgp.section.touch'),
    children: [
      for (final (i, place) in [...snapshot.touch.keys].indexed)
        Builder(
          builder: (context) {
            final policy = snapshot.touch[place]!.policy;
            // A setting the card will not undo stays as it is
            final fixed = policy?.permanent ?? false;
            return GroupRow(
              key: ValueKey('openpgp-touch-${place.name}'),
              first: i == 0,
              primary: context.t('securityKeys.openpgp.place.${place.name}'),
              value: Text(touchPolicyText(context, policy)),
              onTap: fixed || card.keys.busy || snapshot.pinStatus.adminPinTries == 0
                  ? null
                  : () => unawaited(changeCardTouch(context, card, place, policy)),
            );
          },
        ),
    ],
  );
}

/// Asks which touch setting [place] gets, warns before one the card will
/// not undo, and sets it with the admin PIN.
Future<void> changeCardTouch(BuildContext context, OpenPgpCardController card, CardPlace place, TouchPolicy? current) async {
  final chosen = await showAppBottomSheet<TouchPolicy>(
    context,
    label: context.t('securityKeys.openpgp.place.${place.name}'),
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: sheet.t('securityKeys.openpgp.touch.title', {'place': sheet.t('securityKeys.openpgp.place.${place.name}')})),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Group(
            children: [
              for (final (i, policy) in TouchPolicy.values.indexed)
                GroupRow(
                  key: ValueKey('touch-choice-${policy.name}'),
                  first: i == 0,
                  primary: touchPolicyText(sheet, policy),
                  secondary: policy.permanent ? sheet.t('securityKeys.openpgp.touch.permanent') : null,
                  value: policy == current ? const Icon(Icons.check_rounded) : null,
                  onTap: () => Navigator.of(sheet).pop(policy),
                ),
            ],
          ),
        ),
      ],
    ),
  );
  if (chosen == null || chosen == current || !context.mounted) return;
  if (chosen.permanent) {
    final sure = await showConfirmDialog(
      context,
      icon: const Icon(Icons.warning_amber_rounded),
      title: context.t('securityKeys.openpgp.touch.permanent.title'),
      body: Text(context.t('securityKeys.openpgp.touch.permanent.body')),
      confirmLabel: context.t('securityKeys.openpgp.touch.permanent.confirm'),
      cancelLabel: context.t('export.cancel'),
      danger: true,
    );
    if (!sure || !context.mounted) return;
  }
  await runWithCardPin(context, card, (session) async {
    await session.setTouch(place, chosen);
    await session.refresh();
  });
}

class _Details extends StatelessWidget {
  const _Details({required this.snapshot});

  final CardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final aid = snapshot.aid;
    final maker = cardMakerName(aid.manufacturer);
    final url = snapshot.url;
    final mono = AppType.mono(fontSize: 14, fontWeight: FontWeight.w500);
    return Group(
      label: context.t('securityKeys.openpgp.section.card'),
      children: [
        GroupRow(
          first: true,
          primary: context.t('securityKeys.openpgp.serial'),
          value: Text(aid.groupedSerial, style: mono),
        ),
        GroupRow(
          primary: context.t('securityKeys.openpgp.maker'),
          value: Text(
            maker ??
                context.t('securityKeys.openpgp.maker.unknown', {'code': aid.manufacturer.toRadixString(16).toUpperCase().padLeft(4, '0')}),
          ),
        ),
        GroupRow(primary: context.t('securityKeys.openpgp.version'), value: Text(aid.version)),
        if (snapshot.cardholder case final holder?) GroupRow(primary: context.t('securityKeys.openpgp.holder'), value: Text(holder)),
        if (snapshot.signatureCounter case final counter?)
          GroupRow(primary: context.t('securityKeys.openpgp.counter'), value: Text('$counter')),
        if (url != null)
          GroupRow(
            primary: context.t('securityKeys.openpgp.url'),
            secondary: url,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) showToast(context, context.t('securityKeys.openpgp.url.copied'));
            },
          ),
      ],
    );
  }
}
