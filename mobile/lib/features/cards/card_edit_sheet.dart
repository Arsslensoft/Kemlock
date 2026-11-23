import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../i18n/messages.dart';
import '../../models/json.dart';
import '../../models/payment_card.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/tag_input.dart';
import '../lock/gate_widgets.dart';
import '../settings/prefs.dart';
import '../vault/owner_check.dart';
import 'card_number.dart';

/// Opens the sheet that adds a card, or edits [card].
Future<void> showCardEditSheet(BuildContext context, {PaymentCard? card}) => showAppBottomSheet<void>(
  context,
  label: context.t(card == null ? 'cards.new.title' : 'cards.edit.title'),
  builder: (_) => CardEditSheet(card: card),
);

/// Whether [text] is an expiry or "valid from" date people may have typed:
/// empty, or a month and a year ("05/29", "5/2029"), or one of them alone.
bool cardDateOk(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return true;
  final read = parseCardExpiry(trimmed);
  final partsCount = trimmed.split(RegExp(r'[\s/\-.]+')).where((part) => part.isNotEmpty).length;
  return partsCount == 1 && trimmed.length <= 2 ? read.month != null : read.month != null && read.year != null;
}

/// A card's fields: its name, cardholder, number, brand, expiry, security
/// code, PIN, "valid from" date, a note and tags. The number is kept as its
/// digits and a brand is offered from them. Save needs a name and a number or
/// a cardholder, a number of 8 to 19 digits, and dates that read. A number that
/// fails the Luhn check is warned about and still saves.
class CardEditSheet extends ConsumerStatefulWidget {
  const CardEditSheet({super.key, this.card});

  final PaymentCard? card;

  @override
  ConsumerState<CardEditSheet> createState() => _CardEditSheetState();
}

class _CardEditSheetState extends ConsumerState<CardEditSheet> {
  late final _name = TextEditingController(text: widget.card?.name ?? '');
  late final _holder = TextEditingController(text: widget.card?.cardholder ?? '');
  late final _number = TextEditingController(text: groupedCardNumber(widget.card?.number ?? ''));
  late final _expiry = TextEditingController(text: monthYearText(widget.card?.expMonth, widget.card?.expYear) ?? '');
  late final _validFrom = TextEditingController(text: monthYearText(widget.card?.validFromMonth, widget.card?.validFromYear) ?? '');
  late final _code = TextEditingController(text: widget.card?.code ?? '');
  late final _pin = TextEditingController(text: widget.card?.pin ?? '');
  late final _note = TextEditingController(text: widget.card?.note ?? '');
  late var _tags = <String>[...?widget.card?.tags];

  /// The brand the person picked; until they pick one, the brand follows the number.
  late String? _brand = widget.card?.brand;
  late var _brandPicked = widget.card?.brand != null;
  var _showCode = false;
  var _showPin = false;
  var _saving = false;

  List<TextEditingController> get _fields => [_name, _holder, _number, _expiry, _validFrom, _code, _pin, _note];

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  String get _digits => cardDigits(_number.text);

  String? get _effectiveBrand => _brandPicked ? _brand : cardBrandOf(_digits);

  bool get _numberText => isCardNumberText(_number.text);

  bool get _numberLength => _digits.isEmpty || (_digits.length >= cardNumberMinDigits && _digits.length <= cardNumberMaxDigits);

  PaymentCard _draft() {
    String? text(TextEditingController field) => field.text.trim().isEmpty ? null : field.text.trim();
    final expiry = parseCardExpiry(_expiry.text);
    final from = parseCardExpiry(_validFrom.text);
    final base = widget.card ?? PaymentCard(id: newUuid(), name: '', addedAt: 0);
    return base.copyWith(
      name: _name.text.trim(),
      cardholder: text(_holder) ?? unset,
      number: _digits.isEmpty ? unset : _digits,
      brand: _effectiveBrand ?? unset,
      expMonth: expiry.month ?? unset,
      expYear: expiry.year ?? unset,
      // A code and a PIN are kept as typed
      code: _code.text.isEmpty ? unset : _code.text,
      pin: _pin.text.isEmpty ? unset : _pin.text,
      validFromMonth: from.month ?? unset,
      validFromYear: from.year ?? unset,
      note: text(_note) ?? unset,
      tags: _tags.isEmpty ? unset : [..._tags],
    );
  }

  /// Shows or hides the code or PIN. Showing what is saved asks first who it
  /// is when Settings says so, as the card's sheet does; what was just typed shows at once.
  Future<void> _toggle({required bool pin}) async {
    final shown = pin ? _showPin : _showCode;
    final saved = pin ? widget.card?.pin : widget.card?.code;
    final controller = pin ? _pin : _code;
    if (!shown && saved != null && controller.text == saved && ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('cards.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) return;
    }
    setState(() => pin ? _showPin = !shown : _showCode = !shown);
  }

  Future<void> _save(PaymentCard draft) async {
    setState(() => _saving = true);
    final controller = ref.read(vaultControllerProvider.notifier);
    final saved = widget.card == null ? await controller.addCard(draft) : await controller.updateCard(draft);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  Widget _secretField(TextEditingController controller, String labelId, {required bool shown, required bool pin}) => SecretSelection(
    child: TextField(
      enableIMEPersonalizedLearning: false,
      controller: controller,
      obscureText: !shown,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: null,
      keyboardType: TextInputType.number,
      contextMenuBuilder: secretTextMenu,
      style: AppType.mono(),
      decoration: InputDecoration(
        labelText: context.t(labelId),
        suffixIcon: RevealPasswordButton(
          shown: shown,
          onPressed: () => unawaited(_toggle(pin: pin)),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final draft = _draft();
    final numberOk = _numberText && _numberLength;
    final datesOk = cardDateOk(_expiry.text) && cardDateOk(_validFrom.text);
    final incomplete = _name.text.trim().isNotEmpty && !draft.isComplete;
    final changed = widget.card == null || draft != widget.card;
    final luhnWarning = numberOk && _digits.length >= cardNumberMinDigits && !luhnValid(_digits);
    final allTags = {for (final card in ref.watch(vaultControllerProvider.select((state) => state.cards))) ...?card.tags}.toList()..sort();
    final offered = cardBrandOf(_digits);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: const Icon(Icons.credit_card_rounded),
          title: context.t(widget.card == null ? 'cards.new.title' : 'cards.edit.title'),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  autofocus: widget.card == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: context.t('cards.field.name')),
                ),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _holder,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: context.t('cards.field.cardholder')),
                ),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _number,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: null,
                  keyboardType: TextInputType.number,
                  style: AppType.mono(),
                  decoration: InputDecoration(
                    labelText: context.t('cards.field.number'),
                    errorText: !_numberText
                        ? context.t('cards.number.digits')
                        : !_numberLength
                        ? context.t('cards.number.length')
                        : null,
                    errorMaxLines: 3,
                  ),
                ),
                if (luhnWarning) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('cards.number.luhn'))),
                // The brand follows the number until the person picks one
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final brand in cardBrands)
                      ChoiceChip(
                        label: Text(brand),
                        selected: _effectiveBrand == brand,
                        onSelected: (on) => setState(() {
                          _brandPicked = true;
                          _brand = on ? brand : null;
                        }),
                      ),
                  ],
                ),
                if (offered != null && !_brandPicked && _effectiveBrand == offered)
                  Text(
                    context.t('cards.brand.offered', {'brand': offered}),
                    style: AppType.caption.copyWith(color: context.palette.textSecondary),
                  ),
                Row(
                  spacing: 12,
                  children: [
                    Expanded(
                      child: TextField(
                        enableIMEPersonalizedLearning: false,
                        controller: _expiry,
                        keyboardType: TextInputType.datetime,
                        decoration: InputDecoration(
                          labelText: context.t('cards.field.expiry'),
                          hintText: 'MM/YY',
                          errorText: cardDateOk(_expiry.text) ? null : context.t('cards.date.invalid'),
                          errorMaxLines: 2,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        enableIMEPersonalizedLearning: false,
                        controller: _validFrom,
                        keyboardType: TextInputType.datetime,
                        decoration: InputDecoration(
                          labelText: context.t('cards.field.validFrom'),
                          hintText: 'MM/YY',
                          errorText: cardDateOk(_validFrom.text) ? null : context.t('cards.date.invalid'),
                          errorMaxLines: 2,
                        ),
                      ),
                    ),
                  ],
                ),
                _secretField(_code, 'cards.field.code', shown: _showCode, pin: false),
                _secretField(_pin, 'cards.field.pin', shown: _showPin, pin: true),
                if (incomplete) AppAlert(severity: AlertSeverity.info, child: Text(context.t('cards.needsDetail'))),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('cards.field.note'), alignLabelWithHint: true),
                ),
                TagInput(value: _tags, onChanged: (tags) => setState(() => _tags = tags), suggestions: allTags),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: draft.isComplete && numberOk && datesOk && changed && !_saving ? () => unawaited(_save(draft)) : null,
                  child: Text(context.t('cards.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
