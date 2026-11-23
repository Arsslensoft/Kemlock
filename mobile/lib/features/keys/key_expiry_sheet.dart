import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'key_edit_gate.dart';

/// Changes when a PGP key expires, or one of its subkeys, the one whose
/// fingerprint is [subkey] (openspec: add-pgp-key-editing). Pops true once
/// the change is saved.
Future<bool> showKeyExpirySheet(BuildContext context, VaultKey key, {Uint8List? subkey}) async =>
    await showAppBottomSheet<bool>(
      context,
      label: context.t(subkey == null ? 'keys.change.expiry.title' : 'keys.change.expiry.subkeyTitle'),
      builder: (_) => KeyExpirySheet(keyId: key.id, subkey: subkey),
    ) ??
    false;

/// Picks a date for "On a date…"; tests replace it.
final expiryDatePickerProvider = Provider<Future<DateTime?> Function(BuildContext context, DateTime initial)>(
  (ref) =>
      (context, initial) =>
          showDatePicker(context: context, initialDate: initial, firstDate: DateTime(1970), lastDate: DateTime(2105, 12, 31)),
);

/// The expiries a change offers.
enum ExpiryChoice { oneYear, twoYears, fiveYears, onDate, never }

/// The message id of [choice]'s row.
String expiryChoiceLabelId(ExpiryChoice choice) => switch (choice) {
  ExpiryChoice.oneYear => 'keys.change.expiry.oneYear',
  ExpiryChoice.twoYears => 'keys.change.expiry.twoYears',
  ExpiryChoice.fiveYears => 'keys.change.expiry.fiveYears',
  ExpiryChoice.onDate => 'keys.change.expiry.onDate',
  ExpiryChoice.never => 'keys.change.expiry.never',
};

/// When [choice] made at [now] expires, the date [picked] for
/// [ExpiryChoice.onDate] at noon, or null for never and for a date not yet
/// picked. The years are counted on the calendar of [now].
DateTime? expiryOf(ExpiryChoice choice, DateTime now, {DateTime? picked}) {
  DateTime years(int n) => now.isUtc
      ? DateTime.utc(now.year + n, now.month, now.day, now.hour, now.minute)
      : DateTime(now.year + n, now.month, now.day, now.hour, now.minute);
  return switch (choice) {
    ExpiryChoice.oneYear => years(1),
    ExpiryChoice.twoYears => years(2),
    ExpiryChoice.fiveYears => years(5),
    ExpiryChoice.onDate => picked == null ? null : DateTime(picked.year, picked.month, picked.day, 12),
    ExpiryChoice.never => null,
  };
}

/// The expiry choices as radio rows, each with its date: what the expiry
/// sheet shows, and the subkey sheet's "Expires" dialog. [picked] is the
/// date of "On a date…", which [onPickDate] asks for.
class ExpiryChoices extends StatelessWidget {
  const ExpiryChoices({
    super.key,
    required this.value,
    required this.now,
    required this.onChanged,
    required this.onPickDate,
    this.picked,
    this.error,
  });

  final ExpiryChoice value;
  final DateTime now;
  final DateTime? picked;
  final ValueChanged<ExpiryChoice> onChanged;
  final VoidCallback onPickDate;

  /// Said under the rows: a picked date that is not in the future.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dates = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag());
    String? dateOf(ExpiryChoice choice) {
      if (choice == ExpiryChoice.never) return context.t('keys.change.expiry.neverBody');
      final when = expiryOf(choice, now, picked: picked);
      return when == null ? context.t('keys.change.expiry.pickDate') : dates.format(when);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Group(
          children: [
            for (final (i, choice) in ExpiryChoice.values.indexed)
              GroupRow(
                key: ValueKey('expiry-${choice.name}'),
                first: i == 0,
                icon: Icon(value == choice ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
                accent: value == choice,
                primary: context.t(expiryChoiceLabelId(choice)),
                secondary: dateOf(choice),
                onTap: () {
                  onChanged(choice);
                  if (choice == ExpiryChoice.onDate) onPickDate();
                },
              ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            error!,
            key: const ValueKey('expiry-error'),
            style: AppType.caption.copyWith(color: p.error),
          ),
        ],
      ],
    );
  }
}

/// The expiry sheet: the choices, each with its date; for the key itself
/// a switch "Also the subkeys", on; and Save, which goes through the gate
/// and makes the change.
class KeyExpirySheet extends ConsumerStatefulWidget {
  const KeyExpirySheet({super.key, required this.keyId, this.subkey});

  final String keyId;
  final Uint8List? subkey;

  @override
  ConsumerState<KeyExpirySheet> createState() => _KeyExpirySheetState();
}

class _KeyExpirySheetState extends ConsumerState<KeyExpirySheet> {
  var _choice = ExpiryChoice.twoYears;
  DateTime? _picked;
  var _alsoSubkeys = true;
  var _working = false;

  Future<void> _pickDate() async {
    final now = ref.read(clockProvider)();
    final picked = await ref.read(expiryDatePickerProvider)(context, _picked ?? now.add(const Duration(days: 365)));
    if (picked != null && mounted) setState(() => _picked = picked);
  }

  Future<void> _save(VaultKey key, DateTime? expires) async {
    setState(() => _working = true);
    final outcome = await runPgpChange(
      context,
      ref,
      key: key,
      change: crypto.SetPgpExpiry(expires?.toUtc(), subkey: widget.subkey, alsoSubkeys: widget.subkey == null && _alsoSubkeys),
      doneId: 'keys.change.done.expiry',
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (outcome == PgpChangeOutcome.saved) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(vaultControllerProvider.select((state) => state.keys.firstWhereOrNull((key) => key.id == widget.keyId)));
    final now = ref.watch(clockProvider)();
    final expires = expiryOf(_choice, now, picked: _picked);
    final notFuture = _choice == ExpiryChoice.onDate && expires != null && !expires.isAfter(now);
    final ready = key != null && !_working && !notFuture && (_choice != ExpiryChoice.onDate || expires != null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: const Icon(Icons.event_outlined),
          title: context.t(widget.subkey == null ? 'keys.change.expiry.title' : 'keys.change.expiry.subkeyTitle'),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Rise(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExpiryChoices(
                    value: _choice,
                    now: now,
                    picked: _picked,
                    onChanged: (choice) => setState(() => _choice = choice),
                    onPickDate: () => unawaited(_pickDate()),
                    error: notFuture ? context.t('keys.change.expiry.notFuture') : null,
                  ),
                  if (widget.subkey == null) ...[
                    const SizedBox(height: 12),
                    Group(
                      children: [
                        GroupRow(
                          first: true,
                          icon: const Icon(Icons.account_tree_outlined),
                          primary: context.t('keys.change.expiry.alsoSubkeys'),
                          control: AppSwitch(value: _alsoSubkeys, onChanged: (value) => setState(() => _alsoSubkeys = value)),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: ready ? () => unawaited(_save(key, expires)) : null,
                    child: _working ? const Spinner() : Text(context.t('keys.change.expiry.save')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
