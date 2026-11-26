import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/now.dart';
import '../../i18n/messages.dart';
import '../../models/custom_field.dart';
import '../../models/json.dart' show unset;
import '../../models/otp_account.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../backup/coverage.dart';
import '../breaches/breach_widgets.dart';
import '../fields/custom_fields_editor.dart';
import '../fields/custom_fields_view.dart';
import '../links/linked_items_section.dart';
import '../logins/account_login.dart';
import '../settings/prefs.dart';
import '../sync/kemlock/km_kinds.dart';
import '../sync/space_picker.dart';
import '../sync/sync_store.dart';
import '../sync/vaultwarden/vaultwarden_login.dart';
import '../vault/owner_check.dart';
import 'account_websites.dart';
import 'key_transfer_actions.dart';
import 'otp.dart';
import 'otpauth.dart';
import 'service_tile.dart';
import 'tag_input.dart';

/// What the list calls an account: its name when it has one, else its issuer, else its label.
String displayName(OtpAccount account) {
  final name = account.name?.trim() ?? '';
  if (name.isNotEmpty) return name;
  return account.issuer.isNotEmpty ? account.issuer : account.label;
}

/// The line under [displayName]: an account's label under its issuer, and for one that has a name, its issuer and label.
String accountSubLabel(OtpAccount account) {
  if (account.name?.trim().isNotEmpty ?? false) return [account.issuer, account.label].where((part) => part.isNotEmpty).join(' · ');
  return account.issuer.isNotEmpty ? account.label : '';
}

/// What an account's tile is drawn from: its issuer, which names the service, else what it is called.
String accountTileName(OtpAccount account) => account.issuer.isNotEmpty ? account.issuer : displayName(account);

/// [displayName], or "Unknown" for an account with neither.
String accountTitle(BuildContext context, OtpAccount account) {
  final name = displayName(account);
  return name.isNotEmpty ? name : context.t('accountCard.unknown');
}

/// Opens an account's detail sheet, `AccountSheet.tsx`: the code in large,
/// its countdown or HOTP counter and the next code, copying, pinning, the
/// details, the secret and its QR code behind a tap, editing, and removing.
/// [onDelete] is called with the account's id after the sheet closes, to
/// ask before removing it; [onUpdate] gets each change; [onCopied] runs
/// after the code lands on the clipboard.
/// The sheet follows the account in the vault as it changes.
Future<void> showAccountSheet(
  BuildContext context, {
  required OtpAccount account,
  List<String> allTags = const [],
  required ValueChanged<String> onDelete,
  required ValueChanged<OtpAccount> onUpdate,
  ValueChanged<OtpAccount>? onCopied,
}) => showAppBottomSheet<void>(
  context,
  label: accountTitle(context, account),
  builder: (_) => AccountSheet(account: account, allTags: allTags, onDelete: onDelete, onUpdate: onUpdate, onCopied: onCopied),
);

enum _Panel { details, qr, edit }

/// The content of the sheet [showAccountSheet] opens.
class AccountSheet extends ConsumerStatefulWidget {
  const AccountSheet({
    super.key,
    required this.account,
    this.allTags = const [],
    required this.onDelete,
    required this.onUpdate,
    this.onCopied,
  });

  final OtpAccount account;
  final List<String> allTags;
  final ValueChanged<String> onDelete;
  final ValueChanged<OtpAccount> onUpdate;
  final ValueChanged<OtpAccount>? onCopied;

  @override
  ConsumerState<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<AccountSheet> {
  var _panel = _Panel.details;
  final _copied = Flash(const Duration(milliseconds: 1900));

  @override
  void dispose() {
    _copied.dispose();
    super.dispose();
  }

  void _toggle(_Panel panel) => setState(() => _panel = _panel == panel ? _Panel.details : panel);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    // The vault's copy, so a pin or an edit shows at once; the one given when the vault doesn't have it
    final account =
        ref.watch(vaultControllerProvider.select((s) => s.accounts.firstWhereOrNull((a) => a.id == widget.account.id))) ?? widget.account;
    final nowSec = ref.watch(nowSecondsProvider);
    final name = accountTitle(context, account);
    final subLabel = accountSubLabel(account);
    final timeBased = isTimeBased(account);
    final remaining = remainingIn(nowSec, account.period);
    final urgent = timeBased && remaining <= 5;
    final code = codeAt(account, nowSec);
    final pinned = account.pinned ?? false;

    Future<void> copy() async {
      if (!await ref.read(secretClipboardProvider).copy(code)) return;
      _copied.trigger();
      widget.onCopied?.call(account);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              ServiceTile(name: accountTileName(account), size: 54),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.h3.copyWith(color: p.text),
                      ),
                    ),
                    if (subLabel.isNotEmpty)
                      Text(
                        subLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body2.copyWith(color: p.textSecondary),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              PressScale(
                scale: 0.94,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: context.t('accountSheet.close'),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: b.raised,
                    foregroundColor: p.textSecondary,
                    fixedSize: const Size.square(38),
                    minimumSize: const Size.square(38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ),
            ],
          ),

          // Big code: tap to copy
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: PressScale(
              scale: 0.98,
              // A button whose name is the code and "Tap to copy", as the web app's was
              child: Semantics(
                container: true,
                button: true,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: copy,
                    borderRadius: BorderRadius.circular(22),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        children: [
                          CodeDigits(
                            code: code,
                            style: TextStyle(fontSize: 52, letterSpacing: 0.78, color: urgent ? p.warning : p.text),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 18,
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _copied,
                              builder: (context, copied, _) => _CrossFade(
                                on: copied,
                                off: Text(
                                  context.t('accountSheet.tapToCopy'),
                                  style: AppType.caption.copyWith(color: b.faint, fontWeight: FontWeight.w500),
                                ),
                                onChild: Text(
                                  context.t('accountSheet.copiedToClipboard'),
                                  style: AppType.caption.copyWith(color: b.accentText, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
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
            _HotpCounter(
              account: account,
              onNext: () => widget.onUpdate(account.copyWith(counter: (account.counter ?? 0) + 1)),
            ),

          if (timeBased) ...[
            // Countdown
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Row(
                children: [
                  Expanded(
                    child: _CountdownBar(remaining: remaining, period: account.period, color: urgent ? p.warning : b.accentText),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 36,
                    child: Text(
                      context.t('accountSheet.secondsShort', {'seconds': remaining}),
                      textAlign: TextAlign.right,
                      style: AppType.mono(fontSize: 13, fontWeight: FontWeight.w600, color: urgent ? p.warning : b.accentText),
                    ),
                  ),
                ],
              ),
            ),

            // Up next
            Container(
              margin: const EdgeInsets.only(top: 14),
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: p.divider),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(context.t('accountSheet.upNext'), style: AppType.body2.copyWith(color: p.textSecondary)),
                  ),
                  Text(
                    formatCode(codeAt(account, nowSec, 1)),
                    style: AppType.mono(fontSize: 17, fontWeight: FontWeight.w500, color: p.textSecondary),
                  ),
                  const SizedBox(width: 8),
                  Text(context.t('accountCard.nextCodes.in', {'seconds': remaining}), style: AppType.caption.copyWith(color: b.faint)),
                ],
              ),
            ),
          ],

          // Primary copy
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: PressScale(
              child: FilledButton(
                onPressed: copy,
                style: largeButtonStyle,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _copied,
                  builder: (context, copied, _) => _CrossFade(
                    on: copied,
                    slide: true,
                    off: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.content_copy_rounded, size: 19),
                        const SizedBox(width: 8),
                        Text(context.t('accountCard.tooltip.copy')),
                      ],
                    ),
                    onChild: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_rounded, size: 20),
                        const SizedBox(width: 8),
                        Text(context.t('accountCard.tooltip.copied')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Secondary actions
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                Expanded(
                  child: _ActionTile(
                    icon: Icons.qr_code_2_rounded,
                    label: context.t('accountCard.tooltip.viewQr'),
                    active: _panel == _Panel.qr,
                    expanded: _panel == _Panel.qr,
                    onTap: () => _toggle(_Panel.qr),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.edit_rounded,
                    label: context.t('accountSheet.edit'),
                    active: _panel == _Panel.edit,
                    expanded: _panel == _Panel.edit,
                    onTap: () => _toggle(_Panel.edit),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    label: context.t(pinned ? 'accountSheet.pinned' : 'accountSheet.pin'),
                    active: pinned,
                    pressed: pinned,
                    onTap: () => widget.onUpdate(account.copyWith(pinned: !pinned)),
                  ),
                ),
              ],
            ),
          ),

          switch (_panel) {
            _Panel.details => _Details(key: const ValueKey(_Panel.details), account: account),
            _Panel.qr => _SecretPanel(key: const ValueKey(_Panel.qr), account: account),
            _Panel.edit => _EditPanel(
              key: const ValueKey(_Panel.edit),
              account: account,
              allTags: widget.allTags,
              onCancel: () => setState(() => _panel = _Panel.details),
              onSave: (changed) {
                widget.onUpdate(changed);
                setState(() => _panel = _Panel.details);
              },
            ),
          },

          AccountWebsites(account: account, onUpdate: widget.onUpdate),

          AccountLogin(account: account),

          AccountBreaches(account: account),

          VaultwardenLoginPanel(account: account),

          KeyTransferActions(account: account),

          if (_panel != _Panel.edit) CustomFieldsView(fields: account.fields),
          LinkedItemsSection(entry: account),

          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: PressScale(
              child: TextButton.icon(
                onPressed: () async {
                  // The code is in the user's own Vaultwarden login: say so first
                  final linked = ref.read(vwLinkedLoginProvider(account.id)).value;
                  if (linked != null) {
                    final remove = context.t('accountCard.tooltip.remove');
                    final confirmed = await showConfirmDialog(
                      context,
                      title: remove,
                      body: Text(context.t('vaultwarden.deleteLinked', {'name': linked.name})),
                      confirmLabel: remove,
                      cancelLabel: context.t('changePw.cancel'),
                    );
                    if (!confirmed || !context.mounted) return;
                  }
                  Navigator.of(context).pop();
                  widget.onDelete(account.id);
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: b.dangerSoft,
                  foregroundColor: p.error,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: Text(context.t('accountCard.tooltip.remove')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Swaps two labels with a short fade, and with [slide] a little roll up.
/// Only the label showing is read out.
class _CrossFade extends StatelessWidget {
  const _CrossFade({required this.on, required this.off, required this.onChild, this.slide = false});

  final bool on;
  final Widget off;
  final Widget onChild;
  final bool slide;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    Widget layer(bool visible, double from, Widget child) => IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: reduced ? Duration.zero : const Duration(milliseconds: 250),
          child: AnimatedSlide(
            // A fraction of the label's own height: 10px on a 20px row
            offset: visible || !slide ? Offset.zero : Offset(0, from / 20),
            duration: reduced ? Duration.zero : const Duration(milliseconds: 350),
            curve: Ease.roll,
            child: child,
          ),
        ),
      ),
    );
    return Stack(alignment: Alignment.center, children: [layer(!on, -10, off), layer(on, 10, onChild)]);
  }
}

/// The bar that drains over the window, beside the seconds left.
class _CountdownBar extends StatelessWidget {
  const _CountdownBar({required this.remaining, required this.period, required this.color});

  final int remaining;
  final int period;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final refill = remaining == period;
    final fraction = period <= 0 ? 0.0 : (remaining - 1).clamp(0, period) / period;
    return ExcludeSemantics(
      child: Container(
        height: 6,
        decoration: BoxDecoration(color: context.bmc.raised, borderRadius: BorderRadius.circular(3)),
        clipBehavior: Clip.antiAlias,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: fraction),
          duration: reduced
              ? Duration.zero
              : refill
              ? const Duration(milliseconds: 500)
              : const Duration(seconds: 1),
          curve: refill ? Ease.out : Curves.linear,
          builder: (context, value, _) => FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0.0, 1.0),
            child: AnimatedContainer(
              duration: reduced ? Duration.zero : const Duration(milliseconds: 400),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the three square buttons under the copy button.
class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.active, required this.onTap, this.pressed, this.expanded});

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool? pressed;
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final reduced = Motion.reduced(context);
    final foreground = active ? b.accentText : p.text;
    return Semantics(
      container: true,
      button: true,
      toggled: pressed,
      expanded: expanded,
      child: PressScale(
        scale: 0.96,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : Motion.colour,
          height: 72,
          decoration: BoxDecoration(color: active ? b.accentSoft : b.raised, borderRadius: BorderRadius.circular(18)),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22, color: foreground),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: fontSans, fontSize: 12.5, fontWeight: FontWeight.w500, color: foreground),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bordered box the details, the secret and the edit form sit in, rising into place.
class _PanelBox extends StatelessWidget {
  const _PanelBox({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => Rise(
    duration: const Duration(milliseconds: 400),
    child: Container(
      margin: const EdgeInsets.only(top: 18),
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.palette.divider),
      ),
      child: child,
    ),
  );
}

/// HOTP codes only change when asked for, so the sheet offers that instead of a countdown.
class _HotpCounter extends StatelessWidget {
  const _HotpCounter({required this.account, required this.onNext});

  final OtpAccount account;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      height: 52,
      padding: const EdgeInsets.only(left: 16, right: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.t('accountSheet.counter', {'counter': account.counter ?? 0}),
              style: AppType.body2.copyWith(color: p.textSecondary),
            ),
          ),
          Semantics(
            container: true,
            button: true,
            label: context.t('accountCard.hotpNext', {'name': displayName(account)}),
            excludeSemantics: true,
            child: TextButton.icon(
              onPressed: onNext,
              style: TextButton.styleFrom(foregroundColor: context.bmc.accentText),
              icon: const Icon(Icons.refresh_rounded, size: 20),
              label: Text(context.t('accountSheet.nextCode')),
            ),
          ),
        ],
      ),
    );
  }
}

const _typeLabels = {OtpType.totp: 'TOTP', OtpType.hotp: 'HOTP', OtpType.steam: 'Steam'};

class _Details extends ConsumerWidget {
  const _Details({super.key, required this.account});

  final OtpAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final mono = AppType.mono(fontSize: 13.5, color: p.text);
    final type = account.kind;
    final space = ref.watch(spaceNameProvider(account.spaceId));
    final services = ref.watch(vaultControllerProvider.select((s) => s.backupServices));
    final checksCodes = account.noBackupCodes != true;
    final backup = checksCodes ? backupFor(account, services) : null;
    final left = backup?.codes.where((c) => !c.used).length ?? 0;
    final tags = account.tags ?? const [];
    final locale = Localizations.localeOf(context).toString();

    final rows = <Widget>[
      _DetailRow(
        label: context.t('accountSheet.type'),
        value: Text(_typeLabels[type]!, style: mono),
      ),
      if (type != OtpType.steam) ...[
        _DetailRow(
          label: context.t('viewQr.label.algorithm'),
          value: Text(account.algorithm.replaceFirst('SHA', 'SHA-'), style: mono),
        ),
        _DetailRow(
          label: context.t('viewQr.label.digits'),
          value: Text('${account.digits}', style: mono),
        ),
      ],
      if (type != OtpType.hotp)
        _DetailRow(
          label: context.t('viewQr.label.period'),
          value: Text(context.t('accountSheet.secondsShort', {'seconds': account.period}), style: mono),
        ),
      if (tags.isNotEmpty)
        _DetailRow(
          label: context.t('tags.label'),
          value: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [for (final tag in tags) TagChip(label: tag)],
          ),
        ),
      if (space != null) _DetailRow(label: context.t('spaces.picker.label'), value: Text(space)),
      if (checksCodes)
        _DetailRow(
          label: context.t('accountSheet.backupCodes'),
          value: Text(
            backup != null ? context.t('accountSheet.backupCodes.left', {'count': left}) : context.t('accountSheet.backupCodes.none'),
            style: TextStyle(color: backup != null && left > 2 ? p.text : p.warning),
          ),
        ),
      if (account.addedAt > 0)
        _DetailRow(
          label: context.t('accountSheet.added'),
          value: Text(DateFormat.yMMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(account.addedAt))),
        ),
    ];
    final note = account.note ?? '';

    return _PanelBox(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, row) in rows.indexed)
            if (i == 0) row else _Hairline(child: row),
          if (note.isNotEmpty)
            _Hairline(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.t('accountSheet.note'), style: AppType.body2.copyWith(color: p.textSecondary)),
                    const SizedBox(height: 4),
                    Text(note, style: AppType.body2.copyWith(color: p.text)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A divider line above [child].
class _Hairline extends StatelessWidget {
  const _Hairline({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: context.palette.divider)),
    ),
    child: child,
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      container: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Row(
          children: [
            Text(label, style: AppType.body2.copyWith(color: p.textSecondary)),
            const SizedBox(width: 16),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DefaultTextStyle.merge(
                    style: AppType.body2.copyWith(color: p.text),
                    textAlign: TextAlign.right,
                    child: value,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The QR code and the secret, hidden behind a blurred stand-in until the
/// user asks, so the secret is never drawn unless revealed.
class _SecretPanel extends ConsumerStatefulWidget {
  const _SecretPanel({super.key, required this.account});

  final OtpAccount account;

  @override
  ConsumerState<_SecretPanel> createState() => _SecretPanelState();
}

class _SecretPanelState extends ConsumerState<_SecretPanel> {
  var _revealed = false;
  final _copied = Flash(const Duration(seconds: 2));

  @override
  void dispose() {
    _copied.dispose();
    super.dispose();
  }

  /// Shows the secret, once the person has shown it is them when Settings
  /// asks for that.
  Future<void> _reveal() async {
    if (ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('accountSheet.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason)) return;
    }
    if (mounted) setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    String? uri;
    if (_revealed) {
      try {
        uri = buildOtpUri(widget.account);
      } catch (_) {
        uri = null;
      }
    }

    return _PanelBox(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Container(
            width: 188,
            height: 188,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(16)),
            child: Stack(
              alignment: Alignment.center,
              // The reveal button may be wider than the code, as it was on the web
              clipBehavior: Clip.none,
              children: [
                if (_revealed && uri != null)
                  FadeIn(
                    child: QrImageView(
                      data: uri,
                      size: 168,
                      padding: EdgeInsets.zero,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      backgroundColor: const Color(0xFFFFFFFF),
                      semanticsLabel: context.t('accountCard.tooltip.viewQr'),
                    ),
                  )
                else
                  ExcludeSemantics(
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                      child: const CustomPaint(size: Size.square(168), painter: _PlaceholderPainter()),
                    ),
                  ),
                if (!_revealed)
                  OverflowBox(
                    maxWidth: 360,
                    child: PressScale(
                      child: Semantics(
                        container: true,
                        button: true,
                        child: Material(
                          color: const Color(0xFF0A0B0D),
                          shape: const StadiumBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => unawaited(_reveal()),
                            child: Container(
                              height: 38,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.visibility_rounded, size: 17, color: Color(0xFFF3F4F6)),
                                  const SizedBox(width: 7),
                                  Text(
                                    context.t('accountSheet.reveal'),
                                    style: const TextStyle(
                                      fontFamily: fontSans,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFF3F4F6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_revealed) ...[
            const SizedBox(height: 14),
            FadeIn(
              duration: const Duration(milliseconds: 400),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      groupSecret(widget.account.secret),
                      textAlign: TextAlign.center,
                      style: AppType.mono(fontSize: 14.5, color: p.text).copyWith(letterSpacing: 0.87),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<bool>(
                    valueListenable: _copied,
                    builder: (context, copied, _) => IconButton(
                      onPressed: () async {
                        if (await ref.read(secretClipboardProvider).copy(widget.account.secret)) _copied.trigger();
                      },
                      tooltip: context.t(copied ? 'viewQr.secret.copied' : 'viewQr.secret.copy'),
                      color: copied ? b.accentText : p.textSecondary,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        copied ? Icons.check_rounded : Icons.content_copy_rounded,
                        size: 20,
                        semanticLabel: context.t('viewQr.secret.copy'),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _revealed = false),
                    tooltip: context.t('viewQr.secret.hide'),
                    color: p.textSecondary,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.visibility_off_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 290),
            child: Text(
              context.t('accountSheet.secretWarning'),
              textAlign: TextAlign.center,
              style: AppType.caption.copyWith(color: b.faint),
            ),
          ),
        ],
      ),
    );
  }
}

/// A made-up QR code with the three finder squares, which stands in, blurred, for the real one.
class _PlaceholderPainter extends CustomPainter {
  const _PlaceholderPainter();

  static const _cells = 21;

  static bool _on(int r, int c) {
    final finder = (r < 7 && c < 7) || (r < 7 && c > 13) || (r > 13 && c < 7);
    if (finder) {
      final y = r % 14;
      final x = c % 14;
      final ring = y == 0 || y == 6 || x == 0 || x == 6;
      final core = y >= 2 && y <= 4 && x >= 2 && x <= 4;
      return ring || core;
    }
    return (r * 7 + c * 13 + r * c) % 5 < 2;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / _cells;
    final paint = Paint()..color = const Color(0xFF0A0B0D);
    for (var r = 0; r < _cells; r++) {
      for (var c = 0; c < _cells; c++) {
        if (_on(r, c)) canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_PlaceholderPainter old) => false;
}

/// Editing the issuer, label, note, tags, space and whether the service
/// gives backup codes. An empty note and no tags are dropped rather than
/// stored empty.
class _EditPanel extends ConsumerStatefulWidget {
  const _EditPanel({super.key, required this.account, required this.allTags, required this.onCancel, required this.onSave});

  final OtpAccount account;
  final List<String> allTags;
  final VoidCallback onCancel;
  final ValueChanged<OtpAccount> onSave;

  @override
  ConsumerState<_EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends ConsumerState<_EditPanel> {
  late final _name = TextEditingController(text: widget.account.name ?? '');
  late final _issuer = TextEditingController(text: widget.account.issuer);
  late final _label = TextEditingController(text: widget.account.label);
  late final _note = TextEditingController(text: widget.account.note ?? '');
  late var _tags = widget.account.tags ?? const <String>[];
  late String? _spaceId = widget.account.spaceId;
  late var _noCodes = widget.account.noBackupCodes ?? false;
  late var _customFields = <CustomField>[...widget.account.fields];
  final _tagInput = GlobalKey<TagInputState>();

  @override
  void dispose() {
    _name.dispose();
    _issuer.dispose();
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _valid => _issuer.text.trim().isNotEmpty || _label.text.trim().isNotEmpty;

  void _save() {
    if (!_valid) return;
    // A tag still in the field counts, as leaving the field would have added it
    final tags = _tagInput.currentState?.commitDraft() ?? _tags;
    final note = _note.text.trim();
    widget.onSave(
      widget.account.copyWith(
        name: _name.text.trim().isNotEmpty ? _name.text.trim() : unset,
        issuer: _issuer.text.trim(),
        label: _label.text.trim(),
        note: note.isNotEmpty ? note : unset,
        tags: tags.isNotEmpty ? tags : unset,
        spaceId: _spaceId ?? unset,
        noBackupCodes: _noCodes ? true : unset,
        fields: _customFields,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // The space picker takes no room when there is no space to pick and the account is in none
    final hasSpaces = ref.watch(syncProvider.select((sync) => sync.settings?.spaces.isNotEmpty ?? false));
    return _PanelBox(
      padding: const EdgeInsets.all(16),
      child: ListenableBuilder(
        listenable: Listenable.merge([_issuer, _label]),
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: context.t('accounts.field.name'),
                hintText: context.t('accounts.field.namePlaceholder'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _issuer,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: context.t('addAccount.field.issuer')),
            ),
            const SizedBox(height: 14),
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _label,
              decoration: InputDecoration(labelText: context.t('addAccount.field.label')),
            ),
            const SizedBox(height: 14),
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _note,
              minLines: 2,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: context.t('accountSheet.note'),
                hintText: context.t('accountSheet.notePlaceholder'),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 14),
            CustomFieldsEditor(
              kind: itemKindOf(widget.account),
              fields: _customFields,
              onChanged: (next) => setState(() => _customFields = next),
            ),
            const SizedBox(height: 14),
            TagInput(key: _tagInput, value: _tags, onChanged: (next) => setState(() => _tags = next), suggestions: widget.allTags),
            if (hasSpaces || _spaceId != null) ...[
              const SizedBox(height: 14),
              SpacePicker(value: _spaceId, onChanged: (id) => setState(() => _spaceId = id)),
            ],
            const SizedBox(height: 6),
            MergeSemantics(
              child: InkWell(
                onTap: () => setState(() => _noCodes = !_noCodes),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _noCodes,
                        onChanged: (value) => setState(() => _noCodes = value ?? false),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(context.t('accountSheet.noBackupCodes'), style: AppType.body1.copyWith(color: p.text)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: widget.onCancel,
                  style: TextButton.styleFrom(foregroundColor: p.text),
                  child: Text(context.t('addAccount.cancel')),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _valid ? _save : null, child: Text(context.t('accountSheet.save'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
