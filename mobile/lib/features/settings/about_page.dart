import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell_page.dart';
import '../../core/build_kind.dart';
import '../../core/project_links.dart';
import '../../i18n/messages.dart';
import '../../platform/links.dart';
import '../../ui/ui.dart';
import 'app_version.dart';

/// The developer, named in About and in the terms.
const developerName = 'Arsslen Idadi';

const _features = [
  (icon: Icons.wifi_off_rounded, titleId: 'app.about.feature.offline', bodyId: 'app.about.feature.offline.desc'),
  (icon: Icons.lock_rounded, titleId: 'app.about.feature.encrypted', bodyId: 'app.about.feature.encrypted.desc'),
  (icon: Icons.fingerprint_rounded, titleId: 'app.about.feature.biometric', bodyId: 'app.about.feature.biometric.desc'),
  (icon: Icons.qr_code_2_rounded, titleId: 'app.about.feature.qr', bodyId: 'app.about.feature.qr.desc'),
];

const _promises = [
  (icon: Icons.privacy_tip_outlined, titleId: 'app.about.privacy.title', bodyId: 'app.about.privacy.body'),
  (icon: Icons.phonelink_lock_outlined, titleId: 'app.about.storage.title', bodyId: 'app.about.storage.body'),
  (icon: Icons.enhanced_encryption_outlined, titleId: 'app.about.postquantum.title', bodyId: 'app.about.postquantum.body'),
];

/// About, `routes/about.tsx`: the mark, the name, the tagline and version,
/// what the app does and what it promises, and the way to the terms. The
/// back button, and the phone's back gesture, go to Settings.
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final b = context.bmc;
    final version = ref.watch(appVersionProvider).value;
    // The name in bold inside the sentence, wherever the language puts it
    final developer = context.t('app.about.developer', {'name': '\u{0}'}).split('\u{0}');

    return BackToSettings(
      child: ShellPage(
        children: [
          ScreenHeader(
            title: context.t('app.settings.section.about'),
            backLabel: context.t('nav.back'),
            onBack: () => context.go('/settings'),
          ),
          const SizedBox(height: 32),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: b.accentSoft, offset: const Offset(0, 12), blurRadius: 32)],
              ),
              child: const BrandMark(size: 72),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(
              context.t('app.title'),
              textAlign: TextAlign.center,
              style: AppType.h2.copyWith(color: p.text),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.t('app.about.tagline'),
            textAlign: TextAlign.center,
            style: AppType.body2.copyWith(color: p.textSecondary),
          ),
          if (version != null) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(13)),
                // As wide as the text: a Container with an alignment would fill the line
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    context.t('settings.version', {'version': version}),
                    style: AppType.mono(fontSize: 11.5, color: b.accentText),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // Which build this is, known without the network (openspec: add-fdroid-release, design decision 12)
          Text(
            context.t(buildKind == BuildKind.free ? 'about.build.free' : 'about.build.store'),
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: developer.first),
                const TextSpan(
                  text: developerName,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                if (developer.length > 1) TextSpan(text: developer.sublist(1).join()),
              ],
            ),
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(color: b.faint),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 0),
            child: Text(
              context.t('app.about.description'),
              textAlign: TextAlign.center,
              style: AppType.body1.copyWith(color: p.textSecondary),
            ),
          ),
          SectionLabel(context.t('app.about.features.title')),
          for (final (i, feature) in _features.indexed)
            _InfoCard(
              icon: feature.icon,
              title: context.t(feature.titleId),
              body: context.t(feature.bodyId),
              delay: Duration(milliseconds: i * 60),
            ),
          SectionLabel(context.t('about.section.promise')),
          for (final (i, promise) in _promises.indexed)
            _InfoCard(
              icon: promise.icon,
              title: context.t(promise.titleId),
              body: context.t(promise.bodyId),
              delay: Duration(milliseconds: 240 + i * 60),
            ),
          SectionLabel(context.t('about.section.credits')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(context.t('about.credits'), style: AppType.caption.copyWith(color: p.textSecondary)),
          ),
          const SizedBox(height: 14),
          GroupCard(
            child: GroupRow(
              first: true,
              icon: const Icon(Icons.verified_outlined),
              primary: context.t('about.build.check'),
              onTap: () => unawaited(ref.read(linkOpenerProvider).open(context, reproducibleBuildsPage)),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: () => context.go('/terms'),
              style: TextButton.styleFrom(foregroundColor: p.textSecondary),
              icon: const Icon(Icons.description_outlined),
              label: Text(context.t('app.terms.title')),
            ),
          ),
        ],
      ),
    );
  }
}

/// A feature or a promise: its icon in a soft Azure tile beside the title
/// and the text, on a paper card that rises in after [delay].
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.title, required this.body, required this.delay});

  final IconData icon;
  final String title;
  final String body;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Rise(
        delay: delay,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.paper,
            border: Border.all(color: p.divider),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, size: 20, color: b.accentText),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppType.body1.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0, color: p.text),
                    ),
                    const SizedBox(height: 2),
                    Text(body, style: AppType.body2.copyWith(color: p.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sends the phone's back gesture on a page pushed from Settings (About,
/// Terms) back to Settings, as the page's own back button does.
class BackToSettings extends StatelessWidget {
  const BackToSettings({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) context.go('/settings');
    },
    child: child,
  );
}
