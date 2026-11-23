import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../security_key/openpgp_card/card_session.dart';
import '../../ui/ui.dart';
import 'card_pin_forms.dart';
import 'key_widgets.dart';
import 'openpgp_card_controller.dart';
import 'openpgp_card_sheet.dart' show cardErrorText;

/// Runs [action] on [card] with the PINs it needs (openspec:
/// add-openpgp-card, design decision 8): a PIN the connection was not
/// given is asked for, with the tries the card has just reported, and
/// asked again after a wrong one with the tries now left. Returns false
/// when the person gave up, a PIN is blocked or the card failed, which is
/// said in a toast.
Future<bool> runWithCardPin(
  BuildContext context,
  OpenPgpCardController card,
  Future<void> Function(OpenPgpCardSession session) action,
) async {
  while (true) {
    try {
      await card.run(action);
      return true;
    } on CardPinNeeded catch (needed) {
      if (!context.mounted) return false;
      final typed = await showCardPinPrompt(context, pin: needed.pin, triesLeft: needed.triesLeft);
      if (typed == null) return false;
      card.givePin(needed.pin, typed);
    } on CardWrongPin catch (wrong) {
      if (!context.mounted) return false;
      final typed = await showCardPinPrompt(context, pin: wrong.pin, triesLeft: wrong.triesLeft, wrong: true);
      if (typed == null) return false;
      card.givePin(wrong.pin, typed);
    } on SecurityKeyCancelled {
      return false;
    } catch (error) {
      if (context.mounted) {
        final text = cardErrorText(context, error);
        if (text != null) showToast(context, text, severity: ToastSeverity.error);
      }
      return false;
    }
  }
}

/// What a form changes on the card.
enum CardPinChange {
  /// The PIN, given the current one.
  pin,

  /// The admin PIN, given the current one.
  admin,

  /// A new PIN, given the reset code or the admin PIN: what unblocks it.
  unblock,

  /// The reset code, given the admin PIN.
  resetCode,
}

/// Opens the form for [change].
Future<bool> showCardPinChange(BuildContext context, OpenPgpCardController card, CardPinChange change) async =>
    await showAppBottomSheet<bool>(
      context,
      label: context.t('securityKeys.openpgp.change.${change.name}'),
      builder: (_) => CardPinChangeForm(card: card, change: change),
    ) ??
    false;

/// A form that changes one of the card's codes: what proves the person
/// may (the current code, the reset code or the admin PIN), then the new
/// code twice. The lengths and the two entries are checked here, before
/// anything is sent.
class CardPinChangeForm extends StatefulWidget {
  const CardPinChangeForm({super.key, required this.card, required this.change});

  final OpenPgpCardController card;
  final CardPinChange change;

  @override
  State<CardPinChangeForm> createState() => _CardPinChangeFormState();
}

class _CardPinChangeFormState extends State<CardPinChangeForm> {
  final _proof = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  late bool _withResetCode = widget.change == CardPinChange.unblock && (widget.card.snapshot?.pinStatus.resetCodeTries ?? 0) > 0;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    for (final field in [_proof, _next, _again]) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in [_proof, _next, _again]) {
      field.dispose();
    }
    super.dispose();
  }

  /// The code given as proof.
  CardPin get _proofPin => switch (widget.change) {
    CardPinChange.pin => CardPin.pin,
    CardPinChange.unblock when _withResetCode => CardPin.resetCode,
    _ => CardPin.admin,
  };

  /// The code being set.
  CardPin get _newPin => switch (widget.change) {
    CardPinChange.admin => CardPin.admin,
    CardPinChange.resetCode => CardPin.resetCode,
    _ => CardPin.pin,
  };

  int get _minimum => _newPin == CardPin.pin ? 6 : 8;

  int get _maximum {
    final status = widget.card.snapshot?.pinStatus;
    final max = switch (_newPin) {
      CardPin.admin => status?.adminPinMaxLength,
      CardPin.resetCode => status?.resetCodeMaxLength,
      _ => status?.pinMaxLength,
    };
    return max == null || max == 0 ? 127 : max;
  }

  bool get _filled => _proof.text.isNotEmpty && _next.text.isNotEmpty && _again.text.isNotEmpty;

  Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

  Future<void> _submit() async {
    if (!_filled || _sending) return;
    final next = _bytes(_next.text);
    final String? problem = _next.text != _again.text
        ? context.t('securityKeys.pin.mismatch')
        : next.length < _minimum
        ? context.t(_newPin == CardPin.pin ? 'securityKeys.openpgp.rule.pin' : 'securityKeys.openpgp.rule.admin')
        : next.length > _maximum
        ? context.t('securityKeys.openpgp.rule.tooLong', {'count': _maximum})
        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final proof = _bytes(_proof.text);
    final messages = context.messages;
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      await widget.card.run((session) async {
        switch (widget.change) {
          case CardPinChange.pin:
            await session.changePin(CardPin.pin, proof, next);
          case CardPinChange.admin:
            await session.changePin(CardPin.admin, proof, next);
          case CardPinChange.unblock when _withResetCode:
            await session.unblockWithResetCode(proof, next);
          case CardPinChange.unblock:
            session.holdPin(CardPin.admin, proof);
            await session.unblockWithAdmin(next);
          case CardPinChange.resetCode:
            session.holdPin(CardPin.admin, proof);
            await session.setResetCode(next);
        }
      });
      if (!mounted) return;
      showToast(context, messages.t('securityKeys.openpgp.done.${widget.change.name}'));
      Navigator.of(context).pop(true);
    } on CardWrongPin catch (wrong) {
      if (mounted) {
        setState(
          () => _error =
              '${messages.t('securityKeys.openpgp.wrong.${wrong.pin.name}')} ${messages.t('securityKeys.pin.triesLeft', {'count': wrong.triesLeft})}',
        );
      }
    } on SecurityKeyRemoved {
      // The card may have changed it or not: the person is told to try both
      if (mounted) setState(() => _error = messages.t('securityKeys.openpgp.takenAway'));
    } on SecurityKeyCancelled {
      // The form stays as it was
    } catch (error) {
      if (mounted) setState(() => _error = cardErrorText(context, error) ?? messages.t('securityKeys.error.failed'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _field(TextEditingController controller, String label, {String? helper, bool first = false, bool last = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      enableIMEPersonalizedLearning: false,
      controller: controller,
      autofocus: first,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      enabled: !_sending,
      inputFormatters: [LengthLimitingTextInputFormatter(127)],
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onSubmitted: last ? (_) => unawaited(_submit()) : null,
      decoration: InputDecoration(labelText: label, helperText: helper),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final canUseResetCode = change == CardPinChange.unblock && (widget.card.snapshot?.pinStatus.resetCodeTries ?? 0) > 0;
    final proofLabel = switch (_proofPin) {
      CardPin.resetCode => context.t('securityKeys.openpgp.resetCode'),
      CardPin.admin => context.t('securityKeys.openpgp.adminPin'),
      _ => context.t('securityKeys.pin.current'),
    };
    final kind = _newPin.name;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.openpgp.change.${change.name}')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.card.keys),
                if (canUseResetCode) ...[
                  SegmentedControl<bool>(
                    semanticLabel: context.t('securityKeys.openpgp.change.unblock'),
                    semantics: SegmentSemantics.radio,
                    options: [
                      SegmentOption(value: true, label: context.t('securityKeys.openpgp.resetCode')),
                      SegmentOption(value: false, label: context.t('securityKeys.openpgp.adminPin')),
                    ],
                    value: _withResetCode,
                    onChanged: (value) => setState(() {
                      _withResetCode = value;
                      _proof.clear();
                    }),
                  ),
                  const SizedBox(height: 14),
                ],
                if (_error != null) ...[
                  AppAlert(key: const ValueKey('card-pin-error'), severity: AlertSeverity.error, child: Text(_error!)),
                  const SizedBox(height: 14),
                ],
                _field(_proof, proofLabel, first: true),
                _field(
                  _next,
                  context.t('securityKeys.openpgp.field.new.$kind'),
                  helper: context.t(_newPin == CardPin.pin ? 'securityKeys.openpgp.rule.pin' : 'securityKeys.openpgp.rule.admin'),
                ),
                _field(_again, context.t('securityKeys.openpgp.field.again.$kind'), last: true),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                  child: Text(
                    context.t('securityKeys.openpgp.pin.hint'),
                    style: AppType.caption.copyWith(color: context.palette.textSecondary),
                  ),
                ),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _filled && !_sending ? () => unawaited(_submit()) : null,
                  child: Text(context.t('securityKeys.openpgp.change.${change.name}')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
