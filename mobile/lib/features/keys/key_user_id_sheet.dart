import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'key_bridge.dart';
import 'key_edit_gate.dart';

/// Adds a user ID to a PGP key (openspec: add-pgp-key-editing). Pops true
/// once the change is saved.
Future<bool> showKeyUserIdSheet(BuildContext context, VaultKey key) async =>
    await showAppBottomSheet<bool>(
      context,
      label: context.t('keys.change.userId.title'),
      builder: (_) => KeyUserIdSheet(keyId: key.id),
    ) ??
    false;

/// The user ID sheet: the name and email address of the generate sheet,
/// with its errors, a switch to make the new one the main user ID, and
/// "Add user ID". A user ID the key has already is refused under the form.
class KeyUserIdSheet extends ConsumerStatefulWidget {
  const KeyUserIdSheet({super.key, required this.keyId});

  final String keyId;

  @override
  ConsumerState<KeyUserIdSheet> createState() => _KeyUserIdSheetState();
}

class _KeyUserIdSheetState extends ConsumerState<KeyUserIdSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  var _makePrimary = false;
  var _tried = false;
  var _working = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _email.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  bool get _nameMissing => _name.text.trim().isEmpty;
  bool get _emailMissing => _email.text.trim().isEmpty;

  /// Whether [key] has the user ID the form makes.
  bool _held(VaultKey key) {
    if (_nameMissing || _emailMissing) return false;
    // As pgpUserId writes it
    final userId = '${_name.text.trim()} <${_email.text.trim()}>';
    return parsedKeyOf(key).pgp?.userIds.contains(userId) ?? false;
  }

  Future<void> _add(VaultKey key) async {
    setState(() => _tried = true);
    if (_nameMissing || _emailMissing || _held(key)) return;
    setState(() => _working = true);
    final outcome = await runPgpChange(
      context,
      ref,
      key: key,
      change: crypto.AddPgpUserId(name: _name.text.trim(), email: _email.text.trim(), makePrimary: _makePrimary),
      doneId: 'keys.change.done.userId',
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (outcome == PgpChangeOutcome.saved) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(vaultControllerProvider.select((state) => state.keys.firstWhereOrNull((key) => key.id == widget.keyId)));
    final held = key != null && _held(key);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.person_add_alt_outlined), title: context.t('keys.change.userId.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Rise(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _name,
                    enabled: !_working,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: context.t('keys.generate.pgp.name'),
                      hintText: context.t('keys.generate.pgp.namePlaceholder'),
                      errorText: _tried && _nameMissing ? context.t('keys.generate.pgp.nameMissing') : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _email,
                    enabled: !_working,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: context.t('keys.generate.pgp.email'),
                      hintText: 'ada@example.org',
                      errorText: _tried && _emailMissing
                          ? context.t('keys.generate.pgp.emailMissing')
                          : held
                          ? context.t('keys.change.userId.duplicate')
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Group(
                    children: [
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.star_outline_rounded),
                        primary: context.t('keys.change.userId.makePrimary'),
                        control: AppSwitch(value: _makePrimary, onChanged: (value) => setState(() => _makePrimary = value)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    style: largeButtonStyle,
                    onPressed: key == null || _working || held ? null : () => unawaited(_add(key)),
                    icon: _working ? const Spinner() : const Icon(Icons.add_rounded),
                    label: Text(context.t('keys.change.userId.add')),
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
