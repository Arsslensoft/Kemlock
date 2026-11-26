import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell_page.dart';
import '../../core/now.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/key_account.dart';
import '../../models/otp_account.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../backup/backup_status.dart';
import '../export/export_sheet.dart';
import '../security_keys/key_codes.dart';
import '../security_keys/key_codes_flow.dart';
import '../settings/prefs.dart';
import 'account_card.dart';
import 'account_sheet.dart';
import 'add_account_sheet.dart';
import 'key_account_card.dart';
import 'service_names.dart';
import 'service_tile.dart';
import 'tag_input.dart';

/// A–Z ignoring case and accents, as `localeCompare` with base sensitivity.
int _byName(OtpAccount a, OtpAccount b) => fold(displayName(a)).compareTo(fold(displayName(b)));

/// The custom order; accounts added since it was last set have none and go last, oldest first.
int _byCustomOrder(OtpAccount a, OtpAccount b) {
  final order = (a.order ?? double.maxFinite).compareTo(b.order ?? double.maxFinite);
  if (order != 0) return order;
  final added = a.addedAt.compareTo(b.addedAt);
  return added != 0 ? added : _byName(a, b);
}

/// [list] sorted by [compare], keeping the order of entries that compare
/// equal, as JavaScript's sort does.
List<OtpAccount> _sorted(Iterable<OtpAccount> list, Comparator<OtpAccount> compare) {
  final sorted = [...list];
  mergeSort(sorted, compare: compare);
  return sorted;
}

enum _Section { pinned, rest }

enum _SortChoice { name, custom, reorder }

/// The Codes tab, `routes/accounts.tsx`: the vault's accounts with their
/// codes under one 30-second clock, searched, filtered by tag, pinned ones
/// first, A–Z or in the user's own order, which can be changed by moving
/// accounts up and down. It reminds the user to back up once a
/// few entries are in no backup, and offers to add the first account when
/// there is none. The accounts kept on a security key come under the
/// vault's own, a section for each key (openspec: add-security-key-codes).
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  final _query = TextEditingController();
  final _sortButton = GlobalKey();
  String? _tag;
  var _reordering = false;

  late final KeyCodesController _keyCodes = ref.read(keyCodesProvider.notifier);

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    // While the tab is on screen, a key that stays plugged in keeps its codes fresh.
    _keyCodes.listening(true);
  }

  @override
  void dispose() {
    _query.dispose();
    final keyCodes = _keyCodes;
    // Not while the tree is being taken down: it may change what widgets watch.
    scheduleMicrotask(() => keyCodes.listening(false));
    super.dispose();
  }

  VaultController get _vault => ref.read(vaultControllerProvider.notifier);

  Future<void> _delete(String id) async {
    final account = ref.read(vaultControllerProvider).accounts.firstWhereOrNull((a) => a.id == id);
    if (account == null) return;
    final p = context.palette;
    // The name in bold inside the sentence, as the web app's <strong>
    const marker = '\u{0}';
    final parts = context.t('app.deleteAccount.body', {'name': marker}).split(marker);
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('app.deleteAccount.title'),
      body: Text.rich(
        TextSpan(
          children: [
            for (final (i, part) in parts.indexed) ...[
              if (i > 0)
                TextSpan(
                  text: displayName(account),
                  style: TextStyle(fontWeight: FontWeight.w700, color: p.text),
                ),
              TextSpan(text: part),
            ],
          ],
        ),
      ),
      cancelLabel: context.t('app.deleteAccount.cancel'),
      confirmLabel: context.t('app.deleteAccount.confirm'),
    );
    if (confirmed && mounted) await _vault.deleteAccount(account);
  }

  void _copied(OtpAccount account) => ref.read(toastsProvider.notifier).show(context.t('accounts.copied', {'name': displayName(account)}));

  Future<void> _chooseSort(_SortChoice choice) async {
    if (choice == _SortChoice.name) {
      ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(accountSort: AccountSort.name));
      return;
    }
    final accounts = ref.read(vaultControllerProvider).accounts;
    // Start the custom order from what the user sees now, not from the order accounts were added
    if (accounts.every((a) => a.order == null)) {
      final pinnedFirst = _sorted(accounts, (a, b) {
        final pinned = (b.pinned == true ? 1 : 0) - (a.pinned == true ? 1 : 0);
        return pinned != 0 ? pinned : _byName(a, b);
      });
      unawaited(_vault.reorderAccounts([for (final a in pinnedFirst) a.id]));
    }
    ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(accountSort: AccountSort.custom));
    if (choice == _SortChoice.reorder) {
      _query.clear();
      setState(() {
        _tag = null;
        _reordering = true;
      });
    }
  }

  Future<void> _openSortMenu(AccountSort sort) async {
    final box = _sortButton.currentContext!.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
    final bottomRight = box.localToGlobal(box.size.bottomRight(const Offset(0, 4)), ancestor: overlay);
    final b = context.bmc;
    final p = context.palette;

    PopupMenuEntry<_SortChoice> item(_SortChoice choice, IconData icon, String label, {bool selected = false}) => PopupMenuItem(
      value: choice,
      padding: EdgeInsets.zero,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        color: selected ? p.selected : null,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: p.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: AppType.body1.copyWith(color: p.text)),
            ),
            if (selected) ...[const SizedBox(width: 16), Icon(Icons.check_rounded, size: 20, color: b.accentText)],
          ],
        ),
      ),
    );

    final choice = await showMenu<_SortChoice>(
      context: context,
      position: RelativeRect.fromRect(Rect.fromPoints(topLeft, bottomRight), Offset.zero & overlay.size),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      items: [
        item(_SortChoice.name, Icons.sort_by_alpha_rounded, context.t('accounts.sort.name'), selected: sort == AccountSort.name),
        item(
          _SortChoice.custom,
          Icons.format_list_numbered_rounded,
          context.t('accounts.sort.custom'),
          selected: sort == AccountSort.custom,
        ),
        item(_SortChoice.reorder, Icons.swap_vert_rounded, context.t('accounts.reorder')),
      ],
    );
    if (choice != null && mounted) await _chooseSort(choice);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final accounts = ref.watch(vaultControllerProvider.select((s) => s.accounts));
    final keyAccounts = ref.watch(vaultControllerProvider.select((s) => s.keyAccounts));
    final services = ref.watch(vaultControllerProvider.select((s) => s.backupServices));
    final prefs = ref.watch(prefsProvider);

    final sort = prefs.accountSort;
    final compare = sort == AccountSort.custom ? _byCustomOrder : _byName;

    final allTags = {for (final a in accounts) ...?a.tags, for (final a in keyAccounts) ...?a.tags}.toList();
    mergeSort(allTags, compare: (a, b) => fold(a).compareTo(fold(b)));
    // A filter on a tag that no longer exists shows everything
    final activeTag = _tag != null && allTags.contains(_tag) ? _tag : null;
    final tagged = activeTag == null ? accounts : accounts.where((a) => a.tags?.contains(activeTag) ?? false);

    final q = _query.text.trim().toLowerCase();
    final matches = q.isEmpty
        ? const <OtpAccount>[]
        : _sorted(tagged.where((a) => '${a.name ?? ''} ${a.issuer} ${a.label}'.toLowerCase().contains(q)), _byName);
    final pinned = q.isNotEmpty ? const <OtpAccount>[] : _sorted(tagged.where((a) => a.pinned == true), compare);
    final rest = q.isNotEmpty ? matches : _sorted(tagged.where((a) => a.pinned != true), compare);

    // The accounts on security keys: a section for each key, in the order the keys were first
    // read, each A to Z. The tag filter and the search cover them as they do the vault's.
    final keyGroups = <String, List<KeyAccount>>{};
    for (final a in keyAccounts) {
      if (activeTag != null && !(a.tags?.contains(activeTag) ?? false)) continue;
      if (q.isNotEmpty && !'${a.issuer} ${a.label} ${a.tags?.join(' ') ?? ''} ${a.note ?? ''}'.toLowerCase().contains(q)) continue;
      (keyGroups[a.device] ??= []).add(a);
    }
    for (final group in keyGroups.values) {
      mergeSort(group, compare: (a, b) => fold(a.displayName).compareTo(fold(b.displayName)));
    }
    final total = accounts.length + keyAccounts.length;

    final backedUpUntil = math.max(prefs.lastBackupAt ?? 0, prefs.backupNudgeDismissedAt ?? 0);
    final unbacked = entriesSince(accounts, services, backedUpUntil == 0 ? null : backedUpUntil);

    void move(_Section section, int index, int delta) {
      final list = [...(section == _Section.pinned ? pinned : rest)];
      final target = index + delta;
      if (target < 0 || target >= list.length) return;
      final moved = list[index];
      list[index] = list[target];
      list[target] = moved;
      final ordered = section == _Section.pinned ? [...list, ...rest] : [...pinned, ...list];
      unawaited(_vault.reorderAccounts([for (final a in ordered) a.id]));
    }

    Widget list(List<OtpAccount> list, int offset, _Section section) => _ListCard(
      children: [
        for (final (i, account) in list.indexed)
          _reordering
              ? _ReorderRow(
                  key: ValueKey(account.id),
                  account: account,
                  divider: i > 0,
                  canMoveUp: i > 0,
                  canMoveDown: i < list.length - 1,
                  onMove: (delta) => move(section, i, delta),
                )
              : AccountCard(
                  key: ValueKey(account.id),
                  account: account,
                  index: offset + i,
                  divider: i > 0,
                  onDelete: (id) => unawaited(_delete(id)),
                  onUpdate: (updated) => unawaited(_vault.updateAccount(updated)),
                  onCopied: _copied,
                  allTags: allTags,
                ),
      ],
    );

    String sectionTitle() {
      if (q.isNotEmpty) return context.t('accounts.section.results');
      if (activeTag != null) return context.t('accounts.section.tagged', {'tag': activeTag});
      return context.t(keyAccounts.isEmpty ? 'accounts.section.all' : 'accounts.section.inVault');
    }

    return ShellPage(
      children: [
        // Status and lock
        SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                height: 30,
                padding: const EdgeInsets.only(left: 9, right: 12),
                decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(999)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gpp_good_outlined, size: 16, color: b.accentText),
                    const SizedBox(width: 6),
                    Text(
                      context.t('accounts.encrypted'),
                      style: TextStyle(fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, color: b.accentText),
                    ),
                  ],
                ),
              ),
              PressScale(
                scale: 0.94,
                child: IconButton(
                  onPressed: () => _vault.lock(),
                  tooltip: context.t('app.tooltip.lockVault'),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: p.paper,
                    foregroundColor: p.textSecondary,
                    fixedSize: const Size.square(40),
                    minimumSize: const Size.square(40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: CircleBorder(side: BorderSide(color: p.divider)),
                  ),
                  icon: const Icon(Icons.lock_rounded, size: 18),
                ),
              ),
            ],
          ),
        ),

        PageTitle(title: context.t('nav.codes'), count: total > 0 ? total : null, trailing: total > 0 ? const _GlobalClock() : null),

        if (unbacked >= nudgeAt && !_reordering)
          _BackupNudge(
            count: unbacked,
            onBackUp: () => unawaited(showExportSheet(context)),
            onDismiss: () {
              final now = ref.read(clockProvider)().millisecondsSinceEpoch;
              ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(backupNudgeDismissedAt: now));
            },
          ),

        if (total == 0)
          EmptyState(
            icon: const Icon(Icons.password_rounded),
            title: context.t('app.empty.otp.title'),
            body: context.t('app.empty.otp.body'),
            action: FilledButton.icon(
              onPressed: () => unawaited(showAddAccountSheet(context)),
              style: largeButtonStyle,
              icon: const Icon(Icons.add_rounded),
              label: Text(context.t('app.empty.otp.action')),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: _reordering
                ? ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 46),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(context.t('accounts.reorder.hint'), style: AppType.body2.copyWith(color: p.textSecondary)),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(onPressed: () => setState(() => _reordering = false), child: Text(context.t('accounts.reorder.done'))),
                      ],
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: SearchField(
                          controller: _query,
                          label: context.t('accounts.searchLabel'),
                          hint: context.t('accounts.search', {'count': total}),
                          clearLabel: context.t('accounts.clearSearch'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PressScale(
                        scale: 0.94,
                        child: IconButton(
                          key: _sortButton,
                          onPressed: () => unawaited(_openSortMenu(sort)),
                          tooltip: context.t('accounts.sort'),
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(
                            backgroundColor: p.paper,
                            foregroundColor: p.textSecondary,
                            fixedSize: const Size.square(46),
                            minimumSize: const Size.square(46),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                              side: BorderSide(color: p.divider),
                            ),
                          ),
                          icon: const Icon(Icons.sort_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
          ),

          if (allTags.isNotEmpty && !_reordering)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _TagFilter(tags: allTags, active: activeTag, onSelect: (tag) => setState(() => _tag = tag)),
            ),

          if (pinned.isNotEmpty) ...[
            SectionLabel(context.t('accounts.section.pinned'), padding: const EdgeInsets.fromLTRB(6, 28, 6, 8)),
            list(pinned, 0, _Section.pinned),
          ],

          if (rest.isNotEmpty) ...[
            SectionLabel(sectionTitle(), padding: const EdgeInsets.fromLTRB(6, 28, 6, 8)),
            list(rest, pinned.length, _Section.rest),
          ],

          if (!_reordering) ...[
            for (final (n, group) in keyGroups.values.indexed) ...[
              _KeySectionLabel(keyName: group.map((a) => a.keyName).nonNulls.firstOrNull),
              _ListCard(
                children: [
                  for (final (i, account) in group.indexed)
                    KeyAccountCard(
                      key: ValueKey(account.id),
                      account: account,
                      index: pinned.length + rest.length + keyGroups.values.take(n).fold<int>(0, (sum, other) => sum + other.length) + i,
                      divider: i > 0,
                      allTags: allTags,
                    ),
                ],
              ),
            ],
            if (keyAccounts.isNotEmpty && q.isEmpty) const _KeyCodesFooter(),
          ],

          if (q.isNotEmpty && matches.isEmpty && keyGroups.isEmpty)
            EmptyState(
              icon: const Icon(Icons.search_rounded),
              title: context.t('accounts.noMatches.title', {'query': _query.text.trim()}),
              body: context.t('accounts.noMatches.body'),
            ),

          if (q.isEmpty && !_reordering)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                context.t('accounts.hint'),
                textAlign: TextAlign.center,
                style: AppType.caption.copyWith(color: b.faint),
              ),
            ),
        ],
      ],
    );
  }
}

/// The ring beside the title: the seconds left in the shared 30-second window.
class _GlobalClock extends ConsumerWidget {
  const _GlobalClock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = remainingIn(ref.watch(nowSecondsProvider), 30);
    return Semantics(
      container: true,
      image: true,
      label: context.t('accounts.clock', {'seconds': remaining}),
      excludeSemantics: true,
      child: CountdownRing(remaining: remaining, period: 30, label: true),
    );
  }
}

/// The title of a key's section: "On your YubiKey".
class _KeySectionLabel extends StatelessWidget {
  const _KeySectionLabel({required this.keyName});

  /// The key's name as it gave it; a key read over NFC gives none.
  final String? keyName;

  @override
  Widget build(BuildContext context) => SectionLabel(
    keyName == null ? context.t('accounts.section.onKeyUnnamed') : context.t('accounts.section.onKey', {'key': keyName}),
    padding: const EdgeInsets.fromLTRB(6, 28, 6, 8),
  );
}

/// Under the last key's section: how long ago a key was read, that these
/// secrets never leave it, and the button that reads it (again).
class _KeyCodesFooter extends ConsumerWidget {
  const _KeyCodesFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = context.bmc;
    final readAt = ref.watch(keyCodesProvider.select((state) => state.readAt));
    final busy = ref.watch(keyCodesProvider.select((state) => state.activity != KeyCodesActivity.idle));
    final String note;
    if (readAt == null) {
      note = context.t('keyCodes.neverLeave');
    } else {
      final seconds = math.max(0, ref.watch(nowSecondsProvider) - readAt);
      note = '${context.t('keyCodes.readAgo', {'seconds': seconds})} ${context.t('keyCodes.neverLeave')}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 0),
          child: Text(note, style: AppType.caption.copyWith(color: b.faint)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton(
            onPressed: busy ? null : () => unawaited(readKeyCodes(context, ref)),
            style: largeButtonStyle,
            child: Text(context.t(readAt == null ? 'keyCodes.read' : 'keyCodes.readAgain')),
          ),
        ),
      ],
    );
  }
}

/// The search box: a paper field with a search icon, and a clear button
/// once something is typed. Its border lights up while it has focus.
/// The tag chips under the search box, All first, scrolling sideways to
/// the screen's edges.
class _TagFilter extends StatelessWidget {
  const _TagFilter({required this.tags, required this.active, required this.onSelect});

  final List<String> tags;
  final String? active;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: context.t('accounts.tagFilter'),
    child: LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: 32,
        // Out to the screen's edges, as the web app's negative margin did
        child: OverflowBox(
          minWidth: constraints.maxWidth + 32,
          maxWidth: constraints.maxWidth + 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final (i, tag) in [null, ...tags].indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                TagChip(
                  label: tag ?? context.t('accounts.tag.all'),
                  medium: true,
                  outlined: true,
                  selected: tag == active,
                  onTap: () => onSelect(tag),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// The rounded card the accounts of a section sit in.
class _ListCard extends StatelessWidget {
  const _ListCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.divider),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}

/// An account in reorder mode: its name with buttons to move it up or down.
class _ReorderRow extends StatelessWidget {
  const _ReorderRow({
    super.key,
    required this.account,
    required this.divider,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMove,
  });

  final OtpAccount account;
  final bool divider;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = accountTitle(context, account);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (divider) Container(height: 1, margin: const EdgeInsets.only(left: 72, right: 14), color: p.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
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
                      style: TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w600, height: 1.4, color: p.text),
                    ),
                    if (accountSubLabel(account).isNotEmpty)
                      Text(
                        accountSubLabel(account),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: fontSans, fontSize: 13, height: 1.4, color: p.textSecondary),
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: canMoveUp ? () => onMove(-1) : null,
                tooltip: context.t('accounts.reorder.up', {'name': name}),
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton(
                onPressed: canMoveDown ? () => onMove(1) : null,
                tooltip: context.t('accounts.reorder.down', {'name': name}),
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Reminds the user that recently added entries aren't in any backup yet.
class _BackupNudge extends StatelessWidget {
  const _BackupNudge({required this.count, required this.onBackUp, required this.onDismiss});

  final int count;
  final VoidCallback onBackUp;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: b.warnSoft,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.divider),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined, color: p.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Text(context.t('accounts.backupNudge', {'count': count}), style: AppType.body2.copyWith(color: p.text)),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: onBackUp, style: smallButtonStyle, child: Text(context.t('settings.health.backUp'))),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDismiss,
              tooltip: context.t('accounts.backupNudge.dismiss'),
              color: p.textSecondary,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}
