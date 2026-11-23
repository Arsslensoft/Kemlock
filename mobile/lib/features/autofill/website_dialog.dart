import 'package:flutter/material.dart';

import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../i18n/messages.dart';
import '../../models/website_rule.dart';
import '../../ui/ui.dart';
import 'website_rule_fields.dart';

/// Asks for a website and its rule, or changes [rule]'s, and gives back the
/// website as Kemlock keeps it, or null when the person cancels. The address
/// the rule can't take is refused in the field, with why, and Add waits for one
/// it can ([kind] is what the website is held on; see [WebsiteRuleFields]).
Future<WebsiteRule?> showWebsiteRuleDialog(
  BuildContext context, {
  required WebsiteKind kind,
  WebsiteRule? rule,
  PublicSuffixList? suffixes,
}) => showAppDialog<WebsiteRule>(
  context,
  builder: (_) => _WebsiteRuleDialog(kind: kind, rule: rule, suffixes: suffixes),
);

class _WebsiteRuleDialog extends StatefulWidget {
  const _WebsiteRuleDialog({required this.kind, this.rule, this.suffixes});

  final WebsiteKind kind;
  final WebsiteRule? rule;
  final PublicSuffixList? suffixes;

  @override
  State<_WebsiteRuleDialog> createState() => _WebsiteRuleDialogState();
}

class _WebsiteRuleDialogState extends State<_WebsiteRuleDialog> {
  late final _fields = WebsiteRuleController(widget.rule)..addListener(() => setState(() {}));

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  void _done() {
    final rule = _fields.rule;
    if (rule != null) Navigator.of(context).pop(rule);
  }

  @override
  Widget build(BuildContext context) {
    final adding = widget.rule == null;
    final title = context.t(adding ? 'websiteDialog.title' : 'websiteRules.edit.title');
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.public_rounded), title: title),
      content: SingleChildScrollView(
        child: WebsiteRuleFields(
          controller: _fields,
          kind: widget.kind,
          label: context.t('websiteDialog.field'),
          suffixes: widget.suffixes,
          autofocus: true,
          onSubmitted: _done,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('websiteDialog.cancel'))),
        FilledButton(
          onPressed: _fields.rule == null ? null : _done,
          child: Text(context.t(adding ? 'websiteDialog.add' : 'websiteRules.edit.save')),
        ),
      ],
    );
  }
}
