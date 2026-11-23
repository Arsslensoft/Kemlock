import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/generated_password.dart';
import '../../models/login.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../lock/password_strength.dart';
import 'generator.dart';
import 'word_list.dart';

/// Where the generator's last choices are kept: on this phone, for every
/// vault, never synced. `{"kind": "random" | "passphrase", "random": {…},
/// "passphrase": {…}}`.
const keyGenerator = 'backmycodes_generator';

enum GeneratorKind { random, passphrase }

/// Opens the generator; gives back the password picked with "Use this
/// password", or null when the sheet is dismissed.
Future<String?> showGeneratorSheet(BuildContext context) =>
    showAppBottomSheet<String>(context, label: context.t('generator.title'), builder: (_) => const GeneratorSheet());

/// The password generator (openspec: password-generator; the approved
/// mockup `PasswordGenerator`): the password in large characters with its
/// digits and symbols coloured, how strong it is, Again and Copy; Random or
/// Passphrase and their choices; and "Use this password". Below, the
/// passwords AutoFill generated that no saved login holds (openspec:
/// password-autofill), each with its site and date, Copy and "Save as login".
class GeneratorSheet extends ConsumerStatefulWidget {
  const GeneratorSheet({super.key});

  @override
  ConsumerState<GeneratorSheet> createState() => _GeneratorSheetState();
}

class _GeneratorSheetState extends ConsumerState<GeneratorSheet> {
  final _source = SecureByteSource();
  var _kind = GeneratorKind.random;
  var _random = const PasswordChoices();
  var _passphrase = const PassphraseChoices();
  var _value = '';

  @override
  void initState() {
    super.initState();
    try {
      final stored = jsonDecode(ref.read(keyValueStoreProvider).getItem(keyGenerator) ?? '{}') as Map<String, Object?>;
      _kind = stored['kind'] == 'passphrase' ? GeneratorKind.passphrase : GeneratorKind.random;
      if (stored['random'] case final Map<String, Object?> random) _random = PasswordChoices.fromJson(random);
      if (stored['passphrase'] case final Map<String, Object?> passphrase) _passphrase = PassphraseChoices.fromJson(passphrase);
    } catch (_) {
      // Choices a later version wrote, or none: the defaults
    }
    _make();
  }

  void _remember() => ref
      .read(keyValueStoreProvider)
      .setItem(keyGenerator, jsonEncode({'kind': _kind.name, 'random': _random.toJson(), 'passphrase': _passphrase.toJson()}));

  /// A new password with the choices now; a passphrase waits for the word list.
  void _make() {
    if (_kind == GeneratorKind.random) {
      _value = generatePassword(_source, _random);
      return;
    }
    final words = ref.read(wordListProvider).value;
    _value = words == null ? '' : generatePassphrase(_source, words, _passphrase);
  }

  void _change(void Function() update) {
    setState(() {
      update();
      _make();
    });
    _remember();
  }

  Future<void> _copy([String? password]) async {
    if (await ref.read(secretClipboardProvider).copy(password ?? _value) && mounted) {
      ref.read(toastsProvider.notifier).show(context.t('logins.copied.password'));
    }
  }

  /// Adds a generated password as a login named after its site, which
  /// takes it off the list; the toast says it was added.
  Future<void> _saveAsLogin(GeneratedPassword item) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final login = Login(
      id: newUuid(),
      name: item.site ?? context.t('generator.recent.unnamed'),
      password: item.password,
      websites: item.site == null ? null : [item.site!],
      addedAt: 0,
    );
    if (await controller.addLogin(login)) await controller.deleteGenerated(item);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    // The words load once; the first passphrase is made when they are there
    ref.listen(wordListProvider, (_, next) {
      if (next.hasValue && _kind == GeneratorKind.passphrase && _value.isEmpty) setState(_make);
    });
    // Newest first; one a login holds already is saved, and isn't listed
    final logins = ref.watch(vaultControllerProvider.select((state) => state.logins));
    final held = {for (final login in logins) ?login.password};
    final recent = [
      for (final item in ref.watch(vaultControllerProvider.select((state) => state.generated)).reversed)
        if (!held.contains(item.password)) item,
    ];
    final locale = Localizations.localeOf(context).toLanguageTag();
    String date(int ms) => DateFormat.MMMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(ms));

    Widget toggle(String id, bool value, ValueChanged<bool> onChanged, {String? detailId}) => GroupRow(
      primary: context.t(id),
      secondary: detailId == null ? null : context.t(detailId),
      control: Semantics(
        label: context.t(id),
        child: AppSwitch(value: value, onChanged: onChanged),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.casino_outlined), title: context.t('generator.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                GroupCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 10, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 10,
                      children: [
                        Semantics(
                          liveRegion: true,
                          label: _value,
                          child: ExcludeSemantics(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  for (final c in _value.split(''))
                                    TextSpan(
                                      text: c,
                                      style: TextStyle(
                                        color: RegExp(r'\d').hasMatch(c)
                                            ? b.accentText
                                            : RegExp('[A-Za-z]').hasMatch(c) || c == ' '
                                            ? p.text
                                            : p.warning,
                                      ),
                                    ),
                                ],
                              ),
                              style: AppType.mono().copyWith(fontSize: 22, height: 1.35),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _value.isEmpty ? '' : context.t(strengthIds[strengthLevel(_value)]),
                                style: AppType.caption.copyWith(color: strengthColor(context, _value)),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => setState(_make),
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: Text(context.t('generator.again')),
                            ),
                            TextButton(onPressed: _value.isEmpty ? null : () => unawaited(_copy()), child: Text(context.t('logins.copy'))),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SegmentedControl<GeneratorKind>(
                  options: [
                    SegmentOption(value: GeneratorKind.random, label: context.t('generator.kind.random')),
                    SegmentOption(value: GeneratorKind.passphrase, label: context.t('generator.kind.passphrase')),
                  ],
                  value: _kind,
                  onChanged: (kind) => _change(() => _kind = kind),
                  semanticLabel: context.t('generator.kind.label'),
                ),
                if (_kind == GeneratorKind.random) ...[
                  _Count(
                    labelId: 'generator.length',
                    value: _random.length,
                    min: minPasswordLength,
                    max: maxPasswordLength,
                    onChanged: (length) => _change(() => _random = _random.copyWith(length: length)),
                  ),
                  Group(
                    children: [
                      GroupRow(
                        first: true,
                        primary: context.t('generator.capitals'),
                        secondary: 'A–Z',
                        control: Semantics(
                          label: context.t('generator.capitals'),
                          child: AppSwitch(
                            value: _random.capitals,
                            onChanged: (on) => _change(() => _random = _random.copyWith(capitals: on)),
                          ),
                        ),
                      ),
                      toggle(
                        'generator.digits',
                        _random.digits,
                        (on) => _change(() => _random = _random.copyWith(digits: on)),
                        detailId: 'generator.digits.detail',
                      ),
                      toggle(
                        'generator.symbols',
                        _random.symbols,
                        (on) => _change(() => _random = _random.copyWith(symbols: on)),
                        detailId: 'generator.symbols.detail',
                      ),
                      toggle(
                        'generator.lookAlikes',
                        _random.avoidLookAlikes,
                        (on) => _change(() => _random = _random.copyWith(avoidLookAlikes: on)),
                        detailId: 'generator.lookAlikes.detail',
                      ),
                    ],
                  ),
                ] else ...[
                  _Count(
                    labelId: 'generator.words',
                    value: _passphrase.words,
                    min: minPassphraseWords,
                    max: maxPassphraseWords,
                    onChanged: (words) => _change(() => _passphrase = _passphrase.copyWith(words: words)),
                  ),
                  SegmentedControl<String>(
                    options: [
                      SegmentOption(value: '-', label: context.t('generator.separator.dash')),
                      SegmentOption(value: ' ', label: context.t('generator.separator.space')),
                      SegmentOption(value: '.', label: context.t('generator.separator.dot')),
                      SegmentOption(value: '_', label: context.t('generator.separator.underscore')),
                    ],
                    value: _passphrase.separator,
                    onChanged: (separator) => _change(() => _passphrase = _passphrase.copyWith(separator: separator)),
                    semanticLabel: context.t('generator.separator'),
                    size: SegmentSize.small,
                  ),
                  Group(
                    children: [
                      GroupRow(
                        first: true,
                        primary: context.t('generator.capitalise'),
                        control: Semantics(
                          label: context.t('generator.capitalise'),
                          child: AppSwitch(
                            value: _passphrase.capitalise,
                            onChanged: (on) => _change(() => _passphrase = _passphrase.copyWith(capitalise: on)),
                          ),
                        ),
                      ),
                      toggle('generator.digit', _passphrase.digit, (on) => _change(() => _passphrase = _passphrase.copyWith(digit: on))),
                    ],
                  ),
                ],
                Text(context.t('generator.note'), style: AppType.caption.copyWith(color: b.faint)),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _value.isEmpty ? null : () => Navigator.of(context).pop(_value),
                  child: Text(context.t('generator.use')),
                ),
                if (recent.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SectionLabel(context.t('generator.recent')),
                  Group(
                    children: [
                      for (final (i, item) in recent.indexed)
                        GroupRow(
                          key: ValueKey('generated:${item.at}:${item.site}'),
                          first: i == 0,
                          primary: item.site ?? context.t('generator.recent.app'),
                          secondary: context.t('generator.recent.at', {'date': date(item.at)}),
                          control: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: context.t('logins.copy.password'),
                                icon: const Icon(Icons.copy_rounded, size: 20),
                                onPressed: () => unawaited(_copy(item.password)),
                              ),
                              TextButton(onPressed: () => unawaited(_saveAsLogin(item)), child: Text(context.t('generator.recent.save'))),
                            ],
                          ),
                        ),
                    ],
                  ),
                  Text(context.t('generator.recent.note'), style: AppType.caption.copyWith(color: b.faint)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A count with its value and a slider: a password's length, a passphrase's words.
class _Count extends StatelessWidget {
  const _Count({required this.labelId, required this.value, required this.min, required this.max, required this.onChanged});

  final String labelId;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GroupCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(context.t(labelId), style: AppType.body1.copyWith(color: p.text)),
                ),
                Text('$value', style: AppType.mono().copyWith(fontSize: 17, color: p.text)),
              ],
            ),
            Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min,
              label: '$value',
              semanticFormatterCallback: (v) =>
                  context.t(labelId == 'generator.length' ? 'generator.length.value' : 'generator.words.value', {'count': v.round()}),
              onChanged: (v) => onChanged(v.round()),
            ),
          ],
        ),
      ),
    );
  }
}
