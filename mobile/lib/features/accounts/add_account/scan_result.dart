import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/now.dart';
import '../../../i18n/messages.dart';
import '../../../models/otp_account.dart';
import '../../../ui/ui.dart';
import '../../import/importers.dart';
import '../otp.dart';
import '../service_tile.dart';
import 'manual_form.dart';

/// The account a QR code held, with its live code, its settings as chips,
/// and a way to scan again: `ScanResult` in `AddAccountDialog.tsx`.
class ScanResult extends ConsumerWidget {
  const ScanResult({super.key, required this.account, required this.onRescan});

  final OtpAccount account;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final b = context.bmc;
    final nowSec = ref.watch(nowSecondsProvider);
    final name = account.issuer.isNotEmpty ? account.issuer : account.label;
    final type = account.kind;
    return _ResultCard(
      children: [
        _FoundBadge(context.t('addAccount.scan.success')),
        const SizedBox(height: 12),
        Row(
          children: [
            ServiceTile(name: name, size: 48),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.h5.copyWith(color: p.text),
                  ),
                  if (account.issuer.isNotEmpty && account.label.isNotEmpty)
                    Text(
                      account.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body2.copyWith(color: p.textSecondary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatCode(codeAt(account, nowSec)),
                  style: AppType.mono(fontSize: 22, fontWeight: FontWeight.w500, color: p.text),
                ),
                Text(context.t('addAccount.currentCode'), style: AppType.caption.copyWith(color: b.faint)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (type != OtpType.totp) _Chip(otpTypeName(type)),
            if (type != OtpType.steam) ...[
              _Chip(algorithmName(account.algorithm)),
              _Chip(context.t('addAccount.digitsValue', {'digits': account.digits})),
            ],
            _Chip(
              type == OtpType.hotp
                  ? context.t('addAccount.counterValue', {'counter': account.counter ?? 0})
                  : context.t('accountSheet.secondsShort', {'seconds': account.period}),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _ScanAgain(onPressed: onRescan),
      ],
    );
  }
}

/// The accounts a Google Authenticator "Transfer accounts" QR code held:
/// `MigrationResult` in `AddAccountDialog.tsx`.
class MigrationResult extends StatelessWidget {
  const MigrationResult({super.key, required this.result, required this.onRescan});

  final ForeignImport result;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _ResultCard(
      children: [
        _FoundBadge(context.t('addAccount.migration.found', {'count': result.accounts.length})),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final account in result.accounts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      ServiceTile(name: account.issuer.isNotEmpty ? account.issuer : account.label, size: 36),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              account.issuer.isNotEmpty ? account.issuer : account.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: fontSans,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                height: 1.5,
                                color: p.text,
                              ),
                            ),
                            if (account.issuer.isNotEmpty && account.label.isNotEmpty)
                              Text(
                                account.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontFamily: fontSans, fontSize: 12.5, height: 1.5, color: p.textSecondary),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (result.skipped > 0) ...[
          const SizedBox(height: 8),
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('import.skipped', {'count': result.skipped}))),
        ],
        const SizedBox(height: 8),
        Text(context.t('addAccount.migration.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
        const SizedBox(height: 8),
        _ScanAgain(onPressed: onRescan),
      ],
    );
  }
}

/// The card a result sits on, rising into place a moment after the code is found.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Rise(
    duration: const Duration(milliseconds: 550),
    delay: const Duration(milliseconds: 150),
    curve: Ease.sheet,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.palette.paper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: context.bmc.line2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
}

/// The Azure pill with a check that says what was found.
class _FoundBadge extends StatelessWidget {
  const _FoundBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        height: 26,
        padding: const EdgeInsets.only(left: 7, right: 10),
        decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(13)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(child: Icon(Icons.check_rounded, size: 14, color: b.accentText)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, color: b.accentText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small outlined pill in Geist Mono: the type, algorithm, digits and period of a scanned account.
class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    height: 26,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: context.bmc.line2),
    ),
    // As wide as its text, not as the row.
    child: Center(
      widthFactor: 1,
      child: Text(text, style: AppType.mono(fontSize: 11, color: context.palette.textSecondary)),
    ),
  );
}

class _ScanAgain extends StatelessWidget {
  const _ScanAgain({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: context.palette.textSecondary),
    child: Text(context.t('addAccount.scan.again')),
  );
}
