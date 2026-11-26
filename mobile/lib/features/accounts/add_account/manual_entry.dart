import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/now.dart';
import '../../../i18n/messages.dart';
import '../../../models/otp_account.dart';
import '../../../ui/ui.dart';
import '../../fields/custom_fields_editor.dart';
import '../../sync/kemlock/km_kinds.dart' show KmKind;
import '../otp.dart';
import '../service_tile.dart';
import '../websites_editor.dart';
import 'manual_form.dart';

/// The Manual tab: a live preview of the account and its code, the service,
/// account and secret fields, and the type, algorithm, digits, period and
/// counter under Advanced. `ManualEntry` in `AddAccountDialog.tsx`.
class ManualEntry extends StatelessWidget {
  const ManualEntry({
    super.key,
    required this.form,
    required this.error,
    required this.advanced,
    required this.onToggleAdvanced,
    required this.onSubmit,
  });

  final ManualForm form;

  /// What is wrong with the form, after a try to add it.
  final String? error;
  final bool advanced;
  final VoidCallback onToggleAdvanced;

  /// The keyboard's done key on the secret field adds the account.
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Preview(form: form),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(context.t('addAccount.preview.hint'), style: AppType.caption.copyWith(color: b.faint)),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: AppAlert(severity: AlertSeverity.error, child: Text(error!)),
          ),
        const SizedBox(height: 18),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: form.issuer,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: context.t('addAccount.field.issuer'),
            hintText: context.t('addAccount.field.issuerPlaceholder'),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: form.label,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: context.t('addAccount.field.label'),
            hintText: context.t('addAccount.field.labelPlaceholder'),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: form.name,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: context.t('accounts.field.name'), hintText: context.t('accounts.field.namePlaceholder')),
        ),
        const SizedBox(height: 14),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: form.secret,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          inputFormatters: const [SecretFormatter()],
          style: AppType.mono(fontSize: 15).copyWith(letterSpacing: 15 * .06, color: p.text),
          decoration: InputDecoration(
            // Required, as MUI marks it: the star isn't part of the field's name.
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.t('addAccount.field.secret')),
                const ExcludeSemantics(child: Text(' *')),
              ],
            ),
            hintText: context.t('addAccount.field.secretPlaceholder'),
            helperText: context.t('addAccount.field.secretHelper'),
          ),
        ),
        const SizedBox(height: 18),
        SectionLabel(context.t('accounts.websites.title'), padding: const EdgeInsets.fromLTRB(4, 0, 4, 8)),
        WebsitesEditor(draft: form.websites),
        const SizedBox(height: 12),
        const SizedBox(height: 12),
        _AdvancedToggle(open: advanced, onPressed: onToggleAdvanced),
        _Collapsible(
          open: advanced,
          child: Padding(
            // Room for the focus halo inside the clipped area.
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 12),
            child: ListenableBuilder(
              listenable: form,
              builder: (context, _) => _AdvancedFields(form: form),
            ),
          ),
        ),
        const SizedBox(height: 14),
        CustomFieldsEditor(kind: KmKind.otp, fields: form.fields, onChanged: (next) => form.fields = next),
      ],
    );
  }
}

/// The account as it will look, with its live code once the key is valid.
class _Preview extends ConsumerWidget {
  const _Preview({required this.form});

  final ManualForm form;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final b = context.bmc;
    final nowSec = ref.watch(nowSecondsProvider);
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final name = form.name.text.trim().isNotEmpty ? form.name.text.trim() : form.issuer.text.trim();
        final label = form.label.text.trim();
        final ready = form.secretOk && form.paramsOk;
        final String code;
        if (ready) {
          code = formatCode(codeAt(form.toAccount(), nowSec));
        } else {
          code = form.type == OtpType.steam
              ? '–––––'
              : form.digits == 8
              ? '–––– ––––'
              : '––– –––';
        }
        return Semantics(
          liveRegion: true,
          container: true,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: b.raised,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.divider),
            ),
            child: Row(
              children: [
                ServiceTile(name: name),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? context.t('addAccount.preview.name') : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: fontSans,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                          color: name.isEmpty ? b.faint : p.text,
                        ),
                      ),
                      Text(
                        label.isEmpty ? context.t('addAccount.preview.label') : label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: fontSans, fontSize: 13, height: 1.5, color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: ready ? p.text : b.faint),
                  duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 300),
                  curve: Ease.css,
                  builder: (context, color, _) => Text(
                    code,
                    style: AppType.mono(fontSize: 22, fontWeight: FontWeight.w500, color: color),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The row that opens and closes the advanced fields, its chevron turning over.
class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = context.t('addAccount.advanced');
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(fontFamily: fontSans, fontSize: 14.5, fontWeight: FontWeight.w600, color: p.textSecondary),
                    ),
                  ),
                  AnimatedRotation(
                    turns: open ? .5 : 0,
                    duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 350),
                    curve: Ease.sheet,
                    child: Icon(Icons.expand_more_rounded, color: p.textSecondary),
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

/// Opens down to its child's height and closes back up over .45s. Closed,
/// its fields are out of reach of taps, focus and screen readers.
class _Collapsible extends StatelessWidget {
  const _Collapsible({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedAlign(
      alignment: Alignment.topCenter,
      heightFactor: open ? 1 : 0,
      duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 450),
      curve: Ease.sheet,
      child: IgnorePointer(
        ignoring: !open,
        child: ExcludeFocus(
          excluding: !open,
          child: ExcludeSemantics(excluding: !open, child: child),
        ),
      ),
    ),
  );
}

class _AdvancedFields extends StatelessWidget {
  const _AdvancedFields({required this.form});

  final ManualForm form;

  @override
  Widget build(BuildContext context) {
    final type = form.type;
    final typeLabel = context.t('addAccount.field.type');
    final algorithmLabel = context.t('addAccount.field.algorithm');
    final digitsLabel = context.t('addAccount.field.digits');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AdvancedRow(
          label: typeLabel,
          child: SizedBox(
            width: 230,
            child: SegmentedControl<OtpType>(
              size: SegmentSize.small,
              semanticLabel: typeLabel,
              value: type,
              onChanged: (value) => form.type = value,
              options: [for (final t in OtpType.values) SegmentOption(value: t, label: otpTypeName(t))],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (type == OtpType.steam)
          Text(context.t('addAccount.steamHint'), style: AppType.caption.copyWith(color: context.palette.textSecondary))
        else ...[
          _AdvancedRow(
            label: algorithmLabel,
            child: SizedBox(
              width: 230,
              child: SegmentedControl<String>(
                size: SegmentSize.small,
                mono: true,
                semanticLabel: algorithmLabel,
                value: form.algorithm,
                onChanged: (value) => form.algorithm = value,
                options: [for (final a in manualAlgorithms) SegmentOption(value: a, label: algorithmName(a))],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _AdvancedRow(
            label: digitsLabel,
            child: SizedBox(
              width: 120,
              child: SegmentedControl<int>(
                size: SegmentSize.small,
                mono: true,
                semanticLabel: digitsLabel,
                value: form.digits,
                onChanged: (value) => form.digits = value,
                options: [for (final d in manualDigits) SegmentOption(value: d, label: '$d')],
              ),
            ),
          ),
        ],
        if (type == OtpType.totp) ...[
          const SizedBox(height: 14),
          _NumberRow(label: context.t('addAccount.field.period'), controller: form.period, suffix: 's'),
        ],
        if (type == OtpType.hotp) ...[
          const SizedBox(height: 14),
          _NumberRow(label: context.t('addAccount.field.counter'), controller: form.counter),
        ],
      ],
    );
  }
}

class _AdvancedRow extends StatelessWidget {
  const _AdvancedRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ExcludeSemantics(
          child: Text(label, style: AppType.body2.copyWith(color: context.palette.textSecondary)),
        ),
      ),
      const SizedBox(width: 12),
      child,
    ],
  );
}

/// A label beside a small number field, which screen readers read as the field's name.
class _NumberRow extends StatelessWidget {
  const _NumberRow({required this.label, required this.controller, this.suffix});

  final String label;
  final TextEditingController controller;
  final String? suffix;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ExcludeSemantics(
          child: Text(label, style: AppType.body2.copyWith(color: context.palette.textSecondary)),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        width: 120,
        child: Semantics(
          label: label,
          child: TextField(
            enableIMEPersonalizedLearning: false,
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppType.mono(fontSize: 15, color: context.palette.text),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              suffixText: suffix,
            ),
          ),
        ),
      ),
    ],
  );
}
