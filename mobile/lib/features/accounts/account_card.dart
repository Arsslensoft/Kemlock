import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/now.dart';
import '../../i18n/messages.dart';
import '../../models/otp_account.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import 'account_sheet.dart';
import 'otp.dart';
import 'service_tile.dart';

/// One account in the list, `AccountCard.tsx`: a tap on the row copies the
/// code, the chevron opens the detail sheet. The code turns to the warning
/// colour in its last five seconds and previews the next one; an account
/// whose period isn't the shared 30 seconds gets its own small ring. An
/// HOTP account has a button for its next code.
class AccountCard extends ConsumerStatefulWidget {
  const AccountCard({
    super.key,
    required this.account,
    required this.onDelete,
    required this.onUpdate,
    this.onCopied,
    this.index = 0,
    this.divider = false,
    this.allTags = const [],
  });

  final OtpAccount account;
  final ValueChanged<String> onDelete;
  final ValueChanged<OtpAccount> onUpdate;

  /// Called after the code lands on the clipboard.
  final ValueChanged<OtpAccount>? onCopied;

  /// Position in the list, for the staggered entrance.
  final int index;

  /// Draw a hairline above the row.
  final bool divider;

  /// Tags on all accounts, suggested when editing this one.
  final List<String> allTags;

  @override
  ConsumerState<AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<AccountCard> {
  final _copied = Flash(const Duration(milliseconds: 1600));

  @override
  void dispose() {
    _copied.dispose();
    super.dispose();
  }

  void _openSheet() => showAccountSheet(
    context,
    account: widget.account,
    allTags: widget.allTags,
    onDelete: widget.onDelete,
    onUpdate: widget.onUpdate,
    onCopied: widget.onCopied,
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final account = widget.account;
    final nowSec = ref.watch(nowSecondsProvider);
    final reduced = Motion.reduced(context);
    final timeBased = isTimeBased(account);
    final remaining = remainingIn(nowSec, account.period);
    final urgent = timeBased && remaining <= 5;
    final code = codeAt(account, nowSec);
    final name = accountTitle(context, account);
    final subLabel = account.issuer.isNotEmpty ? account.label : '';

    Future<void> copy() async {
      if (!await ref.read(secretClipboardProvider).copy(code)) return;
      _copied.trigger();
      widget.onCopied?.call(account);
    }

    return Rise(
      duration: const Duration(milliseconds: 550),
      delay: Duration(milliseconds: widget.index * 45 + 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.divider) Container(height: 1, margin: const EdgeInsets.only(left: 72, right: 14), color: p.divider),
          ValueListenableBuilder<bool>(
            valueListenable: _copied,
            builder: (context, copied, _) {
              final showNext = urgent && !copied;
              return AnimatedContainer(
                duration: reduced ? Duration.zero : const Duration(milliseconds: 450),
                curve: Ease.standard,
                decoration: BoxDecoration(
                  color: copied ? b.accentSoft : b.accentSoft.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: PressScale(
                        scale: 0.985,
                        child: Semantics(
                          container: true,
                          button: true,
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              onTap: copy,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                                child: Row(
                                  children: [
                                    ServiceTile(name: name),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontFamily: fontSans,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: -0.15,
                                              height: 1.4,
                                              color: p.text,
                                            ),
                                          ),
                                          if (subLabel.isNotEmpty)
                                            Text(
                                              subLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontFamily: fontSans, fontSize: 13, height: 1.4, color: p.textSecondary),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (timeBased && account.period != 30) ...[
                                              CountdownRing(remaining: remaining, period: account.period, size: 18, stroke: 2),
                                              const SizedBox(width: 8),
                                            ],
                                            CodeDigits(
                                              code: code,
                                              style: TextStyle(
                                                // 8-digit codes run smaller so the name keeps some room
                                                fontSize: codeLength(account) == 8 ? 19 : 22,
                                                color: urgent ? p.warning : p.text,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        SizedBox(
                                          height: 14,
                                          child: Stack(
                                            alignment: Alignment.centerRight,
                                            clipBehavior: Clip.none,
                                            children: [
                                              _Slot(
                                                visible: showNext,
                                                from: -4,
                                                child: showNext
                                                    ? Text(
                                                        context.t('accountCard.next', {'code': formatCode(codeAt(account, nowSec, 1))}),
                                                        maxLines: 1,
                                                        softWrap: false,
                                                        style: AppType.mono(fontSize: 11, color: b.faint).copyWith(height: 14 / 11),
                                                      )
                                                    : const SizedBox.shrink(),
                                              ),
                                              _Slot(
                                                visible: copied,
                                                from: 4,
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.check_rounded, size: 13, color: b.accentText),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      context.t('accountCard.tooltip.copied'),
                                                      maxLines: 1,
                                                      softWrap: false,
                                                      style: TextStyle(
                                                        fontFamily: fontSans,
                                                        fontSize: 11,
                                                        height: 14 / 11,
                                                        fontWeight: FontWeight.w600,
                                                        color: b.accentText,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!timeBased)
                      _SideButton(
                        tooltip: context.t('accountCard.hotpNext', {'name': name}),
                        icon: Icons.refresh_rounded,
                        color: b.accentText,
                        height: 44,
                        onPressed: () => widget.onUpdate(account.copyWith(counter: (account.counter ?? 0) + 1)),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _SideButton(
                        tooltip: context.t('accountCard.details', {'name': name}),
                        icon: Icons.chevron_right_rounded,
                        color: b.faint,
                        height: 60,
                        onPressed: _openSheet,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The "next" preview or the "Copied!" label under the code, fading and
/// sliding in when [visible]; only a visible one is read out.
class _Slot extends StatelessWidget {
  const _Slot({required this.visible, required this.from, required this.child});

  final bool visible;

  /// Where the label sits while hidden, in pixels above (negative) or below.
  final double from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return ExcludeSemantics(
      excluding: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: visible ? 0 : from),
          duration: reduced ? Duration.zero : const Duration(milliseconds: 350),
          curve: Ease.roll,
          builder: (context, dy, child) => Transform.translate(offset: Offset(0, dy), child: child),
          child: child,
        ),
      ),
    );
  }
}

/// The narrow buttons at the row's right: HOTP's next code and the chevron.
class _SideButton extends StatelessWidget {
  const _SideButton({required this.tooltip, required this.icon, required this.color, required this.height, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final Color color;
  final double height;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => PressScale(
    scale: 0.94,
    child: IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: color,
        fixedSize: Size(36, height),
        minimumSize: Size(36, height),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Icon(icon),
    ),
  );
}
