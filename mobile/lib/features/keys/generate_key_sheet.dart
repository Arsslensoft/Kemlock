import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'key_bridge.dart';

/// Makes a new key pair on the phone and puts it in the vault.
Future<void> showGenerateKeySheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('keys.generate.title'), builder: (_) => const GenerateKeySheet());

/// Starts a key's generation; tests replace it with one that needs no isolate.
final keyGeneratorProvider = Provider<crypto.KeyGeneration Function(crypto.KeyRequest request)>((ref) => crypto.generateKey);

/// The kinds the sheet makes.
const _kinds = [crypto.KeyKind.ssh, crypto.KeyKind.signing, crypto.KeyKind.exchange, crypto.KeyKind.pgp];

/// The PGP key types, in the order of their cards (design decision 12 of
/// add-post-quantum-pgp), and the one chosen first.
const _pgpTypes = [crypto.PgpKeyType.ed25519, crypto.PgpKeyType.pqStandard, crypto.PgpKeyType.pqGnupg, crypto.PgpKeyType.rsa4096];
const _defaultPgpType = crypto.PgpKeyType.pqStandard;

/// The expiries offered, in years; null is never.
const _expiryChoices = <int?>[1, 2, 5, null];

/// The expiry a PGP key gets unless changed: two years, which the key's
/// sheet can push back since add-pgp-key-editing (design decision 11).
const pgpDefaultExpiryYears = 2;

String _expiryLabel(BuildContext context, int? years) =>
    context.t(years == null ? 'keys.generate.expires.never' : 'keys.generate.expires.in$years');

/// The generate sheet: the kind, its algorithm (Ed25519 for SSH and
/// signing keys, X25519 for exchange keys, unless changed), a name, and for
/// a PGP key the name and email of its user ID and when it expires. A PGP
/// key's type is chosen from cards that say who reads each, the standard
/// post-quantum one first. The key is made in a background isolate; the
/// sheet shows that it is working and offers Cancel, which adds nothing. A
/// vault that locks meanwhile gets nothing.
class GenerateKeySheet extends ConsumerStatefulWidget {
  const GenerateKeySheet({super.key});

  @override
  ConsumerState<GenerateKeySheet> createState() => _GenerateKeySheetState();
}

class _GenerateKeySheetState extends ConsumerState<GenerateKeySheet> {
  var _kind = crypto.KeyKind.ssh;
  crypto.GeneratedAlgorithm _algorithm = crypto.generatedAlgorithms[crypto.KeyKind.ssh]!.first;
  var _pgpType = _defaultPgpType;
  int? _expiryYears = pgpDefaultExpiryYears;
  final _name = TextEditingController();
  final _email = TextEditingController();
  var _tried = false;
  crypto.KeyGeneration? _running;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _email.addListener(() => setState(() {}));
    // A vault that locks while a key is made gets none of it
    ref.listenManual(vaultControllerProvider.select((state) => state.session), (_, session) {
      if (session == null) _running?.cancel();
    });
  }

  @override
  void dispose() {
    _running?.cancel();
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  bool get _pgp => _kind == crypto.KeyKind.pgp;
  bool get _nameMissing => _name.text.trim().isEmpty;
  bool get _emailMissing => _pgp && _email.text.trim().isEmpty;

  void _pickKind(crypto.KeyKind kind) => setState(() {
    _kind = kind;
    if (kind != crypto.KeyKind.pgp) _algorithm = crypto.generatedAlgorithms[kind]!.first;
  });

  Future<void> _generate() async {
    setState(() => _tried = true);
    if (_nameMissing || _emailMissing) return;
    final name = _name.text.trim();
    final email = _email.text.trim();
    final request = _pgp
        ? crypto.PgpKeyRequest(name: name, email: email, type: _pgpType, expiresInYears: _expiryYears)
        : crypto.NewKeyRequest(_kind, _algorithm);
    final session = ref.read(vaultControllerProvider).session;
    final generation = ref.read(keyGeneratorProvider)(request);
    setState(() => _running = generation);
    final result = await generation.result;
    if (!mounted) return;
    setState(() => _running = null);
    // Cancelled, or the vault locked or changed while it was made
    if (result is! crypto.KeyGenerated || ref.read(vaultControllerProvider).session != session || session == null) return;
    final key = vaultKeyOf(result.key, id: newUuid(), name: _pgp ? '$name <$email>' : name, origin: KeyOrigin.generated);
    final added = await ref.read(vaultControllerProvider.notifier).addKey(key);
    if (added && mounted) Navigator.of(context).pop();
  }

  void _cancel() {
    _running?.cancel();
    setState(() => _running = null);
  }

  /// The expiry menu, under the row's right end, as Settings' menus are.
  Future<void> _chooseExpiry(BuildContext row) async {
    final box = row.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(row, rootNavigator: true).overlay!.context.findRenderObject()! as RenderBox;
    final corner = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final p = context.palette;
    final chosen = await showMenu<(int?,)>(
      context: row,
      useRootNavigator: true,
      position: RelativeRect.fromLTRB(corner.dx, corner.dy, overlay.size.width - corner.dx, overlay.size.height - corner.dy),
      constraints: const BoxConstraints(minWidth: 160),
      items: [
        for (final years in _expiryChoices)
          PopupMenuItem(
            value: (years,),
            child: Semantics(
              inMutuallyExclusiveGroup: true,
              checked: years == _expiryYears,
              child: Row(
                children: [
                  Opacity(
                    opacity: years == _expiryYears ? 1 : 0,
                    child: Icon(Icons.check_rounded, size: 20, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  Text(_expiryLabel(context, years), style: AppType.body1.copyWith(color: p.text)),
                ],
              ),
            ),
          ),
      ],
    );
    if (chosen != null && mounted) setState(() => _expiryYears = chosen.$1);
  }

  Widget _pgpCards(bool working) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(context.t('keys.generate.algorithm'), style: AppType.caption.copyWith(color: context.palette.textSecondary)),
      const SizedBox(height: 8),
      for (final (i, type) in _pgpTypes.indexed) ...[
        if (i > 0) const SizedBox(height: 8),
        Rise(
          delay: Duration(milliseconds: 40 * i),
          child: OptionCard(
            key: ValueKey('pgp-type-${type.name}'),
            title: context.t('keys.generate.pgp.${type.name}'),
            caption: context.t('keys.generate.pgp.${type.name}.caption'),
            tag: type == _defaultPgpType ? context.t('keys.generate.pgp.recommended') : null,
            selected: type == _pgpType,
            onTap: working ? null : () => setState(() => _pgpType = type),
          ),
        ),
      ],
    ],
  );

  Widget _expiry(bool working) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      GroupCard(
        child: Builder(
          builder: (row) => GroupRow(
            key: const ValueKey('pgp-expiry'),
            first: true,
            primary: context.t('keys.generate.expires'),
            value: Text(_expiryLabel(context, _expiryYears)),
            onTap: working ? null : () => unawaited(_chooseExpiry(row)),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final working = _running != null;
    final algorithms = crypto.generatedAlgorithms[_kind] ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.key_rounded), title: context.t('keys.generate.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedControl<crypto.KeyKind>(
                  options: [for (final kind in _kinds) SegmentOption(value: kind, label: context.t('keys.generate.kind.${kind.name}'))],
                  value: _kind,
                  onChanged: working ? (_) {} : _pickKind,
                  semanticLabel: context.t('keys.generate.kind'),
                  size: SegmentSize.small,
                ),
                const SizedBox(height: 8),
                Text(context.t('keys.generate.kind.${_kind.name}.body'), style: AppType.caption.copyWith(color: p.textSecondary)),
                const SizedBox(height: 16),
                if (_pgp)
                  _pgpCards(working)
                else
                  DropdownButtonFormField<crypto.GeneratedAlgorithm>(
                    isExpanded: true,
                    key: ValueKey(_kind),
                    initialValue: _algorithm,
                    decoration: InputDecoration(labelText: context.t('keys.generate.algorithm')),
                    items: [
                      for (final (i, algorithm) in algorithms.indexed)
                        DropdownMenuItem(
                          value: algorithm,
                          child: Text(
                            i == 0 ? context.t('keys.generate.default', {'name': generatedLabel(algorithm)}) : generatedLabel(algorithm),
                          ),
                        ),
                    ],
                    onChanged: working ? null : (algorithm) => setState(() => _algorithm = algorithm ?? _algorithm),
                  ),
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  enabled: !working,
                  textCapitalization: _pgp ? TextCapitalization.words : TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: context.t(_pgp ? 'keys.generate.pgp.name' : 'keys.generate.name'),
                    hintText: context.t(_pgp ? 'keys.generate.pgp.namePlaceholder' : 'keys.generate.namePlaceholder'),
                    errorText: _tried && _nameMissing
                        ? context.t(_pgp ? 'keys.generate.pgp.nameMissing' : 'keys.generate.nameMissing')
                        : null,
                  ),
                ),
                if (_pgp) ...[
                  const SizedBox(height: 16),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _email,
                    enabled: !working,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: context.t('keys.generate.pgp.email'),
                      hintText: 'ada@example.org',
                      errorText: _tried && _emailMissing ? context.t('keys.generate.pgp.emailMissing') : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _expiry(working),
                ],
                const SizedBox(height: 20),
                if (working) ...[
                  Row(
                    children: [
                      const Spinner(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(context.t('keys.generate.working'), style: AppType.body2.copyWith(color: p.textSecondary)),
                      ),
                      TextButton(onPressed: _cancel, child: Text(context.t('keys.generate.cancel'))),
                    ],
                  ),
                ] else
                  FilledButton.icon(
                    style: largeButtonStyle,
                    onPressed: () => unawaited(_generate()),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text(context.t('keys.generate.button')),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
