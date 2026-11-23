import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/messages.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';

/// The most tries a card's PIN has: the count shown is the one below it.
const cardFullTries = 3;

/// The title of the prompt for [pin].
String cardPinTitle(BuildContext context, CardPin pin) => switch (pin) {
  CardPin.admin => context.t('securityKeys.openpgp.adminPin'),
  CardPin.resetCode => context.t('securityKeys.openpgp.resetCode'),
  _ => context.t('securityKeys.pin.prompt.title'),
};

/// Asks for [pin] of a card (openspec: add-openpgp-card, design decision
/// 8): titled by its purpose, with the tries left when below the full
/// count, a warning at one try left, and the hint that names the factory
/// PINs. After a [wrong] PIN it says so. Resolves to what was typed, as
/// UTF-8, or null when the person backs out.
Future<Uint8List?> showCardPinPrompt(BuildContext context, {required CardPin pin, required int triesLeft, bool wrong = false}) =>
    showAppBottomSheet<Uint8List>(
      context,
      label: cardPinTitle(context, pin),
      builder: (_) => CardPinPrompt(pin: pin, triesLeft: triesLeft, wrong: wrong),
    );

class CardPinPrompt extends StatefulWidget {
  const CardPinPrompt({super.key, required this.pin, required this.triesLeft, this.wrong = false});

  final CardPin pin;
  final int triesLeft;
  final bool wrong;

  @override
  State<CardPinPrompt> createState() => _CardPinPromptState();
}

class _CardPinPromptState extends State<CardPinPrompt> {
  final _field = TextEditingController();

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    if (_field.text.isEmpty) return;
    Navigator.of(context).pop(Uint8List.fromList(utf8.encode(_field.text)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tries = widget.triesLeft;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: cardPinTitle(context, widget.pin)),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(context.t('securityKeys.openpgp.pin.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                if (widget.wrong || tries < cardFullTries) ...[
                  const SizedBox(height: 14),
                  AppAlert(
                    key: const ValueKey('card-pin-tries'),
                    severity: widget.wrong || tries <= 1 ? AlertSeverity.error : AlertSeverity.warning,
                    child: Text(
                      [
                        if (widget.wrong) context.t('securityKeys.pin.wrong'),
                        context.t('securityKeys.pin.triesLeft', {'count': tries}),
                        if (tries == 1) context.t('securityKeys.openpgp.pin.lastTry'),
                      ].join(' '),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _field,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [LengthLimitingTextInputFormatter(127)],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(labelText: cardPinTitle(context, widget.pin)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                  child: Text(context.t('securityKeys.openpgp.pin.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _field.text.isEmpty ? null : _submit,
                  child: Text(context.t('securityKeys.pin.continue')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
