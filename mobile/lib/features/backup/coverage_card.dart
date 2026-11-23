import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../models/backup_service.dart';
import '../../models/otp_account.dart';
import '../../ui/ui.dart';
import '../accounts/service_tile.dart';
import 'coverage.dart' as rules;

/// How many missing services show before "Show all".
const coveragePreview = 4;

/// Which accounts have backup codes saved, and a way to add the missing
/// ones, `CoverageCard.tsx`. It takes no room without accounts, or when
/// every account is marked as giving no codes.
class CoverageCard extends StatefulWidget {
  const CoverageCard({super.key, required this.accounts, required this.backupServices, required this.onAddCodes, required this.onNoCodes});

  final List<OtpAccount> accounts;
  final List<BackupService> backupServices;

  /// Opens "Add backup codes" for this service.
  final ValueChanged<String> onAddCodes;

  /// Records that a service gives no backup codes.
  final ValueChanged<OtpAccount> onNoCodes;

  @override
  State<CoverageCard> createState() => _CoverageCardState();
}

class _CoverageCardState extends State<CoverageCard> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    if (widget.accounts.isEmpty) return const SizedBox.shrink();

    final coverage = rules.coverage(widget.accounts, widget.backupServices);
    if (coverage.total == 0) return const SizedBox.shrink();
    final missing = coverage.missing;
    final shown = _showAll ? missing : missing.take(coveragePreview).toList();
    final p = context.palette;
    final title = context.t('coverage.title');

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Rise(
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: title,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.paper,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: AppType.body1.copyWith(fontWeight: FontWeight.w600, color: p.text),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.t('coverage.summary', {'covered': coverage.covered, 'total': coverage.total}),
                  style: AppType.body2.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: coverage.covered / coverage.total,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  color: missing.isEmpty ? p.success : p.primary,
                  semanticsLabel: title,
                ),
                for (final account in shown) _MissingRow(account: account, onAddCodes: widget.onAddCodes, onNoCodes: widget.onNoCodes),
                if (missing.length > coveragePreview)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        style: smallButtonStyle,
                        onPressed: () => setState(() => _showAll = !_showAll),
                        child: Text(context.t(_showAll ? 'coverage.showLess' : 'coverage.showAll', {'count': missing.length})),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An account without backup codes: its service, Add codes, and Has none.
class _MissingRow extends StatelessWidget {
  const _MissingRow({required this.account, required this.onAddCodes, required this.onNoCodes});

  final OtpAccount account;
  final ValueChanged<String> onAddCodes;
  final ValueChanged<OtpAccount> onNoCodes;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final service = rules.serviceOf(account);
    final name = service.trim().isEmpty ? context.t('accountCard.unknown') : service;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: Row(
        children: [
          ServiceTile(name: name, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: fontSans, fontSize: 14.5, fontWeight: FontWeight.w500, color: p.text),
            ),
          ),
          TextButton(style: smallButtonStyle, onPressed: () => onAddCodes(name), child: Text(context.t('coverage.add'))),
          Semantics(
            label: context.t('coverage.none.label', {'name': name}),
            excludeSemantics: true,
            button: true,
            child: TextButton(
              style: smallButtonStyle.merge(TextButton.styleFrom(foregroundColor: p.textSecondary)),
              onPressed: () => onNoCodes(account),
              child: Text(context.t('coverage.none')),
            ),
          ),
        ],
      ),
    );
  }
}
