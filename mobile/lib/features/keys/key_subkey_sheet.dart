import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'key_edit_gate.dart';
import 'key_expiry_sheet.dart';

/// Adds a subkey to a PGP key, made on the phone (openspec:
/// add-pgp-key-editing). Pops true once the change is saved.
Future<bool> showKeySubkeySheet(BuildContext context, VaultKey key) async =>
    await showAppBottomSheet<bool>(
      context,
      label: context.t('keys.change.subkey.title'),
      builder: (_) => KeySubkeySheet(keyId: key.id),
    ) ??
    false;

/// The subkey sheet: what the subkey is for, its type (Curve25519 to
/// encrypt or Ed25519 to sign first, RSA 4096 second, then to encrypt the
/// two post-quantum ones, each saying who reads it; a version 6 key's own
/// post-quantum one alone), when it expires, and "Add subkey". While the subkey is made the sheet shows that it is
/// working and offers Cancel, which adds nothing; a vault that locks
/// meanwhile gets nothing.
class KeySubkeySheet extends ConsumerStatefulWidget {
  const KeySubkeySheet({super.key, required this.keyId});

  final String keyId;

  @override
  ConsumerState<KeySubkeySheet> createState() => _KeySubkeySheetState();
}

class _KeySubkeySheetState extends ConsumerState<KeySubkeySheet> {
  var _use = crypto.PgpSubkeyUse.encrypt;
  var _type = crypto.PgpKeyType.ed25519;
  var _expiry = ExpiryChoice.never;
  DateTime? _picked;
  var _busy = false;
  crypto.KeyGeneration? _running;

  @override
  void dispose() {
    _running?.cancel();
    super.dispose();
  }

  /// Asks when the subkey expires, with the expiry sheet's choices.
  Future<void> _chooseExpiry() async {
    var choice = _expiry;
    var picked = _picked;
    final chosen = await showAppDialog<bool>(
      context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setDialog) {
          final now = ref.read(clockProvider)();
          final when = expiryOf(choice, now, picked: picked);
          final notFuture = choice == ExpiryChoice.onDate && when != null && !when.isAfter(now);
          return AppDialog(
            heading: DialogHeading(title: dialog.t('keys.change.subkey.expires')),
            content: ExpiryChoices(
              value: choice,
              now: now,
              picked: picked,
              onChanged: (next) => setDialog(() => choice = next),
              onPickDate: () async {
                final date = await ref.read(expiryDatePickerProvider)(dialog, picked ?? now.add(const Duration(days: 365)));
                if (date != null) setDialog(() => picked = date);
              },
              error: notFuture ? dialog.t('keys.change.expiry.notFuture') : null,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(dialog.t('export.cancel'))),
              FilledButton(
                onPressed: notFuture || (choice == ExpiryChoice.onDate && when == null) ? null : () => Navigator.of(dialog).pop(true),
                child: Text(dialog.t('keys.change.expiry.save')),
              ),
            ],
          );
        },
      ),
    );
    if (chosen == true && mounted) {
      setState(() {
        _expiry = choice;
        _picked = picked;
      });
    }
  }

  /// The types a subkey of [key] can be, for [_use], with the message of
  /// each (openspec: add-post-quantum-pgp, design decision 14): a version 6
  /// key takes only its own post-quantum kind.
  List<(crypto.PgpKeyType, String)> _types(VaultKey key) {
    final encrypt = _use == crypto.PgpSubkeyUse.encrypt;
    if (_isVersion6(key)) return [(crypto.PgpKeyType.pqStandard, encrypt ? 'keys.change.subkey.pqStandard' : 'keys.change.subkey.mlDsa')];
    return [
      (crypto.PgpKeyType.ed25519, encrypt ? 'keys.change.subkey.curve25519' : 'keys.change.subkey.ed25519'),
      (crypto.PgpKeyType.rsa4096, 'keys.change.subkey.rsa4096'),
      if (encrypt) ...[
        (crypto.PgpKeyType.pqStandard, 'keys.change.subkey.pqStandard'),
        (crypto.PgpKeyType.pqGnupg, 'keys.change.subkey.pqGnupg'),
      ],
    ];
  }

  bool _isVersion6(VaultKey key) {
    try {
      return crypto.readPgpKeyInfo(unb64(key.publicKey ?? key.privateKey)).version == 6;
    } on Exception {
      return false;
    }
  }

  /// The type chosen, or the first offered when it is not offered for [_use].
  crypto.PgpKeyType _typeFor(VaultKey key) {
    final types = _types(key);
    return types.any((t) => t.$1 == _type) ? _type : types.first.$1;
  }

  Future<void> _add(VaultKey key) async {
    setState(() => _busy = true);
    final expires = expiryOf(_expiry, ref.read(clockProvider)(), picked: _picked);
    final outcome = await runPgpChange(
      context,
      ref,
      key: key,
      change: crypto.AddPgpSubkey(type: _typeFor(key), use: _use, expires: expires?.toUtc()),
      doneId: 'keys.change.done.subkey',
      running: (generation) {
        if (mounted) setState(() => _running = generation);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (outcome == PgpChangeOutcome.saved) Navigator.of(context).pop(true);
  }

  void _cancel() {
    _running?.cancel();
    setState(() => _running = null);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final key = ref.watch(vaultControllerProvider.select((state) => state.keys.firstWhereOrNull((key) => key.id == widget.keyId)));
    final working = _running != null;
    final now = ref.watch(clockProvider)();
    final expires = expiryOf(_expiry, now, picked: _picked);
    final expiresText = expires == null
        ? context.t('keys.change.expiry.neverBody')
        : DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(expires);
    final types = key == null ? const <(crypto.PgpKeyType, String)>[] : _types(key);
    final type = key == null ? _type : _typeFor(key);
    // Who reads a post-quantum subkey of a version 4 key
    final readers = key == null || _isVersion6(key)
        ? null
        : switch (type) {
            crypto.PgpKeyType.pqStandard => 'keys.change.subkey.readers.standard',
            crypto.PgpKeyType.pqGnupg => 'keys.change.subkey.readers.gnupg',
            _ => null,
          };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.key_rounded), title: context.t('keys.change.subkey.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Rise(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedControl<crypto.PgpSubkeyUse>(
                    options: [
                      SegmentOption(value: crypto.PgpSubkeyUse.encrypt, label: context.t('keys.change.subkey.encrypt')),
                      SegmentOption(value: crypto.PgpSubkeyUse.sign, label: context.t('keys.change.subkey.sign')),
                    ],
                    value: _use,
                    onChanged: working || _busy ? (_) {} : (use) => setState(() => _use = use),
                    semanticLabel: context.t('keys.change.subkey.use'),
                    size: SegmentSize.small,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<crypto.PgpKeyType>(
                    key: ValueKey((_use, types.length)),
                    isExpanded: true,
                    initialValue: type,
                    decoration: InputDecoration(labelText: context.t('keys.generate.algorithm')),
                    items: [for (final (value, message) in types) DropdownMenuItem(value: value, child: Text(context.t(message)))],
                    onChanged: working || _busy ? null : (type) => setState(() => _type = type ?? _type),
                  ),
                  if (readers != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      context.t(readers),
                      key: const ValueKey('subkey-readers'),
                      style: AppType.caption.copyWith(color: p.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Group(
                    children: [
                      GroupRow(
                        key: const ValueKey('subkey-expires'),
                        first: true,
                        icon: const Icon(Icons.event_outlined),
                        primary: context.t('keys.change.subkey.expires'),
                        value: Text(expiresText),
                        onTap: working || _busy ? null : () => unawaited(_chooseExpiry()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (working)
                    Row(
                      children: [
                        const Spinner(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(context.t('keys.change.subkey.working'), style: AppType.body2.copyWith(color: p.textSecondary)),
                        ),
                        TextButton(onPressed: _cancel, child: Text(context.t('keys.generate.cancel'))),
                      ],
                    )
                  else
                    FilledButton.icon(
                      style: largeButtonStyle,
                      onPressed: key == null || _busy ? null : () => unawaited(_add(key)),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(context.t('keys.change.subkey.add')),
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
