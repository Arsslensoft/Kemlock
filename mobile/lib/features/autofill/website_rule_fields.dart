import 'package:flutter/material.dart';

import '../../core/public_suffixes.dart';
import '../../core/website_input.dart';
import '../../core/website_rules.dart';
import '../../i18n/messages.dart';
import '../../models/website_rule.dart';
import '../../ui/ui.dart';
import 'website_hints.dart';

/// The copy's message id for the name of the rule [match], a [WebsiteMatch]
/// number or null for Default.
String websiteRuleId(int? match) => switch (match) {
  null => 'websiteRules.rule.default',
  WebsiteMatch.baseDomain => 'websiteRules.rule.baseDomain',
  WebsiteMatch.host => 'websiteRules.rule.host',
  WebsiteMatch.exact => 'websiteRules.rule.exact',
  WebsiteMatch.never => 'websiteRules.rule.never',
  WebsiteMatch.startsWith => 'websiteRules.rule.startsWith',
  WebsiteMatch.regularExpression => 'websiteRules.rule.regularExpression',
  _ => 'websiteRules.rule.unknown',
};

/// The copy's message id for why a pattern is refused.
String patternRefusalId(PatternRefusal refusal) => switch (refusal) {
  PatternRefusal.tooLong => 'websiteRules.refusal.tooLong',
  PatternRefusal.backReference => 'websiteRules.refusal.backReference',
  PatternRefusal.lookaround => 'websiteRules.refusal.lookaround',
  PatternRefusal.wordBoundary => 'websiteRules.refusal.wordBoundary',
  PatternRefusal.unicodeProperty => 'websiteRules.refusal.unicodeProperty',
  PatternRefusal.flags => 'websiteRules.refusal.flags',
  PatternRefusal.repeatTooBig => 'websiteRules.refusal.repeatTooBig',
  PatternRefusal.tooLarge => 'websiteRules.refusal.tooLarge',
  PatternRefusal.syntax => 'websiteRules.refusal.syntax',
};

/// What one website's fields hold: its address as typed, its rule, and the
/// address the test box was given. A website that was there stays exactly as it
/// was read until the person changes its address or rule, so a URI or an
/// unknown rule read from elsewhere is kept, and a pattern the engine refuses
/// doesn't stop Save until it is edited.
class WebsiteRuleController extends ChangeNotifier {
  WebsiteRuleController([this.original]) : address = TextEditingController(text: original?.uri ?? ''), _match = original?.match {
    address.addListener(notifyListeners);
    probe.addListener(notifyListeners);
  }

  /// The website these fields started from, null for a new one.
  final WebsiteRule? original;

  /// The address, host or pattern as typed.
  final TextEditingController address;

  /// The address the test box of a regular expression is given.
  final TextEditingController probe = TextEditingController();

  int? _match;

  /// The rule, a [WebsiteMatch] number, null for Default.
  int? get match => _match;

  set match(int? next) {
    if (next == _match) return;
    _match = next;
    notifyListeners();
  }

  /// Whether nothing is typed.
  bool get isEmpty => address.text.trim().isEmpty;

  /// Whether the website that was there has neither its address nor its rule changed.
  bool get untouched => original != null && address.text == original!.uri && _match == original!.match;

  /// What the typed text makes of the address under the rule now picked.
  WebsiteInput get input => websiteInput(_match, address.text);

  /// Why the pattern is refused, when what is typed is a Regular expression that can't be run.
  PatternRefusal? get refusal => untouched ? null : input.refusal;

  /// Whether this is a pattern read from elsewhere that the engine refuses: kept, and filling nowhere.
  bool get cantBeChecked => untouched && _match == WebsiteMatch.regularExpression && patternRefusal(original!.uri) != null;

  /// The website these fields make: the one that was there while it is untouched, else
  /// one made from the text. Null when nothing is typed or the text can't be one.
  WebsiteRule? get rule {
    final was = original;
    if (untouched) return was!.uri.isEmpty ? null : was;
    final uri = input.uri;
    if (uri == null) return null;
    if (was == null) return WebsiteRule(uri, match: _match);
    // Bitwarden's checksum of a URI is of the one it read
    final extra = <String, Object?>{...was.extra};
    if (was.uri != uri) extra.remove('uriChecksum');
    return WebsiteRule(uri, match: _match, extra: extra);
  }

  /// Whether Save may go on: nothing is typed, or what is typed makes a website.
  bool get isValid => isEmpty || rule != null;

  @override
  void dispose() {
    address.dispose();
    probe.dispose();
    super.dispose();
  }
}

/// The websites [rows] make, in order and without one twice.
List<WebsiteRule> websiteRulesOf(Iterable<WebsiteRuleController> rows) {
  final rules = <WebsiteRule>[];
  for (final row in rows) {
    final rule = row.rule;
    if (rule != null && !rules.contains(rule)) rules.add(rule);
  }
  return rules;
}

const _defaultCode = -1;
const _advancedCode = -2;

/// One website of a login or code: its address, the rule picker with Starts with
/// and Regular expression under Advanced, the hint of where it fills (the
/// add-cards-identities-and-websites plan, design decision 8), Bitwarden's warning
/// for the two advanced rules, and for a Regular expression the test box.
///
/// [label] names the address field; [onRemove], when given, puts a remove button in
/// it. An address the rule can't take is refused as it is typed, unless
/// [showErrors] is false.
class WebsiteRuleFields extends StatelessWidget {
  const WebsiteRuleFields({
    super.key,
    required this.controller,
    required this.kind,
    required this.label,
    this.suffixes,
    this.autofocus = false,
    this.onRemove,
    this.onSubmitted,
    this.showErrors = true,
  });

  final WebsiteRuleController controller;

  /// What the website is held on, which decides how phones fill a Default website.
  final WebsiteKind kind;
  final String label;
  final PublicSuffixList? suffixes;
  final bool autofocus;
  final VoidCallback? onRemove;
  final VoidCallback? onSubmitted;
  final bool showErrors;

  String _hint(int? match) => switch (match) {
    WebsiteMatch.startsWith || WebsiteMatch.exact => 'https://intranet.example.co/login',
    WebsiteMatch.regularExpression => r'^https://([a-z]+\.)?example\.co/',
    _ => 'example.com',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final p = context.palette;
      final b = context.bmc;
      final match = controller.match;
      final input = controller.input;
      final invalid = !controller.isEmpty && !controller.untouched && input.uri == null;
      final refusal = controller.refusal;
      final errorText = !showErrors || !invalid ? null : context.t(refusal == null ? 'websiteDialog.invalid' : patternRefusalId(refusal));
      final rule = controller.rule;
      final pattern = match == WebsiteMatch.regularExpression;
      final unknown = match != null && (match < WebsiteMatch.baseDomain || match > WebsiteMatch.never);
      final shared = rule == null ? null : sharedHostNote(context.t, rule);
      final probe = controller.probe.text;
      // A pattern that runs, to test addresses on
      final testable = pattern && !controller.cantBeChecked ? rule : null;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: controller.address,
            autofocus: autofocus,
            autocorrect: false,
            enableSuggestions: false,
            // Null, not the empty default: the phone's password manager neither fills nor saves a site's sign-in typed here
            autofillHints: null,
            keyboardType: pattern ? TextInputType.text : TextInputType.url,
            textInputAction: onSubmitted == null ? null : TextInputAction.done,
            onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
            decoration: InputDecoration(
              labelText: label,
              hintText: _hint(match),
              errorText: errorText,
              errorMaxLines: 3,
              suffixIcon: onRemove == null
                  ? null
                  : IconButton(
                      tooltip: context.t('websiteRules.remove'),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: onRemove,
                    ),
            ),
          ),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: match ?? _defaultCode,
            decoration: InputDecoration(labelText: context.t('websiteRules.rule.label')),
            items: [
              for (final basic in const <int?>[null, WebsiteMatch.baseDomain, WebsiteMatch.host, WebsiteMatch.exact, WebsiteMatch.never])
                DropdownMenuItem<int>(value: basic ?? _defaultCode, child: Text(context.t(websiteRuleId(basic)))),
              DropdownMenuItem<int>(
                value: _advancedCode,
                enabled: false,
                child: Text(context.t('websiteRules.rule.advanced').toUpperCase(), style: AppType.caption.copyWith(color: b.faint)),
              ),
              for (final advanced in const [WebsiteMatch.startsWith, WebsiteMatch.regularExpression])
                DropdownMenuItem<int>(value: advanced, child: Text(context.t(websiteRuleId(advanced)))),
              if (match != null && unknown)
                DropdownMenuItem<int>(value: match, enabled: false, child: Text(context.t(websiteRuleId(match)))),
            ],
            onChanged: (value) => controller.match = value == null || value == _defaultCode || value == _advancedCode ? null : value,
          ),
          if (rule != null)
            Text(
              websiteHint(context.t, rule, kind, suffixes: suffixes),
              style: AppType.caption.copyWith(color: b.faint),
            ),
          if (shared != null) Text(shared, style: AppType.caption.copyWith(color: b.faint)),
          if (match == WebsiteMatch.startsWith || pattern)
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('websiteRules.warning'))),
          if (controller.cantBeChecked)
            AppAlert(
              severity: AlertSeverity.info,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.t('websiteRules.cantCheck'), style: AppType.body2.copyWith(fontWeight: FontWeight.w600)),
                  Text(context.t('websiteRules.cantCheck.body')),
                ],
              ),
            ),
          if (pattern) ...[
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: controller.probe,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: null,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: context.t('websiteRules.test.label'), hintText: 'https://shop.example.co/cart'),
            ),
            if (testable != null && probe.isNotEmpty)
              Text(
                context.t(fillsOn(testable, probe) ? 'websiteRules.test.matches' : 'websiteRules.test.noMatch'),
                style: AppType.body2.copyWith(color: fillsOn(testable, probe) ? p.success : p.textSecondary, fontWeight: FontWeight.w600),
              ),
            Text(context.t('websiteRules.test.phones'), style: AppType.caption.copyWith(color: b.faint)),
          ],
        ],
      );
    },
  );
}
