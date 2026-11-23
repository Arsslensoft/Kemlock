import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/now.dart';
import '../../i18n/messages.dart';
import '../../models/key_account.dart';
import '../../ui/ui.dart';
import '../accounts/otp.dart';
import '../security_keys/key_codes.dart';
import '../security_keys/key_codes_flow.dart';
import 'key_account_sheet.dart';

/// One account kept on a security key, in the Codes tab (openspec:
/// add-security-key-codes, decisions 5, 7 and 11). It is laid out as an
/// `AccountCard`, with its tile in the accent colour.
///
/// While a code read from the key is valid, a tap copies it. Once it has
/// run out the row keeps its name, shows no code and says the key must be
/// read again; a tap then starts a read and copies nothing. An account the
/// key guards with a touch says so and offers "Tap key"; a counter-based
/// one has a button for its next code.
class KeyAccountCard extends ConsumerStatefulWidget {
  const KeyAccountCard({super.key, required this.account, this.index = 0, this.divider = false, this.allTags = const []});

  final KeyAccount account;

  /// Position in the list, for the staggered entrance.
  final int index;

  /// Draw a hairline above the row.
  final bool divider;

  /// Tags on all accounts, suggested when editing this one.
  final List<String> allTags;

  @override
  ConsumerState<KeyAccountCard> createState() => _KeyAccountCardState();
}

class _KeyAccountCardState extends ConsumerState<KeyAccountCard> {
  final _copied = Flash(const Duration(milliseconds: 1600));

  @override
  void dispose() {
    _copied.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final account = widget.account;
    final nowSec = ref.watch(nowSecondsProvider);
    final codes = ref.watch(keyCodesProvider.select((state) => state.codes[account.id]));
    final counterCode = ref.watch(keyCodesProvider.select((state) => state.counterCodes[account.id]));
    final reduced = Motion.reduced(context);
    final name = keyAccountTitle(context, account);

    KeyCode? fresh;
    KeyCode? next;
    for (final code in codes ?? const <KeyCode>[]) {
      if (code.from <= nowSec && nowSec < code.until) fresh = code;
      if (code.from > nowSec) next ??= code;
    }
    final timeBased = account.isTimeBased;
    final code = timeBased ? fresh?.code : counterCode;
    final remaining = fresh == null ? 0 : fresh.until - nowSec;
    final urgent = fresh != null && remaining <= 5;
    // Without a code: a touch is asked for when the key guards the account, the key is read otherwise.
    final needsTouch = timeBased && code == null && account.touch;

    final String subLabel;
    if (needsTouch) {
      subLabel = context.t('keyCodes.touch');
    } else if (code == null) {
      subLabel = context.t(timeBased ? 'keyCodes.stale' : 'keyCodes.counter');
    } else {
      subLabel = account.issuer.isNotEmpty ? account.label : '';
    }

    Future<void> act() async {
      final shown = code;
      if (shown != null) {
        if (await copyKeyCode(context, ref, account, shown)) _copied.trigger();
        return;
      }
      // Nothing to copy: a stale row reads the key, a touch or counter row asks for its one code.
      if (needsTouch || !timeBased) {
        await askKeyCode(context, ref, account);
      } else {
        await readKeyCodes(context, ref);
      }
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
              final showNext = urgent && !copied && next != null;
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
                          hint: code == null && !needsTouch && timeBased ? context.t('keyCodes.row.read', {'name': name}) : null,
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              onTap: () => unawaited(act()),
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                                child: Row(
                                  children: [
                                    KeyAccountTile(name: name),
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
                                    if (code != null) ...[
                                      const SizedBox(width: 14),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (fresh != null && account.period != 30) ...[
                                                CountdownRing(remaining: remaining, period: account.period, size: 18, stroke: 2),
                                                const SizedBox(width: 8),
                                              ],
                                              CodeDigits(
                                                code: code,
                                                style: TextStyle(fontSize: code.length == 8 ? 19 : 22, color: urgent ? p.warning : p.text),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          SizedBox(
                                            height: 14,
                                            child: copied
                                                ? Row(
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
                                                  )
                                                : showNext
                                                ? Text(
                                                    context.t('accountCard.next', {'code': formatCode(next.code)}),
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: AppType.mono(fontSize: 11, color: b.faint).copyWith(height: 14 / 11),
                                                  )
                                                : null,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (needsTouch)
                      TextButton(
                        onPressed: () => unawaited(askKeyCode(context, ref, account)),
                        style: TextButton.styleFrom(foregroundColor: b.accentText, visualDensity: VisualDensity.compact),
                        child: Text(context.t('keyCodes.tapKey')),
                      ),
                    if (!timeBased)
                      _SideButton(
                        tooltip: context.t('keyCodes.counter.next', {'name': name}),
                        icon: Icons.refresh_rounded,
                        color: b.accentText,
                        height: 44,
                        onPressed: () => unawaited(askKeyCode(context, ref, account)),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _SideButton(
                        tooltip: context.t('accountCard.details', {'name': name}),
                        icon: Icons.chevron_right_rounded,
                        color: b.faint,
                        height: 60,
                        onPressed: () => unawaited(showKeyAccountSheet(context, account: account, allTags: widget.allTags)),
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

/// The narrow buttons at the row's right: the next counter code and the chevron.
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
