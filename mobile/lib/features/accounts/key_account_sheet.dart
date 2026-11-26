import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/json.dart';
import '../../models/key_account.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../links/linked_items_section.dart';
import '../security_keys/key_codes_flow.dart';
import 'tag_input.dart';

/// Opens the sheet of an account kept on a security key (openspec:
/// add-security-key-codes, "An on-key account has a sheet of its own").
Future<void> showKeyAccountSheet(BuildContext context, {required KeyAccount account, List<String> allTags = const []}) =>
    showAppBottomSheet<void>(
      context,
      label: keyAccountTitle(context, account),
      builder: (_) => KeyAccountSheet(account: account, allTags: allTags),
    );

/// What the vault knows of an on-key account: its issuer and name, which
/// key holds it, its kind and whether it needs a touch. Its tags and note
/// can be set, and are saved in the vault alone: nothing is sent to the
/// key for them. The secret is on the key, so there is nothing here to
/// show, copy or export it; the sheet says so. Deleting asks first, then
/// needs the key.
class KeyAccountSheet extends ConsumerStatefulWidget {
  const KeyAccountSheet({super.key, required this.account, this.allTags = const []});

  final KeyAccount account;
  final List<String> allTags;

  @override
  ConsumerState<KeyAccountSheet> createState() => _KeyAccountSheetState();
}

class _KeyAccountSheetState extends ConsumerState<KeyAccountSheet> {
  late final _note = TextEditingController(text: widget.account.note ?? '');
  late var _tags = widget.account.tags ?? const <String>[];
  final _tagInput = GlobalKey<TagInputState>();

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool _changed(KeyAccount account) =>
      _note.text.trim() != (account.note ?? '') || !const ListEquality<String>().equals(_tags, account.tags ?? const []);

  Future<void> _save(KeyAccount account) async {
    // A tag still in the field counts, as leaving the field would have added it
    final tags = _tagInput.currentState?.commitDraft() ?? _tags;
    final note = _note.text.trim();
    final saved = await ref
        .read(vaultControllerProvider.notifier)
        .updateKeyAccount(account.copyWith(note: note.isNotEmpty ? note : unset, tags: tags.isNotEmpty ? tags : unset));
    if (saved && mounted) setState(() => _tags = tags);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    // The vault's copy, so a saved tag shows at once; the one given when the vault no longer has it
    final account =
        ref.watch(vaultControllerProvider.select((s) => s.keyAccounts.firstWhereOrNull((a) => a.id == widget.account.id))) ??
        widget.account;
    final name = keyAccountTitle(context, account);
    final subLabel = account.issuer.isNotEmpty ? account.label : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              KeyAccountTile(name: name, size: 54),
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
          const SizedBox(height: 18),
          GroupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GroupRow(
                  first: true,
                  icon: const Icon(Icons.key_rounded),
                  accent: true,
                  primary: context.t('keyCodes.sheet.onKey'),
                  value: Text(account.keyName ?? context.t('securityKeys.model.unknown')),
                ),
                GroupRow(
                  primary: context.t('accountSheet.type'),
                  value: Text(
                    account.isTimeBased
                        ? context.t('keyCodes.sheet.kind.totp', {'period': account.period})
                        : context.t('keyCodes.sheet.kind.hotp'),
                  ),
                ),
                GroupRow(primary: context.t('viewQr.label.algorithm'), value: Text(account.algorithm)),
                GroupRow(
                  primary: context.t('keyCodes.sheet.touch'),
                  value: Text(context.t(account.touch ? 'keyCodes.sheet.touch.yes' : 'keyCodes.sheet.touch.no')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('keyCodes.sheet.secret'))),
          const SizedBox(height: 18),
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
          TagInput(key: _tagInput, value: _tags, onChanged: (next) => setState(() => _tags = next), suggestions: widget.allTags),
          const SizedBox(height: 8),
          Text(context.t('keyCodes.sheet.tagsNote'), style: AppType.caption.copyWith(color: b.faint)),
          LinkedItemsSection(entry: account),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _changed(account) ? () => unawaited(_save(account)) : null,
            style: largeButtonStyle,
            child: Text(context.t('accountSheet.save')),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: PressScale(
              child: TextButton.icon(
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  if (await deleteKeyAccount(context, ref, account) && navigator.mounted) navigator.pop();
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: b.dangerSoft,
                  foregroundColor: p.error,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: Text(context.t('keyCodes.delete')),
              ),
            ),
          ),
          // The way out for a key that is lost, or was erased with another tool: nothing is sent to it.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                if (await forgetKeyCodes(context, ref, account.device) && navigator.mounted) navigator.pop();
              },
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(context.t('keyCodes.forget')),
            ),
          ),
        ],
      ),
    );
  }
}

/// The tile of an account that is on a key: its first letter on the
/// accent colour's soft ground, where a vault account has its service's.
class KeyAccountTile extends StatelessWidget {
  const KeyAccountTile({super.key, required this.name, this.size = 44});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final trimmed = name.trim();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular((size * 0.32).roundToDouble())),
        child: Text(
          trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase(),
          style: TextStyle(
            fontFamily: fontSans,
            fontSize: (size * 0.41).roundToDouble(),
            fontWeight: FontWeight.w600,
            height: 1,
            color: b.accentText,
          ),
        ),
      ),
    );
  }
}
