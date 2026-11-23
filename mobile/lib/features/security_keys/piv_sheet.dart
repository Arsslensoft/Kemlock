import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../security_key/piv/piv_data.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../security_key/piv/piv_session.dart';
import '../../ui/ui.dart';
import '../keys/key_standing.dart';
import '../keys/key_widgets.dart' show KeyStandingTag;
import 'key_codes_sheet.dart';
import 'key_widgets.dart';
import 'openpgp_card_sheet.dart';
import 'piv_codes_sheet.dart';
import 'piv_controller.dart';
import 'piv_generate_sheet.dart';
import 'piv_management_key_sheet.dart';
import 'piv_reset.dart';
import 'piv_slot_sheet.dart';
import 'security_key_controller.dart';

/// "Also on this key" on the Security key sheet: the "Codes" row of
/// `add-security-key-codes`, the "PGP keys" row of `add-openpgp-card`,
/// then the "Certificates" row, how many of the four slots hold a
/// certificate. The PGP keys and Certificates rows are there only once the
/// key was read and has the application; the group always has Codes.
class PivSection extends StatelessWidget {
  const PivSection({super.key, required this.keys});

  final SecurityKeyController keys;

  @override
  Widget build(BuildContext context) {
    final piv = PivController.of(keys);
    final state = piv.state;
    return Group(
      label: context.t('securityKeys.section.also'),
      children: [
        KeyCodesRow(controller: keys),
        // add-openpgp-card's "PGP keys" row, between Codes and Certificates
        OpenPgpKeysRow(keys: keys),
        if (state != null)
          GroupRow(
            first: false,
            primary: context.t('piv.title'),
            value: Text(context.t('piv.row.slots', {'used': state.slotsInUse, 'total': PivSlot.values.length})),
            onTap: keys.busy ? null : () => unawaited(showPivSheet(context, keys)),
          ),
      ],
    );
  }
}

/// Opens the Certificates sheet of the key [keys] has read.
Future<void> showPivSheet(BuildContext context, SecurityKeyController keys) => showAppBottomSheet<void>(
  context,
  label: context.t('piv.title'),
  builder: (_) => PivSheet(keys: keys),
);

/// The Certificates sheet, as `Piv.dc.html` draws it (design decision 14):
/// the four slots, the codes that protect them, and the warning and
/// button of a factory management key; then reset, on a key that offers
/// it.
class PivSheet extends ConsumerWidget {
  const PivSheet({super.key, required this.keys});

  final SecurityKeyController keys;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piv = PivController.of(keys);
    return ListenableBuilder(
      listenable: Listenable.merge([piv, keys]),
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeySheetHeader(title: context.t('piv.title')),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KeyActivity(controller: keys),
                  if (piv.state case final state?)
                    _Content(piv: piv, state: state, now: ref.read(clockProvider)(), notes: ref.read(pivNotesProvider).notes)
                  else
                    AppAlert(severity: AlertSeverity.info, child: Text(context.t('piv.gone'))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A delay of the mockup's entrance, step [step].
Duration _step(int step) => Duration(milliseconds: 60 * step);

class _Content extends StatelessWidget {
  const _Content({required this.piv, required this.state, required this.now, required this.notes});

  final PivController piv;
  final PivState state;
  final DateTime now;
  final List<SecureNote> notes;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final busy = piv.busy;
    final locale = Localizations.localeOf(context).toLanguageTag();
    VoidCallback? tap(Future<void> Function() action) => busy ? null : () => unawaited(action());

    GroupRow slotRow(int index, PivSlot slot) {
      final slotState = state.slots[slot] ?? PivSlotState(slot, PivSlotStatus.empty);
      final tile = Text(slot.id, style: AppType.mono(fontSize: 12.5, fontWeight: FontWeight.w500));
      final name = pivSlotName(context, slot);
      final faint = TextStyle(color: b.faint);
      switch (slotState.status) {
        case PivSlotStatus.needsContact:
          return GroupRow(
            first: index == 0,
            icon: tile,
            primary: name,
            secondary: context.t('piv.slot.needsContact'),
            secondaryStyle: faint,
          );
        case PivSlotStatus.empty:
          return GroupRow(
            first: index == 0,
            icon: tile,
            primary: name,
            secondary: context.t('piv.empty'),
            secondaryStyle: faint,
            control: TextButton(
              onPressed: tap(() async {
                final importing = await showPivGenerateSheet(context, piv, slot);
                if (importing == true && context.mounted) await showPivSlotSheet(context, piv, slot);
              }),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6)),
              child: Text(context.t('piv.add')),
            ),
          );
        case PivSlotStatus.certificate || PivSlotStatus.unreadable:
          final certificate = pivSlotCertificate(slotState);
          final standing = certificate == null ? null : certificateStanding(certificate.notAfter, now);
          final tagged = standing != null && standing.standing != Standing.ok;
          final String secondary;
          if (certificate == null) {
            secondary = context.t('piv.slot.unreadable');
          } else if (tagged) {
            secondary = certificate.keyAlgorithmName;
          } else {
            final until = context.t('piv.slot.untilDate', {'date': DateFormat.yMMMd(locale).format(certificate.notAfter.toLocal())});
            secondary = '${certificate.keyAlgorithmName} · $until';
          }
          return GroupRow(
            first: index == 0,
            icon: tile,
            accent: true,
            primary: name,
            secondary: secondary,
            tag: tagged
                ? PopIn(
                    delay: _step(5),
                    child: KeyStandingTag(standing: standing),
                  )
                : null,
            onTap: tap(() => showPivSlotSheet(context, piv, slot)),
          );
      }
    }

    final pinTries = state.pinTries;
    final pukTries = state.pukTries;
    final factory = state.factoryManagementKey ?? false;
    final note = pivNoteFor(notes, state.keyId);
    final bothBlocked = state.pinBlocked && state.pukBlocked;
    // Known only from metadata: no try is spent to find out.
    final factoryPin = state.pin?.isDefault ?? false;
    final factoryPuk = state.puk?.isDefault ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Rise(
          delay: _step(1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(context.t('piv.caption'), style: AppType.caption.copyWith(color: p.textSecondary)),
          ),
        ),
        const SizedBox(height: 14),
        GroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final (index, slot) in PivSlot.values.indexed) Rise(delay: _step(index + 1), child: slotRow(index, slot))],
          ),
        ),
        if (bothBlocked) ...[
          const SizedBox(height: 14),
          AppAlert(severity: AlertSeverity.error, child: Text(context.t('piv.codes.bothBlocked'))),
          if (state.makerCommands) ...[
            const SizedBox(height: 10),
            OutlinedButton(onPressed: tap(() => startPivReset(context, piv, finishing: true)), child: Text(context.t('piv.reset.finish'))),
          ],
        ],
        Rise(delay: _step(4), child: SectionLabel(context.t('piv.codes'))),
        Rise(
          delay: _step(4),
          child: GroupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GroupRow(
                  first: true,
                  primary: context.t('piv.pin'),
                  secondary: state.pinBlocked ? context.t('piv.pin.blockedRow') : null,
                  value: pinTries == null || state.pinBlocked ? null : Text(context.t('piv.triesLeft', {'count': pinTries})),
                  onTap: tap(() => showPivCodeSheet(context, piv, PivCode.pin)),
                ),
                GroupRow(
                  primary: context.t('piv.puk'),
                  value: pukTries == null
                      ? null
                      : Text(state.pukBlocked ? context.t('piv.puk.blockedRow') : context.t('piv.triesLeft', {'count': pukTries})),
                  onTap: tap(() => showPivCodeSheet(context, piv, PivCode.puk)),
                ),
                GroupRow(
                  primary: context.t('piv.managementKey'),
                  value: factory || state.factoryManagementKey == null
                      ? null
                      : Text(context.t(note != null ? 'piv.managementKey.inVault' : 'piv.managementKey.changed')),
                  tag: factory
                      ? PopIn(
                          delay: _step(6),
                          child: StatusTag(label: context.t('piv.factoryDefault'), tone: StatusTone.danger),
                        )
                      : null,
                  onTap: tap(() => showPivManagementKeySheet(context, piv)),
                ),
              ],
            ),
          ),
        ),
        if (factoryPin || factoryPuk) ...[
          const SizedBox(height: 14),
          Rise(
            delay: _step(5),
            child: AppAlert(
              severity: AlertSeverity.warning,
              child: Text(
                context.t('piv.codes.factory', {
                  'codes': factoryPin && factoryPuk
                      ? 'both'
                      : factoryPin
                      ? 'pin'
                      : 'puk',
                }),
              ),
            ),
          ),
        ],
        if (factory) ...[
          const SizedBox(height: 14),
          Rise(
            delay: _step(5),
            child: AppAlert(severity: AlertSeverity.warning, child: Text(context.t('piv.defaultWarning'))),
          ),
          const SizedBox(height: 18),
          Rise(
            delay: _step(6),
            child: state.makerCommands
                ? FilledButton(
                    style: largeButtonStyle,
                    onPressed: tap(() => showPivManagementKeySheet(context, piv)),
                    child: Text(context.t('piv.changeManagementKey')),
                  )
                : Text(
                    context.t('piv.managementKey.cannot'),
                    textAlign: TextAlign.center,
                    style: AppType.caption.copyWith(color: p.textSecondary),
                  ),
          ),
        ],
        if (state.makerCommands) ...[
          const SizedBox(height: 8),
          Rise(
            delay: _step(6),
            child: Group(
              children: [
                GroupRow(first: true, danger: true, primary: context.t('piv.reset.row'), onTap: tap(() => startPivReset(context, piv))),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
