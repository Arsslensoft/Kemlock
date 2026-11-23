// The open vault's spaces on Kemlock Server, as the Spaces sheet lists them and opens them (docs/plans/add-server-spaces.md,
// tasks 5.1 and 5.2). [KmServerSpaces] is the [ServerSpacesSource] a signed-in vault gives the list: it builds each of
// the sheet's closures from `KmSpaceSync` and the session of the sync host, so the chain is read and checked, the
// records are signed with the account's key and the actions go to the space's home.
//
// The account's keys are opened for one request at a time (`KmHost.withAccount`) and wiped when it returns, so nothing
// here keeps them: every closure asks [run] for the connection and the account again.
//
// The server's shapes are the ones its session gave:
//
// - `GET /kem/v1/spaces` answers `[{space: {id, name, keyVersion, ...}, member: {state, acceptedAt?, ...}}]`, where the
//   name is a `kem1` envelope of kind `"space-name"`. A confirmed member opens it through the chain's commitment
//   (`KmSpaceSync.openSpaceName`) and the row shows the real name; an invitee holds no space key yet, and a name that
//   doesn't open shows the start of the id (`space_listing.dart`);
// - a new space is its `create` record, with its seals and names, appended as the first record of
//   `POST /kem/v1/spaces/{newId}/chain`, and the server creates the space from it; the older unchained `POST
//   /kem/v1/spaces` is not used;
// - the invitee's accept is `POST .../members/me/accept` with no body (the member then waits to be confirmed; the accept is no
//   chain record), and the decline `DELETE .../members/me` (`space_invites.dart`);
//
// Behind the sheet's seams (`space_invites.dart`): the lookup of an invitee by email (`GET .../lookup?email=`), whose
// bundle signature is checked, and the resend of an invitation. The offers of
// members who accepted come from `GET .../members` (`space_members.dart`): their bundle, whose self-signature is checked,
// is compared and confirmed from the sheet. What no route gives yet stays out: the replacement of keys (which needs every
// name's text).

library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../crypto/account/bundle.dart';
import '../../crypto/account/encoding.dart' show uuidBytes;
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/kemlock/km_account.dart';
import '../sync/kemlock/km_api.dart';
import '../sync/kemlock/km_backend.dart' show KmSyncResult;
import '../sync/kemlock/km_cache.dart';
import '../sync/kemlock/km_kinds.dart' show kmEntriesOf, kmEntryId;
import '../sync/kemlock/km_move_plan.dart' show kmEntryHash;
import '../sync/removal_guard.dart' show RemovalChoice;
import '../sync/sync.dart' show ScopeState, Space;
import '../sync/sync_merge.dart' show Lists;
import '../sync/sync_store.dart' show syncProvider;
import 'accept_space_sheet.dart';
import 'fingerprint_scan.dart';
import 'server_space_sheet.dart';
import 'server_spaces.dart';
import 'server_spaces_list.dart';
import 'space_actions.dart';
import 'space_bridge.dart';
import 'space_chain.dart';
import 'space_chain_client.dart';
import 'space_contact.dart';
import 'space_head_store.dart';
import 'space_invites.dart';
import 'space_listing.dart';
import 'space_manifest.dart';
import 'space_members.dart';
import 'space_move.dart';
import 'space_notices.dart' show matchingSeenKey;
import 'space_overview.dart';
import 'space_pending.dart';
import 'space_policies.dart' show LeaveFirst, SingleSpaceRefused;
import 'space_scope.dart';
import 'space_state.dart';
import 'space_verify.dart' show ChainAnchor;

/// Runs [action] with a connection to the server in use and the open account, whose keys are wiped when it returns
/// (`KmHost.withAccount`).
typedef KmSessionRun = Future<T> Function<T>(Future<T> Function(KmConnection connection, KmAccount account) action);

/// The storage key of a server space's cache, under the vault's own suffix.
String kmSpaceCacheKey(String space) => 'backmycodes_kemlock_space_$space';

/// The name of the collection every new space starts with.
const everyoneName = 'Everyone';

/// The spaces of one signed-in account on its Kemlock Server.
class KmServerSpaces implements ServerSpacesSource, SpaceMover {
  KmServerSpaces({
    required this.accountId,
    required this.run,
    required this.loadValue,
    required this.saveValue,
    this.loadAnchors,
    this.saveAnchors,
    this.homeDown,
    this.homeUrl,
    this.ownBundle,
    this.chainCrypto = const RealChainCrypto(),
    this.manifestCrypto = const RealSpaceManifestCrypto(),
    this.signRecord = signChainEntry,
    this.clock = DateTime.now,
    this.onChain,
    this.onComparedChain,
    this.onInvitation,
    this.makeBlockedBy,
    this.noticesSeen,
    this.markNoticeSeen,
    this.leaveFirstFor,
    this.onName,
  });

  /// The account whose app this is.
  final String accountId;
  final KmSessionRun run;

  /// The vault's sealed values, for each space's cache.
  final Future<Object?> Function(String key) loadValue;
  final Future<void> Function(String key, Object? value) saveValue;

  /// The anchors of the account's spaces' chains in their stored form (`kmAnchorsOf`), or none to keep none.
  final Future<Map<String, Object?>?> Function()? loadAnchors;
  final Future<void> Function(Map<String, Object?> anchors)? saveAnchors;

  /// The name of the home server while it can't be reached, or null.
  final String? Function()? homeDown;

  /// The home server's address, which a chain record or a sealed key is sent to alone (`KmSpaceSync.homeUrl`).
  final Uri Function()? homeUrl;

  /// This account's own bundle, which its fingerprint is of.
  final Future<KeyBundle?> Function()? ownBundle;

  final ChainCrypto chainCrypto;
  final SpaceManifestCrypto manifestCrypto;
  final Future<SignedChainEntry> Function(SpaceChainEntry entry, Uint8List sig1PrivateKey) signRecord;
  final DateTime Function() clock;

  /// Told every chain a space of this account verified (`KmSpaceSync.onChain`).
  final ChainReport? onChain;

  /// Told every chain of a space whose fingerprint this device compared (`KmSpaceSync.onComparedChain`): the policies are
  /// read from these alone.
  final ChainReport? onComparedChain;

  /// Told each space the list shows the account invited, whose chain this device compared, and whether the server's list says it
  /// accepted: one space per member counts an accepted invitation as being in the space.
  final void Function(String space, String account, SpaceState chain, {required bool accepted})? onInvitation;

  /// The space that forbids making another one (one space per member), or null: asked before a space is made.
  final LeaveFirst? Function()? makeBlockedBy;

  /// The notices of the spaces' policies the member was told, by [matchingSeenKey] (the vault's settings keep them), and
  /// the call that remembers one. Without them a notice is shown as details alone.
  final Map<String, int> Function()? noticesSeen;
  final Future<void> Function(String key, int value)? markNoticeSeen;

  /// The space the account has to leave before it may join [space], whose verified chain is the second argument (one space
  /// per member, from the policies of the chains this phone verified), or null. Without it an invitation is never held back.
  final LeaveFirst? Function(String space, SpaceState chain)? leaveFirstFor;

  /// Told the name of a space whose chain's commitment opened it, which the policies' messages name the space by.
  final void Function(String space, String name)? onName;

  int get _millis => clock().millisecondsSinceEpoch;

  int get _seconds => _millis ~/ 1000;

  KmSpaceSync _sync(String space, KmConnection connection, KmAccount account, {bool joining = false, bool bridged = false}) => KmSpaceSync(
    connection: connection,
    server: connection.server,
    account: account,
    space: space,
    loadCache: () async => KmCache.fromJson(await loadValue(kmSpaceCacheKey(space))),
    saveCache: (cache) => saveValue(kmSpaceCacheKey(space), cache.toJson()),
    loadAnchor: (id) async {
      final load = loadAnchors;
      return load == null ? null : SpaceAnchors.fromJson(await load()).of(id);
    },
    loadCompared: (id) async {
      final load = loadAnchors;
      return load != null && SpaceAnchors.fromJson(await load()).hasCompared(id);
    },
    saveAnchor: (id, anchor, {afterFence = false, compared = false}) async {
      final load = loadAnchors;
      final save = saveAnchors;
      if (load == null || save == null) {
        return;
      }
      final held = SpaceAnchors.fromJson(await load());
      await save(held.remembering(id, anchor, afterFence: afterFence, compared: compared).toJson());
    },
    chainCrypto: chainCrypto,
    manifestCrypto: manifestCrypto,
    signRecord: signRecord,
    clock: clock,
    onChain: onChain,
    onComparedChain: onComparedChain,
    joining: joining,
    carriesClosure: bridged,
    homeDown: homeDown,
    homeUrl: homeUrl,
  );

  /// The account's spaces, as the server lists them.
  Future<List<ListedSpace>> _listed(KmConnection connection) async {
    final raw = await connection.call((token) => connection.api.callValue('GET', connection.server, '/spaces', token: token));
    final seen = <String>{};
    return [
      for (final listed in parseSpaceList(raw))
        // A space the vault's own scopes use, or an id that isn't a UUID, is not one to list
        if (isServerSpaceId(listed.id) && seen.add(listed.id)) listed,
    ];
  }

  /// The ids of the spaces the server lists with this account a confirmed member (`member.state`), which the scheduler
  /// runs as scopes. The chain, not this list, decides what a run does: a space whose chain doesn’t confirm the account
  /// gives an empty document, as it does for a member who left.
  Future<List<String>> confirmedSpaces() => run(
    (connection, account) async => [
      for (final listed in await _listed(connection))
        if (listed.state == 'confirmed') listed.id,
    ],
  );

  /// Syncs [space] once, as the scheduler's scope: the run of `KmSpaceSync.sync`, reporting each chain it verified to
  /// [onChain]. [joining] is for a phone that holds the space's WebDAV copy and has not joined yet: the run needs an anchor the
  /// device already stores and makes none (`KmSpaceSync.joining`). [bridged] is for a moved space whose WebDAV copy this phone still
  /// syncs: a failure after its chain closed the copy carries the closure (`KmSpaceSync.carriesClosure`). Throws what the run throws.
  Future<KmSyncResult> syncSpace(
    String space,
    Lists local,
    ScopeState state, {
    required int now,
    RemovalChoice? choice,
    bool joining = false,
    bool bridged = false,
  }) => run((connection, account) async {
    final result = await _sync(space, connection, account, joining: joining, bridged: bridged).sync(local, state, now: now, choice: choice);
    return (doc: result.doc, known: result.known, state: result.state, skipped: result.skipped);
  });

  /// Whether the server space [space], found for a WebDAV space this phone holds, may be offered to the person to merge into, and
  /// who owns it. Null unless this account compared a fingerprint for it before (an anchor is stored, which is never made here)
  /// and is a confirmed member. Nothing is opened, merged or written. Throws what the read of the chain throws.
  Future<JoinOffer?> joinOffer(String space, {required int now}) => run((connection, account) async {
    final found = await _sync(space, connection, account, joining: true).joinOffer(now: now);
    if (found == null) {
      return null;
    }
    // The names are the server's and only label a row; an ordinary member can't read them
    var names = const <String, String>{};
    try {
      names = (await SpaceMembersClient(
        connection: connection,
        server: connection.server,
        space: space,
        crypto: chainCrypto,
      ).read(found.chain)).names;
    } catch (_) {
      names = const {};
    }
    return (owner: [for (final id in found.owners) names[id] ?? shortId(id)].join(', '));
  });

  @override
  Future<List<ServerSpaceEntry>> load() => run((connection, account) async {
    final entries = <ServerSpaceEntry>[];
    for (final listed in await _listed(connection)) {
      final sync = _sync(listed.id, connection, account);
      SpaceState? state;
      String? name;
      var compared = false;
      try {
        state = await sync.chainState();
        compared = await sync.isCompared();
        if (compared && state.member(account.accountId)?.status == MemberStatus.invited) {
          onInvitation?.call(listed.id, account.accountId, state, accepted: listed.accepted);
        }
        final sealed = listed.sealedName;
        // Opening the name opens the space key, which waits for first contact
        if (sealed != null && compared) {
          try {
            name = await sync.openSpaceName(state, sealed);
          } catch (_) {
            // A name that can't be opened shows the start of the id; the list still loads
            name = null;
          }
        }
      } on SpaceSyncError {
        state = null;
      }
      if (name != null) {
        onName?.call(listed.id, name);
      }
      entries.add((
        id: listed.id,
        name: name ?? shortId(listed.id),
        status: serverSpaceStatus(state, account.accountId, accepted: listed.accepted, compared: compared),
      ));
    }
    return entries;
  });

  @override
  Future<ServerSpaceEntry> make(String name) async {
    // One space per member: a member of a space that allows one makes no other (the server has to refuse it too)
    final blocked = makeBlockedBy?.call();
    if (blocked != null) {
      throw SingleSpaceRefused(blocked);
    }
    return _make(name);
  }

  Future<ServerSpaceEntry> _make(String name) => run((connection, account) async {
    final space = newUuid();
    await _create(connection, account, space, name);
    final state = await _sync(space, connection, account).chainState();
    return (id: space, name: name, status: serverSpaceStatus(state, account.accountId));
  });

  /// Makes the space [space] named [name], with "Everyone": its `create` record, with its seals and names, is `records[0]` of the
  /// chain route of [space], and the server makes the space from it. The keys made for it are wiped when it returns.
  Future<void> _create(KmConnection connection, KmAccount account, String space, String name) async {
    // The `create` is a chain record: it goes to the home alone
    _sync(space, connection, account).requireHome();
    final bundle = KeyBundle(
      accountId: uuidBytes(account.accountId),
      keyVersion: account.keyVersion,
      kx1PublicKey: account.kx1PublicKey,
      sig1PublicKey: account.sig1PublicKey,
    );
    final built = await buildCreateSpace(
      account: account.accountId,
      bundle: bundle,
      bundleSignature: await signBundle(bundle, account.sig1PrivateKey),
      space: space,
      collection: newUuid(),
      name: name,
      collectionName: everyoneName,
      at: _seconds,
    );
    final SignedChainEntry signed;
    try {
      signed = await signRecord(built.action.entry, account.sig1PrivateKey);
      // The `create` is records[0] of the chain route of the new id, with its seals and names: the server makes the space
      await SpaceChainClient(connection: connection, server: connection.server, space: space).append(built.action.request(signed));
    } finally {
      built.spaceKey.fillRange(0, built.spaceKey.length, 0);
      built.collectionKey.fillRange(0, built.collectionKey.length, 0);
    }
    // The maker knows its own chain: first contact is done by construction, once the chain begins with the record it signed
    await _sync(space, connection, account).rememberCreated(signed);
  }

  @override
  Future<SpaceMoveResult> moveSpace({
    required String appSpaceId,
    required String name,
    required Lists local,
    void Function(SpaceMoveStep step, int done, int total)? onProgress,
  }) => run((connection, account) async {
    // Every member's app computes the same UUID from the WebDAV id, so a member who holds the file finds the space
    final uuid = serverSpaceUuid(appSpaceId);
    final sync = _sync(uuid, connection, account);
    onProgress?.call(SpaceMoveStep.create, 0, 1);
    final listed = [
      for (final space in await _listed(connection))
        if (space.id == uuid) space,
    ];
    if (listed.isEmpty) {
      await _create(connection, account, uuid, name);
    } else {
      // Run again after a stop: the space is there. Another member's space is not this move's to fill
      if (listed.single.state != 'confirmed') {
        throw const SpaceMoveError(SpaceMoveProblem.exists);
      }
      if ((await sync.chainState()).member(account.accountId)?.role != SpaceRole.owner) {
        throw const SpaceMoveError(SpaceMoveProblem.notOwner);
      }
      // A phone that never compared the space's fingerprint holds nothing of it (a run opens no key), so it can't carry a move on: the
      // space is opened from the Spaces list first
      if (!await sync.isCompared()) {
        throw const SpaceMoveError(SpaceMoveProblem.exists);
      }
    }
    onProgress?.call(SpaceMoveStep.create, 1, 1);

    // The entries go as the server's members know the space, by its UUID; each keeps its own id inside
    final entries = rescopedTo(local, uuid);
    final sentIds = {
      for (final entry in kmEntriesOf(entries))
        if (kmEntryId(entry).isNotEmpty) kmEntryId(entry),
    };
    onProgress?.call(SpaceMoveStep.upload, 0, sentIds.length);
    // The space's own run: seals each entry into "Everyone", sends them in batches and signs the manifest once. Nothing is
    // known of the space yet, so nothing counts as deleted. It merges what it sends with what the server already holds (a move
    // run again after a stop, or another member's edit), so what the server holds after it is the run's merged document, not the
    // entries that went in
    final merged = await sync.sync(entries, const ScopeState(known: []), now: _millis);
    onProgress?.call(SpaceMoveStep.upload, sentIds.length, sentIds.length);

    // What the read-back must find, under the ids that were sent: the hash of each entry of the merged document. An id the merge
    // dropped was deleted on the server by someone later, and is not expected back
    final sent = {
      for (final entry in kmEntriesOf(merged.doc))
        if (sentIds.contains(kmEntryId(entry))) kmEntryId(entry): kmEntryHash(entry.json),
    };
    onProgress?.call(SpaceMoveStep.check, 0, sent.length);
    final List<String> different;
    try {
      different = await sync.compareMoved(sent, now: _millis);
    } on SpaceSyncError catch (e) {
      throw SpaceMoveError(SpaceMoveProblem.mismatch, detail: e.detail ?? e.issue.name);
    }
    if (different.isNotEmpty) {
      throw SpaceMoveError(SpaceMoveProblem.mismatch, ids: different);
    }
    onProgress?.call(SpaceMoveStep.check, sent.length, sent.length);

    onProgress?.call(SpaceMoveStep.finish, 0, 1);
    await sync.markBridge(closed: false, now: _millis);
    onProgress?.call(SpaceMoveStep.finish, 1, 1);
    return (uuid: uuid, moved: sent.length, doc: merged.doc);
  });

  @override
  Future<void> closeCopy(String appSpaceId) =>
      run((connection, account) => _sync(serverSpaceUuid(appSpaceId), connection, account).markBridge(closed: true, now: _millis));

  /// The space's chain, read and checked.
  Future<SpaceState> readChain(String space) => run((connection, account) => _sync(space, connection, account).chainState());

  @override
  Widget sheetFor(ServerSpaceEntry entry) => _SpaceView(source: this, entry: entry);

  /// What a member does on [space]: each step asks for the account's keys again.
  SpaceActions _actions(String space) => SpaceActions(
    account: accountId,
    readChain: () => readChain(space),
    openKeyring: (state) => run((connection, account) => _sync(space, connection, account).actions().openKeyring(state)),
    append: (request) => run((connection, account) => _sync(space, connection, account).actions().append(request)),
    sign: (entry) => run((connection, account) => _sync(space, connection, account).actions().sign(entry)),
    now: () => _seconds,
  );

  SpacePendingClient _pending(String space, KmConnection connection) =>
      SpacePendingClient(connection: connection, server: connection.server, space: space);

  SpaceInviteClient _invites(String space, KmConnection connection) =>
      SpaceInviteClient(connection: connection, server: connection.server, space: space, crypto: chainCrypto);

  /// The chain of an invitation to [space] for the first-contact screen: nothing of it is stored ([KmSpaceSync.chainForContact]).
  Future<({SpaceState state, List<SignedChainEntry> records, ChainAnchor? anchor})> readContact(String space) =>
      run((connection, account) => _sync(space, connection, account).chainForContact());

  /// Stores the anchor of [space]'s chain and records that its fingerprint was compared, once the inviter's (or the
  /// confirmer's) fingerprint matched, or for a chain the account's own key vouches for ([_SpaceViewState._read]).
  Future<void> rememberAnchor(String space, ChainAnchor anchor) =>
      run((connection, account) => _sync(space, connection, account).rememberAnchor(anchor));

  /// Whether a fingerprint was compared for [space], here or on another device of the account: first contact is done.
  Future<bool> isCompared(String space) => run((connection, account) => _sync(space, connection, account).isCompared());

  /// What the server tells of [space]'s members, read against [chain] (`SpaceMembersClient`): the bundles an admin compares
  /// and confirms, who needs a fresh comparison, and the names.
  Future<SpaceMembers> readMembers(String space, SpaceState chain) => run(
    (connection, account) =>
        SpaceMembersClient(connection: connection, server: connection.server, space: space, crypto: chainCrypto).read(chain),
  );

  /// Confirms [member] over exactly [offer]'s bundle, the one whose digits the admin compared, with this account's key, and
  /// seals the keys they are entitled to (`SpaceActions.confirm`).
  Future<SpaceState> confirmMember(String space, String member, BundleOffer offer) => run(
    (connection, account) => _sync(space, connection, account).actions().confirm(
      member: member,
      bundle: offer.bundle,
      bundleSignature: offer.bundleSignature,
      confirmerSig1PrivateKey: account.sig1PrivateKey,
    ),
  );

  /// Accepts or declines the invitation to [space] (`SpaceInviteClient.answer`).
  Future<void> answerInvitation(String space, {required bool accept}) =>
      run((connection, account) => _invites(space, connection).answer(accept: accept));
}

class _SpaceView extends ConsumerStatefulWidget {
  const _SpaceView({required this.source, required this.entry});

  final KmServerSpaces source;
  final ServerSpaceEntry entry;

  @override
  ConsumerState<_SpaceView> createState() => _SpaceViewState();
}

class _SpaceViewState extends ConsumerState<_SpaceView> {
  SpaceState? _state;
  KeyBundle? _own;

  /// What the server tells of the members beside the chain: the bundles to compare and confirm, and the names.
  var _members = const SpaceMembers();
  var _failed = false;

  /// For an invitation not yet answered: the chain as verified, held back from the device until the fingerprint matched.
  ({SpaceState state, List<SignedChainEntry> records, ChainAnchor? anchor})? _contact;
  FirstContact? _first;
  var _answered = false;

  /// Whether a fingerprint was compared for the space (first contact), here or on another device of the account.
  var _compared = false;

  /// Whether the chain records another key for this account than the one this phone holds, so it is not the space it seems.
  var _ownKeyMismatch = false;

  // What the space's policies ask, read once when the sheet reads the space and not in `build`, which runs again and again while
  // the provider the source came from rebuilds: the record that turned server matching on, whether the member was told of it, and
  // the space to leave before joining.
  int? _since;
  var _matchingSeen = true;
  LeaveFirst? _leaveFirst;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  /// An invitation the person hasn't answered: the row's status says so (`serverSpaceStatus`).
  bool get _unanswered => widget.entry.status == 'invited';

  Future<void> _read() async {
    final source = widget.source;
    final space = widget.entry.id;
    try {
      // First contact is the record that a fingerprint was compared, never the presence of an anchor
      final compared = await source.isCompared(space);
      // An invitation, or a space this device hasn't compared, is read for the first-contact screen: the chain as verified,
      // with nothing stored until the digits matched
      final contact = _unanswered || !compared ? await source.readContact(space) : null;
      final state = contact?.state ?? await source.readChain(space);
      final me = state.member(source.accountId);
      // Throws a StateError when the account isn't in the space, which shows as unreadable
      final first = contact != null && (_unanswered || (me?.isConfirmed ?? false))
          ? firstContact(state: state, chain: contact.records, account: source.accountId)
          : null;
      KeyBundle? own;
      try {
        own = await source.ownBundle?.call();
      } catch (_) {
        own = null;
      }
      // The creator on another device, and an account whose own key signed after it was confirmed, have nothing to compare,
      // but only if the chain records the key this phone holds: a chain a server made up could name the account with its own
      final ownKey =
          first == null ||
          (first.kind != ContactKind.creator && first.kind != ContactKind.vouched) ||
          (own != null && confirmRecordsOwnBundle(state, source.accountId, own));
      // Only an admin is told; for anyone else, or when the server can't say, nothing is offered
      var members = const SpaceMembers();
      if (first == null) {
        try {
          members = await source.readMembers(space, state);
        } catch (_) {
          members = const SpaceMembers();
        }
      }
      // The record that turned server matching on, which a notice shown once is remembered by
      final since = state.flagSince('duplicateMatching');
      final matchingSeen = since == null || (source.noticesSeen?.call()[matchingSeenKey(space)] ?? 0) > since;
      final leaveFirst = _unanswered ? source.leaveFirstFor?.call(space, state) : null;
      if (mounted) {
        setState(() {
          _since = since;
          _matchingSeen = matchingSeen;
          _leaveFirst = leaveFirst;
          _contact = first == null ? null : contact;
          _first = first;
          _state = state;
          _own = own;
          _members = members;
          _compared = compared;
          _ownKeyMismatch = !ownKey;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  /// Answers the invitation, and leaves the sheet when it was declined.
  Future<void> _answer({required bool accept}) async {
    await widget.source.answerInvitation(widget.entry.id, accept: accept);
    if (!mounted) {
      return;
    }
    if (accept) {
      // The chain says "invited" until an admin confirms, so the sheet shows "waiting to be confirmed"
      setState(() => _answered = true);
    } else {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  /// A confirmed member's phone that did first contact opens the space: its anchor is stored as compared (the digits matched,
  /// or the account's own key vouches for the chain), and the sheet reads the space again.
  Future<void> _open(ChainAnchor? anchor) async {
    if (anchor != null) {
      await widget.source.rememberAnchor(widget.entry.id, anchor);
    }
    await _read();
  }

  Widget _accept(BuildContext context, SpaceState state, FirstContact contact, List<SignedChainEntry> records, ChainAnchor? anchor) {
    final source = widget.source;
    return AcceptSpaceSheet(
      contact: contact,
      invited: _unanswered,
      accountRecovery: state.policies['accountRecovery'] == true,
      state: state,
      // An invitee holds no space key, so the name is the start of the id unless the list could open it
      spaceName: widget.entry.name == shortId(widget.entry.id) ? null : widget.entry.name,
      pick: (person) => compareWith(state: state, chain: records, person: person, admittedAt: contact.admittedAt ?? 0),
      scan: () => scanFingerprint(context),
      // The anchor is stored, as compared, only once the digits matched
      onCompared: () async {
        if (anchor != null) {
          await source.rememberAnchor(widget.entry.id, anchor);
          if (mounted) {
            setState(() => _compared = true);
          }
        }
      },
      onAccept: () => _unanswered ? _answer(accept: true) : _open(anchor),
      onDecline: () => unawaited(Navigator.of(context).maybePop()),
      // A confirmed member has no invitation to decline: Decline only leaves the sheet
      onReject: _unanswered ? () => unawaited(_answer(accept: false)) : null,
      leaveFirst: _leaveFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final space = widget.entry.id;
    final state = _state;
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: AppAlert(severity: AlertSeverity.error, child: Text(context.t('spaces.server.failed'))),
      );
    }
    if (state == null) {
      return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
    }
    if (_ownKeyMismatch) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: AppAlert(severity: AlertSeverity.error, child: Text(context.t('accept.ownKey'))),
      );
    }
    final contact = _contact;
    final first = _first;
    final since = _since;
    if (contact != null && first != null && !_answered) {
      return _accept(context, state, first, contact.records, contact.anchor);
    }
    // A moved or joined space whose WebDAV copy this phone still syncs: a grant that hides passwords closes the copy
    final copyOpen = ref.watch(
      syncProvider.select(
        (sync) => (sync.settings?.spaces ?? const <Space>[]).any((space) {
          final note = space.onServer;
          return note != null && note.uuid == widget.entry.id && (note.state == SpaceCopy.bridged || note.state == SpaceCopy.joined);
        }),
      ),
    );
    return ServerSpaceSheet(
      state: state,
      account: source.accountId,
      load: () => source.run((connection, account) => source._pending(space, connection).list()),
      approve: (change, record) => source.run((connection, account) async {
        // The answer to a pending change is a chain record: it goes to the home alone
        source._sync(space, connection, account).requireHome();
        await source._pending(space, connection).approve(change, record);
      }),
      drop: (change) => source.run((connection, account) => source._pending(space, connection).drop(change)),
      sign: (entry) => source.run((connection, account) => source._sync(space, connection, account).actions().sign(entry)),
      reloadState: () => source.readChain(space),
      now: () => source._seconds,
      loadHeld: () => source.run((connection, account) => source._sync(space, connection, account).heldItems(now: source._millis)),
      keepHeld: (id) => source.run((connection, account) => source._sync(space, connection, account).keepHeld(id, now: source._millis)),
      deleteHeld: (id) => source.run((connection, account) => source._sync(space, connection, account).deleteHeld(id, now: source._millis)),
      actions: source._actions(space),
      lookupAccount: (email) => source.run((connection, account) => source._invites(space, connection).lookup(email)),
      resendInvite: (member) => source.run((connection, account) => source._invites(space, connection).resend(member)),
      scan: () => scanFingerprint(context),
      data: SpaceSheetData(
        spaceName: widget.entry.name,
        memberNames: _members.names,
        offers: _members.offers,
        reconfirm: _members.reconfirm,
      ),
      confirmMember: (member, offer) => source.confirmMember(space, member, offer),
      homeDown: source.homeDown?.call(),
      copyOpen: copyOpen,
      ownBundle: _own,
      compared: _compared,
      matchingSeen: _matchingSeen,
      markMatchingSeen: since == null || source.markNoticeSeen == null
          ? null
          : () => source.markNoticeSeen!(matchingSeenKey(space), since + 1),
      onLeft: () => Navigator.of(context).maybePop(),
    );
  }
}
