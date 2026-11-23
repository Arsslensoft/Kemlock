// A person's spaces on Kemlock Server, listed on the Spaces sheet beside their WebDAV spaces
// (docs/plans/add-server-spaces.md, task 5.1). The two kinds are told apart: a server space is a different thing, with
// members, roles and a chain, and it opens its own sheet (`ServerSpaceSheet`), where a WebDAV space has an invite and Leave.
//
// What the list needs from a signed-in vault comes in through [ServerSpacesSource], so a screen gives it the open
// vault's connection and keys, and a test gives it a fake. With no source (a vault that doesn't sync with Kemlock Server)
// the section isn't shown.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/kemlock_server_spaces.dart';
import '../sync/sync.dart' show Space;
import '../sync/sync_sheet_frame.dart';
import '../sync/sync_store.dart' show syncProvider;
import 'space_bridge.dart' show SpaceOnServerNote;
import 'space_move.dart';
import 'space_policies_provider.dart';
import 'space_scope.dart' show serverSpaceUuidOrNull;
import 'space_state.dart';

/// One space of the account on a server: its id, its name when the chain's name opened, and what the row says
/// ([serverSpaceStatus]).
typedef ServerSpaceEntry = ({String id, String name, String status});

/// The status a row shows for [account] in [state], the verified chain, or `cantBeChecked` when [state] is null: the
/// account's role once confirmed, what an invitation is waiting for, or that the keys need replacing, for whoever may
/// replace them. A confirmed member of a space whose fingerprint this device hasn't compared ([compared] false) is told to
/// compare, which the sheet then asks for.
String serverSpaceStatus(SpaceState? state, String account, {bool accepted = false, bool compared = true}) {
  final me = state?.member(account);
  if (state == null) {
    return 'cantBeChecked';
  }
  if (me == null || !me.inSpace) {
    return 'removed';
  }
  if (me.status == MemberStatus.invited) {
    return accepted ? 'accepted' : 'invited';
  }
  if (!compared) {
    return 'compare';
  }
  final replaces = me.role == SpaceRole.owner || me.role == SpaceRole.admin;
  if (replaces && state.keysNeedReplacing) {
    return 'keysNeedReplacing';
  }
  return me.role.wire;
}

/// The vault's spaces on Kemlock Server, read and opened through its connection.
abstract interface class ServerSpacesSource {
  /// The account's spaces, each with its chain verified.
  Future<List<ServerSpaceEntry>> load();

  /// The sheet of [entry].
  Widget sheetFor(ServerSpaceEntry entry);

  /// Makes a space named [name] with "Everyone" (`buildCreateSpace`), and answers its entry.
  Future<ServerSpaceEntry> make(String name);
}

/// The source of the open vault's server spaces, or null when it has none to show: the vault's sync with Kemlock Server
/// gives it (`kemlockServerSpacesSourceProvider`). A test overrides it.
final serverSpacesSourceProvider = Provider<ServerSpacesSource?>((ref) => ref.watch(kemlockServerSpacesSourceProvider));

/// The key of the notice that the account is in two spaces, one of which allows only one, for tests.
const serverSpacesLeaveOneKey = ValueKey('server-spaces-leave-one');

/// The key of the notice that no space may be made while the account is in a space that allows only one, for tests.
const serverSpacesMakeBlockedKey = ValueKey('server-spaces-make-blocked');

/// What moves a WebDAV space to Kemlock Server and closes its copy: the same open vault's source, when it can. Null for a vault
/// that doesn't sync with Kemlock Server. A test overrides it.
final spaceMoverProvider = Provider<SpaceMover?>((ref) {
  final source = ref.watch(serverSpacesSourceProvider);
  return source is SpaceMover ? source as SpaceMover : null;
});

/// The server spaces on the Spaces sheet.
class ServerSpacesList extends ConsumerStatefulWidget {
  const ServerSpacesList({super.key, this.canMake = true});

  /// Whether Make a space is offered (not while offline mode is on).
  final bool canMake;

  @override
  ConsumerState<ServerSpacesList> createState() => _ServerSpacesListState();
}

class _ServerSpacesListState extends ConsumerState<ServerSpacesList> {
  List<ServerSpaceEntry>? _entries;
  var _failed = false;
  var _making = false;
  var _makeFailed = false;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final source = ref.read(serverSpacesSourceProvider);
    if (source == null) {
      return;
    }
    try {
      final entries = await source.load();
      if (mounted) {
        setState(() {
          _entries = entries;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  Future<void> _open(ServerSpaceEntry entry) async {
    final source = ref.read(serverSpacesSourceProvider);
    if (source == null) {
      return;
    }
    await showAppBottomSheet<void>(context, label: entry.name, builder: (context) => source.sheetFor(entry));
    if (mounted) {
      await _load();
    }
  }

  Future<void> _make() async {
    final source = ref.read(serverSpacesSourceProvider);
    final name = _name.text.trim();
    // One space per member: a member of a space that allows one makes no other (the server has to refuse it too)
    if (source == null || name.isEmpty || ref.read(spacePoliciesProvider).leaveFirstBeforeMaking() != null) {
      return;
    }
    setState(() {
      _making = true;
      _makeFailed = false;
    });
    try {
      await source.make(name);
      _name.clear();
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => _makeFailed = true);
      }
    }
    if (mounted) {
      setState(() => _making = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(serverSpacesSourceProvider);
    if (source == null) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    // A WebDAV space whose note says it is on the server is listed once, with the WebDAV spaces: its UUID is the one every member
    // computes from its WebDAV id. One that is not (an invitation from the Owner of a space this phone holds in WebDAV, which has to
    // be accepted here) shows its row, or the member could never accept it on the phone that holds the file
    final spaces = ref.watch(syncProvider.select((sync) => sync.settings?.spaces ?? const <Space>[]));
    final represented = {
      for (final space in spaces)
        if (space.movedToServer) ?serverSpaceUuidOrNull(space.id),
    };
    final entries = _entries == null
        ? null
        : [
            for (final entry in _entries!)
              if (!represented.contains(entry.id)) entry,
          ];
    final policies = ref.watch(spacePoliciesProvider);
    final leaveOne = policies.leaveOne;
    final blocked = policies.leaveFirstBeforeMaking();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(
          context.t('spaces.server.title'),
          style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w700),
        ),
        if (_failed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('spaces.server.failed'))),
        // A member of two spaces, one of which allows one space per member, has to leave one of them
        if (leaveOne != null)
          AppAlert(
            key: serverSpacesLeaveOneKey,
            severity: AlertSeverity.warning,
            child: Text(context.t('spaces.server.leaveOne', {'single': leaveOne.singleLabel, 'other': leaveOne.otherLabel})),
          ),
        if (entries == null && !_failed) const LinearProgressIndicator(),
        if (entries != null && entries.isEmpty) SheetText(context.t('spaces.server.empty')),
        for (final entry in entries ?? const <ServerSpaceEntry>[])
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.divider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        context.t('spaces.server.row', {'status': entry.status}),
                        key: ValueKey('server-space-status-${entry.id}'),
                        style: AppType.caption.copyWith(color: entry.status == 'cantBeChecked' ? p.error : p.textSecondary),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: ValueKey('server-space-open-${entry.id}'),
                  onPressed: () => _open(entry),
                  child: Text(context.t('spaces.server.open')),
                ),
              ],
            ),
          ),
        if (widget.canMake) ...[
          TextField(
            enableIMEPersonalizedLearning: false,
            key: const ValueKey('server-space-name'),
            controller: _name,
            decoration: InputDecoration(labelText: context.t('spaces.make.name')),
            onChanged: (_) => setState(() {}),
          ),
          if (_makeFailed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('spaces.make.failed'))),
          if (blocked != null)
            AppAlert(
              key: serverSpacesMakeBlockedKey,
              severity: AlertSeverity.info,
              child: Text(context.t('spaces.make.singleSpace', {'space': blocked.label})),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('server-space-make'),
              onPressed: _making || _name.text.trim().isEmpty || blocked != null ? null : _make,
              child: Text(context.t('spaces.server.make')),
            ),
          ),
        ],
      ],
    );
  }
}
