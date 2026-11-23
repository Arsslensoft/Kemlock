import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../i18n/messages.dart';
import '../../models/identity.dart';
import '../../models/json.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/tag_input.dart';
import '../lock/gate_widgets.dart';
import '../settings/prefs.dart';
import '../vault/owner_check.dart';
import 'countries.dart';
import 'identity_sheet.dart' show documentTypeId;

/// Opens the sheet that adds an identity, or edits [identity].
Future<void> showIdentityEditSheet(BuildContext context, {Identity? identity}) => showAppBottomSheet<void>(
  context,
  label: context.t(identity == null ? 'identities.new.title' : 'identities.edit.title'),
  builder: (_) => IdentityEditSheet(identity: identity),
);

/// Whether [text] is empty or a calendar date written `yyyy-mm-dd`.
bool identityDateOk(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return true;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) return false;
  final date = DateTime.tryParse(trimmed);
  return date != null &&
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}' == trimmed;
}

/// The fields of one document being edited.
class _DocumentDraft {
  _DocumentDraft(IdentityDocument? document)
    : id = document?.id ?? newUuid(),
      original = document,
      type = document?.type ?? IdentityDocumentType.passport.wire,
      number = TextEditingController(text: document?.number ?? ''),
      country = TextEditingController(text: document?.issuingCountry ?? ''),
      authority = TextEditingController(text: document?.issuingAuthority ?? ''),
      issuedOn = TextEditingController(text: document?.issuedOn ?? ''),
      expiresOn = TextEditingController(text: document?.expiresOn ?? '');

  final String id;
  final IdentityDocument? original;
  String type;
  final TextEditingController number;
  final TextEditingController country;
  final TextEditingController authority;
  final TextEditingController issuedOn;
  final TextEditingController expiresOn;
  var shown = false;

  List<TextEditingController> get fields => [number, country, authority, issuedOn, expiresOn];

  bool get datesOk => identityDateOk(issuedOn.text) && identityDateOk(expiresOn.text);

  /// A document needs a number.
  bool get isComplete => number.text.trim().isNotEmpty;

  IdentityDocument toDocument() {
    String? text(TextEditingController field) => field.text.trim().isEmpty ? null : field.text.trim();
    final base = original ?? IdentityDocument(id: id, number: '');
    return base.copyWith(
      type: type,
      number: number.text.trim(),
      issuingCountry: text(country) == null ? unset : countryStored(country.text),
      issuingAuthority: text(authority) ?? unset,
      issuedOn: text(issuedOn) ?? unset,
      expiresOn: text(expiresOn) ?? unset,
    );
  }

  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
  }
}

/// An identity's fields: its name, the person's name parts, company, email,
/// phone, username and birth date, one address, its documents, a note and
/// tags. Save needs a name and at least one detail, and dates that read.
class IdentityEditSheet extends ConsumerStatefulWidget {
  const IdentityEditSheet({super.key, this.identity});

  final Identity? identity;

  @override
  ConsumerState<IdentityEditSheet> createState() => _IdentityEditSheetState();
}

class _IdentityEditSheetState extends ConsumerState<IdentityEditSheet> {
  late final _fields = <String, TextEditingController>{
    'name': TextEditingController(text: widget.identity?.name ?? ''),
    'title': TextEditingController(text: widget.identity?.title ?? ''),
    'given': TextEditingController(text: widget.identity?.givenName ?? ''),
    'middle': TextEditingController(text: widget.identity?.middleName ?? ''),
    'family': TextEditingController(text: widget.identity?.familyName ?? ''),
    'company': TextEditingController(text: widget.identity?.company ?? ''),
    'email': TextEditingController(text: widget.identity?.email ?? ''),
    'phone': TextEditingController(text: widget.identity?.phone ?? ''),
    'username': TextEditingController(text: widget.identity?.username ?? ''),
    'birth': TextEditingController(text: widget.identity?.birthDate ?? ''),
    'line1': TextEditingController(text: widget.identity?.address?.lines?.elementAtOrNull(0) ?? ''),
    'line2': TextEditingController(text: widget.identity?.address?.lines?.elementAtOrNull(1) ?? ''),
    'line3': TextEditingController(text: widget.identity?.address?.lines?.elementAtOrNull(2) ?? ''),
    'city': TextEditingController(text: widget.identity?.address?.city ?? ''),
    'region': TextEditingController(text: widget.identity?.address?.region ?? ''),
    'postal': TextEditingController(text: widget.identity?.address?.postalCode ?? ''),
    'country': TextEditingController(),
    'note': TextEditingController(text: widget.identity?.note ?? ''),
  };
  late final _documents = [for (final document in widget.identity?.documents ?? const <IdentityDocument>[]) _DocumentDraft(document)];
  late var _tags = <String>[...?widget.identity?.tags];
  var _saving = false;
  var _countryReady = false;

  TextEditingController _f(String key) => _fields[key]!;

  @override
  void initState() {
    super.initState();
    for (final field in _fields.values) {
      field.addListener(() => setState(() {}));
    }
    for (final draft in _documents) {
      _listen(draft);
    }
  }

  void _listen(_DocumentDraft draft) {
    for (final field in draft.fields) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final draft in _documents) {
      draft.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _showCountries(Localizations.localeOf(context).languageCode);
  }

  /// Shows the stored country codes as the countries' names, once the language is known.
  void _showCountries(String language) {
    if (_countryReady) return;
    _countryReady = true;
    final stored = widget.identity?.address?.country;
    if (stored != null) _f('country').text = countryLabel(stored, language);
    for (final draft in _documents) {
      final code = draft.original?.issuingCountry;
      if (code != null) draft.country.text = countryLabel(code, language);
    }
  }

  Identity _draft() {
    String? text(String key) => _f(key).text.trim().isEmpty ? null : _f(key).text.trim();
    final lines = [
      for (final key in ['line1', 'line2', 'line3']) ?text(key),
    ];
    final country = text('country') == null ? null : countryStored(_f('country').text);
    final base = widget.identity;
    final address = IdentityAddress(
      lines: lines.isEmpty ? null : lines,
      city: text('city'),
      region: text('region'),
      postalCode: text('postal'),
      country: country,
      extra: base?.address?.extra ?? const {},
    );
    final documents = [for (final draft in _documents) draft.toDocument()];
    return (base ?? Identity(id: newUuid(), name: '', addedAt: 0)).copyWith(
      name: _f('name').text.trim(),
      title: text('title') ?? unset,
      givenName: text('given') ?? unset,
      middleName: text('middle') ?? unset,
      familyName: text('family') ?? unset,
      company: text('company') ?? unset,
      email: text('email') ?? unset,
      phone: text('phone') ?? unset,
      username: text('username') ?? unset,
      birthDate: text('birth') ?? unset,
      address: address.isEmpty ? unset : address,
      documents: documents.isEmpty ? unset : documents,
      note: text('note') ?? unset,
      tags: _tags.isEmpty ? unset : [..._tags],
    );
  }

  Future<void> _toggleNumber(_DocumentDraft draft) async {
    final saved = draft.original?.number;
    if (!draft.shown && saved != null && draft.number.text == saved && ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('identities.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) return;
    }
    setState(() => draft.shown = !draft.shown);
  }

  Future<void> _save(Identity draft) async {
    setState(() => _saving = true);
    final controller = ref.read(vaultControllerProvider.notifier);
    final saved = widget.identity == null ? await controller.addIdentity(draft) : await controller.updateIdentity(draft);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  Widget _text(
    String key,
    String labelId, {
    TextInputType? type,
    TextCapitalization capitalization = TextCapitalization.none,
    bool autofocus = false,
  }) => TextField(
    enableIMEPersonalizedLearning: false,
    controller: _f(key),
    autofocus: autofocus,
    keyboardType: type,
    textCapitalization: capitalization,
    decoration: InputDecoration(labelText: context.t(labelId)),
  );

  /// A country field with the countries its text matches, to pick one as its code.
  Widget _countryField(TextEditingController controller, String labelId, String language) {
    final options = searchCountries(controller.text, language);
    final exact = options.length == 1 && options.single.name(language).toLowerCase() == controller.text.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: controller,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: context.t(labelId)),
        ),
        if (options.isNotEmpty && !exact)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 8,
              children: [
                for (final country in options)
                  ActionChip(
                    label: Text(country.name(language)),
                    onPressed: () => setState(() => controller.text = country.name(language)),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _documentEditor(int index, _DocumentDraft draft, String language) => Container(
    key: ValueKey('document-draft:${draft.id}'),
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        Row(
          children: [
            Expanded(child: SectionLabel(context.t('identities.documentN', {'number': index + 1}))),
            IconButton(
              tooltip: context.t('identities.documentRemove'),
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() {
                _documents.remove(draft);
                draft.dispose();
              }),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final type in IdentityDocumentType.values)
              ChoiceChip(
                label: Text(context.t(documentTypeId(type))),
                selected:
                    IdentityDocumentType.fromWire(draft.type) == type && (draft.type == type.wire || type == IdentityDocumentType.other),
                onSelected: (_) => setState(() => draft.type = type.wire),
              ),
          ],
        ),
        SecretSelection(
          child: TextField(
            enableIMEPersonalizedLearning: false,
            controller: draft.number,
            obscureText: !draft.shown,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: null,
            contextMenuBuilder: secretTextMenu,
            style: AppType.mono(),
            decoration: InputDecoration(
              labelText: context.t('identities.field.documentNumber'),
              suffixIcon: RevealPasswordButton(shown: draft.shown, onPressed: () => unawaited(_toggleNumber(draft))),
            ),
          ),
        ),
        _countryField(draft.country, 'identities.field.issuingCountry', language),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: draft.authority,
          decoration: InputDecoration(labelText: context.t('identities.field.issuingAuthority')),
        ),
        Row(
          spacing: 12,
          children: [
            Expanded(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: draft.issuedOn,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: context.t('identities.field.issuedOn'),
                  hintText: 'yyyy-mm-dd',
                  errorText: identityDateOk(draft.issuedOn.text) ? null : context.t('identities.date.invalid'),
                  errorMaxLines: 2,
                ),
              ),
            ),
            Expanded(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: draft.expiresOn,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: context.t('identities.field.expiresOn'),
                  hintText: 'yyyy-mm-dd',
                  errorText: identityDateOk(draft.expiresOn.text) ? null : context.t('identities.date.invalid'),
                  errorMaxLines: 2,
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final draft = _draft();
    final incomplete = _f('name').text.trim().isNotEmpty && !draft.isComplete;
    final datesOk = identityDateOk(_f('birth').text) && _documents.every((document) => document.datesOk && document.isComplete);
    final changed = widget.identity == null || draft != widget.identity;
    final allTags = {for (final other in ref.watch(vaultControllerProvider.select((state) => state.identities))) ...?other.tags}.toList()
      ..sort();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: const Icon(Icons.badge_outlined),
          title: context.t(widget.identity == null ? 'identities.new.title' : 'identities.edit.title'),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                _text('name', 'identities.field.name', capitalization: TextCapitalization.words, autofocus: widget.identity == null),
                _text('title', 'identities.field.title', capitalization: TextCapitalization.words),
                _text('given', 'identities.field.givenName', capitalization: TextCapitalization.words),
                _text('middle', 'identities.field.middleName', capitalization: TextCapitalization.words),
                _text('family', 'identities.field.familyName', capitalization: TextCapitalization.words),
                _text('company', 'identities.field.company', capitalization: TextCapitalization.words),
                _text('email', 'identities.field.email', type: TextInputType.emailAddress),
                _text('phone', 'identities.field.phone', type: TextInputType.phone),
                _text('username', 'identities.field.username'),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _f('birth'),
                  keyboardType: TextInputType.datetime,
                  decoration: InputDecoration(
                    labelText: context.t('identities.field.birthDate'),
                    hintText: 'yyyy-mm-dd',
                    errorText: identityDateOk(_f('birth').text) ? null : context.t('identities.date.invalid'),
                    errorMaxLines: 2,
                  ),
                ),
                SectionLabel(context.t('identities.address')),
                _text('line1', 'identities.field.addressLine1', capitalization: TextCapitalization.words),
                _text('line2', 'identities.field.addressLine2', capitalization: TextCapitalization.words),
                _text('line3', 'identities.field.addressLine3', capitalization: TextCapitalization.words),
                _text('city', 'identities.field.city', capitalization: TextCapitalization.words),
                _text('region', 'identities.field.region', capitalization: TextCapitalization.words),
                _text('postal', 'identities.field.postalCode'),
                _countryField(_f('country'), 'identities.field.country', language),
                SectionLabel(context.t('identities.documents')),
                for (final (i, document) in _documents.indexed) _documentEditor(i, document, language),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: () => setState(() {
                      final added = _DocumentDraft(null);
                      _listen(added);
                      _documents.add(added);
                    }),
                    child: Text(context.t('identities.documentAdd')),
                  ),
                ),
                if (incomplete) AppAlert(severity: AlertSeverity.info, child: Text(context.t('identities.needsDetail'))),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _f('note'),
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('identities.field.note'), alignLabelWithHint: true),
                ),
                TagInput(value: _tags, onChanged: (tags) => setState(() => _tags = tags), suggestions: allTags),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: draft.isComplete && datesOk && changed && !_saving ? () => unawaited(_save(draft)) : null,
                  child: Text(context.t('identities.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
