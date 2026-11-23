import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/shell_page.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'about_page.dart';

/// When the terms last changed.
final termsUpdated = DateTime(2026, 11, 23);

const _termsSections = [
  (titleId: 'app.terms.s1.title', bodyId: 'app.terms.s1.body'),
  (titleId: 'app.terms.s2.title', bodyId: 'app.terms.s2.body'),
  (titleId: 'app.terms.s3.title', bodyId: 'app.terms.s3.body'),
  (titleId: 'app.terms.s4.title', bodyId: 'app.terms.s4.body'),
  (titleId: 'app.terms.s5.title', bodyId: 'app.terms.s5.body'),
  (titleId: 'app.terms.s6.title', bodyId: 'app.terms.s6.body'),
  (titleId: 'app.terms.s7.title', bodyId: 'app.terms.s7.body'),
];

const _privacySections = [
  (titleId: 'app.privacy.s1.title', bodyId: 'app.privacy.s1.body'),
  (titleId: 'app.privacy.s2.title', bodyId: 'app.privacy.s2.body'),
  (titleId: 'app.privacy.s3.title', bodyId: 'app.privacy.s3.body'),
  (titleId: 'app.privacy.s4.title', bodyId: 'app.privacy.s4.body'),
  (titleId: 'app.privacy.s5.title', bodyId: 'app.privacy.s5.body'),
];

/// The terms of use and the privacy policy, `routes/terms.tsx`. The back
/// button, and the phone's back gesture, go to Settings.
class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final updated = DateFormat.yMMMMd(Localizations.localeOf(context).toLanguageTag()).format(termsUpdated);
    return BackToSettings(
      child: ShellPage(
        children: [
          ScreenHeader(title: context.t('app.terms.title'), backLabel: context.t('nav.back'), onBack: () => context.go('/settings')),
          const SizedBox(height: 24),
          Text(context.t('app.terms.lastUpdated', {'date': updated}), style: AppType.caption.copyWith(color: b.faint)),
          const SizedBox(height: 8),
          Text(context.t('app.terms.intro'), style: AppType.body1.copyWith(color: p.textSecondary)),
          _Heading(icon: Icons.gavel_rounded, text: context.t('app.terms.section.terms')),
          const _SectionList(sections: _termsSections),
          _Heading(icon: Icons.privacy_tip_outlined, text: context.t('app.terms.section.privacy')),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(context.t('app.privacy.intro'), style: AppType.body1.copyWith(color: p.textSecondary)),
          ),
          const _SectionList(sections: _privacySections),
          const SizedBox(height: 24),
          Text(
            context.t('app.terms.contact', {'name': developerName}),
            textAlign: TextAlign.center,
            style: AppType.body2.copyWith(color: b.faint),
          ),
        ],
      ),
    );
  }
}

/// The Azure heading of a part, its icon before it.
class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colour = context.bmc.accentText;
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 12),
      child: Row(
        children: [
          ExcludeSemantics(child: Icon(icon, size: 20, color: colour)),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text.toUpperCase(), style: AppType.overline.copyWith(color: colour)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A paper card of numbered sections, a hairline between them.
class _SectionList extends StatelessWidget {
  const _SectionList({required this.sections});

  final List<({String titleId, String bodyId})> sections;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: p.paper,
        border: Border.all(color: p.divider),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, section) in sections.indexed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: i == 0
                  ? null
                  : BoxDecoration(
                      border: Border(top: BorderSide(color: p.divider)),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(context.t(section.titleId), style: AppType.h6.copyWith(color: p.text)),
                  ),
                  const SizedBox(height: 6),
                  Text(context.t(section.bodyId), style: AppType.body2.copyWith(height: 1.7, color: p.textSecondary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
