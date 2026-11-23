// A fake Kemlock Server for one space and its members, behind a MockClient, for the tests of the space sync
// (docs/plans/add-server-spaces.md, tasks 3a and 4). It knows what the server's code knows
// (crates/kemlock-api-kem routes/spaces.rs, items.rs and kemlock-domain spaces.rs), and the chain routes the server has
// pinned (the space chain section of docs/crypto.md): `GET .../chain` with `?from=`, `GET .../chain/{seq}/seals`, the
// append `POST` (`201 {link, seq}`, `409 {head}`, `422 {reason, seq}`) and the pending changes (`GET /chain/pending`,
// `POST /chain/pending/{n}`, `DELETE /chain/pending/{n}`). What the server still lacks stays behind "server: to confirm":
//
// - the manifest of a space (`GET` and `PUT
//   /kem/v1/manifests/space:<id>`: PUT needs edit on a collection and answers 423 while the space waits for new keys;
//   GET works for a confirmed member, and a stranger gets 404; counters are per owner);
// - the rules the real server keeps: only a confirmed member with edit on the collection writes an item into it,
//   under that collection's current key version; a write names the revision it replaces and the next revision; a
//   batch is all or none; writes pause while keys wait for replacement (423); every confirmed member is sent every
//   item of the space, with its collection.
//
// The caller is the account named by the token, which tests set to the account id, so one server serves several
// members. The members, roles and grants are the chain's: the fake derives them from the entries it serves.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/bundle.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/manifest.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_pending.dart';
import 'package:kemlock/features/spaces/space_seals.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart';

import '../sync/kemlock/openapi_checker.dart';
import 'chain_kit.dart';

class FakeSpaceItem {
  FakeSpaceItem({
    required this.id,
    required this.kind,
    required this.collection,
    required this.revision,
    required this.keyVersion,
    required this.seq,
    this.ciphertext,
    this.itemKey,
  });

  final String id;
  final String kind;
  final String collection;
  int revision;
  int keyVersion;
  int seq;
  Uint8List? ciphertext;
  Uint8List? itemKey;

  Map<String, Object?> toJson(String space, {bool held = false}) => {
    'id': id,
    'owner': 'space:$space',
    'kind': kind,
    'format': 'kem1',
    'revision': revision,
    'keyVersion': keyVersion,
    if (ciphertext != null) 'ciphertext': b64urlEncode(ciphertext!),
    if (itemKey != null) 'itemKey': b64urlEncode(itemKey!),
    'deleted': ciphertext == null,
    'collectionId': collection,
    if (held) 'held': true,
  };
}

class FakeSpaceServer {
  FakeSpaceServer(this.space, this.chain, {this.seals});

  static final url = Uri.parse('https://kem.example.com');

  final String space;

  /// The chain the server serves. Tests grow it as the members make entries.
  final ChainBuilder chain;

  /// The boxes the chain's commitments cover, when the chain is built with real seals (`SealRegistry`): what the server
  /// serves a member as their keys, and the seal hash list of each record.
  final SealRegistry? seals;

  /// The sealed space key each member holds, and its version, and each member's collection keys.
  final sealedSpaceKeys = <String, ({int version, Uint8List sealed})>{};
  final collectionKeys = <String, List<({String collection, int version, Uint8List sealed})>>{};

  final items = <String, FakeSpaceItem>{};

  /// The latest manifest, as the server stores it.
  ({Uint8List manifest, Uint8List signature, String signer, int counter})? manifest;

  /// Changes queued from outside Kemlock clients (the Bitwarden routes, the group sync), as the server's pending
  /// changes: `{id, source, queuedAt, requestedBy, change}`.
  final pending = <Map<String, Object?>>[];

  /// Runs once, just before the next append is looked at: another member's record landing meanwhile.
  void Function()? beforeAppend;

  /// Runs once, just before the next batch is looked at: another member's write landing meanwhile.
  void Function()? beforeBatch;

  /// The sealed name of the space the chain's `create` came with, as the server stores it (`kem1`, kind "space-name").
  Uint8List? spaceName;

  /// The accounts that accepted their invitation, which the chain doesn't record (the member's `state` in the list).
  final accepted = <String>{};

  /// The accounts that declined theirs.
  final declined = <String>{};

  /// What a lying server adds to each listed space and member beside the facts, a policy flipped on say. Nothing reads it.
  var listExtra = const <String, Object?>{};

  /// The accounts the lookup by email finds, with their bundle and its self-signature.
  final directory = <String, ({String account, Uint8List bundle, Uint8List bundleSignature})>{};

  /// What the members route adds to a member beside the chain's own facts, by account: `email`, `name`, `publicBundle`,
  /// `bundleSignature`, `userKeyVersion` and `needsReconfirmation`, the bundle and its signature in base64url.
  final memberFacts = <String, Map<String, Object?>>{};

  /// How many lookups are still answered before the server says 429, or null for no limit.
  int? lookupsLeft;

  /// The invitations sent again, for the 429 of the second one within 10 minutes. server: to confirm
  final resends = <String>[];

  /// The spaces made with a `create` appended to the chain route of a new id (`POST /spaces/{newId}/chain`), by id.
  final created = <String, FakeCreatedSpace>{};

  /// The items a key replacement named held (the server keeps them and serves them to every member, marked held).
  final heldItems = <String>{};

  /// What the server did, in order: `batch`, `manifest`, `sync`, `approved`, `dropped`.
  final events = <String>[];
  var _seq = 0;

  /// Accepts writes by anyone, as a server that lets a removed member write with a key kept from before.
  var acceptAnyWriter = false;

  /// Leaves these items out of what it sends, as a server withholding them.
  final withheld = <String>{};

  /// Answers every read of the delta (`GET /sync`) with this status, as a server that is down or failing, while it is set.
  int? syncStatus;

  /// The state the chain derives, which is who the server lets in and what they may do.
  SpaceState get state => chain.state;

  /// Serves every confirmed member the boxes of the current key versions the chain committed to them, from [seals], as
  /// the server does once the records that sealed them are in. A key the chain didn't seal to a member is not served.
  Future<void> sealAll() async {
    final registry = seals!;
    final now = state;
    sealedSpaceKeys.clear();
    collectionKeys.clear();
    for (final member in now.confirmedMembers) {
      if (now.sealOf(const KeyRef.space(), member.id) != null) {
        sealedSpaceKeys[member.id] = (
          version: now.spaceKeyVersion,
          sealed: registry.box(const KeyRef.space(), now.spaceKeyVersion, member.id),
        );
      }
      collectionKeys[member.id] = [
        for (final collection in now.collections.values)
          if (now.sealOf(KeyRef.collection(collection.id), member.id) != null)
            (
              collection: collection.id,
              version: collection.keyVersion,
              sealed: registry.box(KeyRef.collection(collection.id), collection.keyVersion, member.id),
            ),
      ];
    }
  }

  /// A copy of [items] as another device of the account, or the server itself, wrote it: a test's way to put an item
  /// in without going through a member's sync.
  FakeSpaceItem put(FakeSpaceItem item) {
    item.seq = ++_seq;
    return items[item.id] = item;
  }

  /// The client of the member [caller] (an account id).
  late final http.Client client = MockClient((request) async {
    final response = await handle(request);
    OpenApiChecker.active?.exchange(request, response);
    return response;
  });

  http.Response _json(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  http.Response _problem(int status, String slug, [Map<String, Object?> extra = const {}]) => http.Response(
    jsonEncode({'type': 'urn:kemlock:problem:$slug', 'title': slug, 'status': status, ...extra}),
    status,
    headers: {'content-type': 'application/problem+json'},
  );

  String? _caller(http.Request request) {
    final header = request.headers['Authorization'];
    return header != null && header.startsWith('DPoP ') ? header.substring(5) : null;
  }

  Future<http.Response> handle(http.Request request) async {
    final caller = _caller(request);
    if (caller == null) {
      return _problem(401, 'unauthorized');
    }
    final route = request.url.path.replaceFirst('/kem/v1', '');
    final member = state.member(caller);
    final confirmed = member != null && member.isConfirmed;

    if (route == '/spaces' && request.method == 'GET') {
      return _list(caller);
    }
    if (route == '/spaces/$space/lookup' && request.method == 'GET') {
      return _lookup(caller, request);
    }
    final resend = RegExp(r'^/spaces/' + space + r'/members/([0-9a-f-]{36})/resend$').firstMatch(route);
    if (resend != null && request.method == 'POST') {
      return _resend(caller, resend.group(1)!);
    }
    if (route == '/spaces/$space/members' && request.method == 'GET') {
      return _members(caller);
    }
    // The invitee answers on their own member route: accept with no body, decline as a delete
    if (route == '/spaces/$space/members/me/accept' && request.method == 'POST') {
      return _answer(caller, accept: true);
    }
    if (route == '/spaces/$space/members/me' && request.method == 'DELETE') {
      return _answer(caller, accept: false);
    }
    final other = RegExp(r'^/spaces/([0-9a-f-]{36})(/.*)?$').firstMatch(route);
    if (other != null && other.group(1) != space) {
      return _otherSpace(caller, other.group(1)!, other.group(2) ?? '', request);
    }
    if (route == '/spaces/$space/chain' && request.method == 'GET') {
      // A person outside the space learns nothing about it
      if (member == null) {
        return _problem(404, 'not-found');
      }
      final from = request.url.queryParameters['from'];
      final start = from == null ? 0 : int.tryParse(from);
      if (start == null || start < 0) {
        return _problem(400, 'bad-request');
      }
      return _json([
        for (final signed in chain.entries)
          if (signed.entry.seq >= start) signed.toJson(),
      ]);
    }
    final sealsRoute = RegExp(r'^/spaces/' + space + r'/chain/(\d+)/seals$').firstMatch(route);
    if (sealsRoute != null && request.method == 'GET') {
      final log = chain.sealLog;
      if (member == null || (seals == null && log.isEmpty)) {
        return _problem(404, 'not-found');
      }
      return _json([
        for (final item in log[int.parse(sealsRoute.group(1)!)] ?? const <ChainSealHash>[])
          {
            'bundleVersion': item.bundleVersion,
            'key': item.key.wire,
            'member': item.member,
            'sealHash': b64urlEncode(item.sealHash),
            'version': item.version,
          },
      ]);
    }
    if (route == '/spaces/$space' && request.method == 'GET') {
      if (!confirmed) {
        return _problem(404, 'not-found');
      }
      final held = sealedSpaceKeys[caller];
      return _json({
        'space': _spaceDto(space, state, spaceName),
        'me': _memberDto(
          caller,
          member,
          state: 'confirmed',
          more: {if (held != null) 'sealedSpaceKey': b64urlEncode(held.sealed), if (held != null) 'keyVersion': held.version},
        ),
        'collections': [
          for (final collection in state.collections.values) {'id': collection.id, 'keyVersion': collection.keyVersion, 'name': ''},
        ],
        'collectionKeys': [
          for (final copy in collectionKeys[caller] ?? const <({String collection, int version, Uint8List sealed})>[])
            {'collection': copy.collection, 'keyVersion': copy.version, 'sealed': b64urlEncode(copy.sealed)},
        ],
        'grants': <Object?>[],
        'groups': <Object?>[],
      });
    }
    if (route == '/spaces/$space/chain' && request.method == 'POST' && chain.entries.isEmpty) {
      return _createOwn(caller, request);
    }
    if (route == '/spaces/$space/chain' && request.method == 'POST') {
      return _append(caller, request);
    }
    final pendingRoute = RegExp(r'^/spaces/' + space + r'/chain/pending(?:/([A-Za-z0-9_-]+))?$').firstMatch(route);
    if (pendingRoute != null) {
      return _pending(caller, request, pendingRoute.group(1));
    }
    if (route == '/sync' && request.method == 'GET') {
      if (syncStatus case final status?) {
        return _problem(status, 'unavailable');
      }
      if (!confirmed) {
        return _json({'items': <Object?>[], 'cursor': '0', 'more': false, 'siblings': <Object?>[]});
      }
      events.add('sync');
      final since = int.tryParse(request.url.queryParameters['since'] ?? '0') ?? 0;
      final changed = [
        for (final item in items.values)
          if (item.seq > since && !withheld.contains(item.id)) item,
      ]..sort((a, b) => a.seq.compareTo(b.seq));
      if (changed.isEmpty && request.url.queryParameters.containsKey('since')) {
        return http.Response('', 304);
      }
      return _json({
        'items': [for (final item in changed) item.toJson(space, held: heldItems.contains(item.id))],
        'cursor': '$_seq',
        'more': false,
        'siblings': <Object?>[],
      });
    }
    if (route == '/items:batch' && request.method == 'POST') {
      return _batch(caller, request);
    }
    if (route == '/manifests/space:$space') {
      return request.method == 'GET' ? _getManifest(confirmed) : _putManifest(caller, request);
    }
    return _problem(404, 'not-found');
  }

  // ─── Listing, inviting and making spaces ───────────────────────────────

  /// The member's `state` in the list: `confirmed`, `invited`, `accepted` (the chain doesn't record it) or `revoked`.
  String _stateOf(SpaceMember member, String account) => switch (member.status) {
    MemberStatus.confirmed => 'confirmed',
    MemberStatus.invited => accepted.contains(account) ? 'accepted' : 'invited',
    MemberStatus.removed => 'revoked',
  };

  /// The spec's `SpaceDto`: the name is the sealed `kem1` envelope's base64url, empty for a space with none.
  Map<String, Object?> _spaceDto(String id, SpaceState of, Uint8List? name) => {
    'id': id,
    'name': b64urlEncode(name ?? Uint8List(0)),
    'keyVersion': of.spaceKeyVersion,
    'createdAt': 1795000000,
  };

  /// The spec's `MemberDto` of [member]: the optional members that [more] holds are added to it.
  Map<String, Object?> _memberDto(String account, SpaceMember member, {String? state, Map<String, Object?> more = const {}}) => {
    'user': account,
    'role': member.role.wire,
    'custom': [for (final permission in member.custom) permission.wire],
    'state': state ?? _stateOf(member, account),
    'invitedBy': account,
    'invitedAt': 1,
    if (accepted.contains(account)) 'acceptedAt': 2,
    ...more,
  };

  /// An entry of the list; a space with no sealed name is listed with none (the spec's `name` is required, which a space made
  /// with a `create` record never lacks).
  Map<String, Object?> _listed(String id, Uint8List? name, SpaceState of, SpaceMember member, String account) => {
    'space': {
      'id': id,
      if (name != null) 'name': b64urlEncode(name),
      'keyVersion': of.spaceKeyVersion,
      'createdAt': 1795000000,
      ...listExtra,
    },
    'member': _memberDto(account, member, more: listExtra),
  };

  /// `GET /kem/v1/spaces`: `[{space, member}]`, the name as the sealed `kem1` envelope's base64url.
  http.Response _list(String caller) {
    final member = state.member(caller);
    return _json([
      if (member != null) _listed(space, spaceName, state, member, caller),
      for (final made in created.values)
        if (made.state.member(caller) != null) _listed(made.id, made.names['space'], made.state, made.state.member(caller)!, caller),
    ]);
  }

  bool _mayManageUsers(SpaceMember member) =>
      member.role == SpaceRole.owner ||
      member.role == SpaceRole.admin ||
      (member.role == SpaceRole.custom && member.custom.contains(CustomPermission.manageUsers));

  /// `GET .../lookup?email=`: `{account, bundle, bundleSignature, keyVersion}` for Owners, Admins and manage-users members; 403 for
  /// anyone else, 404 `no-account` for an unknown email, 429 once [lookupsLeft] ran out.
  http.Response _lookup(String caller, http.Request request) {
    final member = state.member(caller);
    if (member == null || !member.isConfirmed) {
      return _problem(404, 'not-found');
    }
    if (!_mayManageUsers(member)) {
      return _problem(403, 'forbidden');
    }
    final left = lookupsLeft;
    if (left != null) {
      if (left <= 0) {
        return _problem(429, 'rate-limited', {'retryAfter': 30});
      }
      lookupsLeft = left - 1;
    }
    final found = directory[request.url.queryParameters['email']];
    if (found == null) {
      return _problem(404, 'no-account');
    }
    events.add('lookup');
    return _json({
      'account': found.account,
      'bundle': b64urlEncode(found.bundle),
      'bundleSignature': b64urlEncode(found.bundleSignature),
      'keyVersion': KeyBundle.parse(found.bundle).keyVersion,
    });
  }

  /// `POST .../members/{user}/resend`: 204, and 429 for a second one within 10 minutes.
  http.Response _resend(String caller, String user) {
    final member = state.member(caller);
    if (member == null || !member.isConfirmed) {
      return _problem(404, 'not-found');
    }
    if (!_mayManageUsers(member)) {
      return _problem(403, 'forbidden');
    }
    if (state.member(user)?.status != MemberStatus.invited) {
      return _problem(404, 'not-found');
    }
    if (resends.contains(user)) {
      return _problem(429, 'rate-limited', {'retryAfter': 600});
    }
    resends.add(user);
    events.add('resend');
    return http.Response('', 204);
  }

  /// `GET .../members` (Owners, Admins and members who manage users): for each member of the chain, `{user, role, state}` and
  /// what [memberFacts] adds for them.
  http.Response _members(String caller) {
    final member = state.member(caller);
    if (member == null || !member.isConfirmed || !_mayManageUsers(member)) {
      return _problem(member == null ? 404 : 403, member == null ? 'not-found' : 'forbidden');
    }
    return _json([
      for (final listed in state.members.values) {..._memberDto(listed.id, listed), ...?memberFacts[listed.id]},
    ]);
  }

  /// `POST .../members/me/accept` (no body, answers the member) and `DELETE .../members/me` (204): the invitee's answer.
  /// Neither seals a key, and neither is a chain record.
  http.Response _answer(String caller, {required bool accept}) {
    final member = state.member(caller);
    if (member == null || member.status != MemberStatus.invited) {
      return _problem(404, 'not-found');
    }
    (accept ? accepted : declined).add(caller);
    events.add(accept ? 'accepted' : 'declined');
    if (!accept) {
      // The spec's answer to leaving a space, which an invitee declining does too: 200 with what the leaver exposed
      return _json({'exposed': <Object?>[], 'keysPending': false});
    }
    return _json(_memberDto(caller, member, state: 'accepted'));
  }

  /// The routes of a space made on this server (`POST /spaces/{newId}/chain` with the `create` as `records[0]`): the chain,
  /// the keys sealed to the caller and the seal hashes, which the app reads back to open its keys and the name.
  http.Response _otherSpace(String caller, String id, String rest, http.Request request) {
    final made = created[id];
    if (made == null && request.method == 'POST' && rest == '/chain') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final records = body['records'];
      if (records is! List<Object?> || records.length != 1) {
        return _refusal('malformed', 0);
      }
      final signed = SignedChainEntry.fromJson(records.single);
      final entry = signed.entry;
      if (entry.kind != ChainKind.create || entry.seq != 0 || entry.space != id || entry.by != caller) {
        return _refusal('not-allowed', 0);
      }
      final SpaceState after;
      try {
        after = SpaceState.empty(id).apply(entry);
      } on ChainRefusal catch (e) {
        return _refusal(e.problem.name, 0);
      }
      created[id] = FakeCreatedSpace(
        id: id,
        records: [signed],
        state: after,
        seals: [...(body['seals'] as List<Object?>? ?? const []).cast<Map<String, Object?>>()],
        names: {
          for (final raw in (body['names'] as List<Object?>? ?? const []).cast<Map<String, Object?>>())
            raw['target']! as String: b64urlDecode(raw['name']! as String),
        },
      );
      events.add('created');
      return _json({'link': b64urlEncode(after.headHash!), 'seq': 0}, 201);
    }
    if (made == null || made.state.member(caller) == null) {
      return _problem(404, 'not-found');
    }
    if (rest == '/chain' && request.method == 'GET') {
      return _json([for (final signed in made.records) signed.toJson()]);
    }
    if (rest == '/chain/0/seals' && request.method == 'GET') {
      return _json([
        for (final raw in made.seals)
          {
            'bundleVersion': made.state.member(raw['member']! as String)!.bundle!.keyVersion,
            'key': raw['key'],
            'member': raw['member'],
            'sealHash': b64urlEncode(hash.sha256.convert(b64urlDecode(raw['box']! as String)).bytes),
            'version': raw['version'],
          },
      ]);
    }
    if (rest.isEmpty && request.method == 'GET') {
      final mine = [
        for (final raw in made.seals)
          if (raw['member'] == caller) raw,
      ];
      final spaceKey = mine.where((raw) => raw['key'] == 'space').firstOrNull;
      return _json({
        'space': _spaceDto(id, made.state, made.names['space']),
        'me': _memberDto(
          caller,
          made.state.member(caller)!,
          state: 'confirmed',
          more: {if (spaceKey != null) 'sealedSpaceKey': spaceKey['box'], if (spaceKey != null) 'keyVersion': spaceKey['version']},
        ),
        'collections': [
          for (final collection in made.state.collections.values) {'id': collection.id, 'keyVersion': collection.keyVersion, 'name': ''},
        ],
        'collectionKeys': [
          for (final raw in mine)
            if (raw['key'] != 'space')
              {'collection': KeyRef.parse(raw['key']! as String).collection, 'keyVersion': raw['version'], 'sealed': raw['box']},
        ],
        'grants': <Object?>[],
        'groups': <Object?>[],
      });
    }
    return _problem(404, 'not-found');
  }

  /// The `create` of this server's own space (`POST /spaces/{id}/chain` with it as `records[0]`, on a server that holds no chain
  /// yet): the chain starts with it, and the boxes and names that came with it are the members' keys and the space's name, as
  /// the server takes them. It is how a moved WebDAV space, whose UUID is known beforehand, comes to exist on the fake.
  http.Response _createOwn(String caller, http.Request request) {
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final records = body['records'];
    if (records is! List<Object?> || records.length != 1) {
      return _refusal('malformed', 0);
    }
    final signed = SignedChainEntry.fromJson(records.single);
    final entry = signed.entry;
    if (entry.kind != ChainKind.create || entry.seq != 0 || entry.space != space || entry.by != caller) {
      return _refusal('not-allowed', 0);
    }
    try {
      SpaceState.empty(space).apply(entry);
    } on ChainRefusal catch (e) {
      return _refusal(e.problem.name, 0);
    }
    for (final raw in (body['names'] as List<Object?>? ?? const []).cast<Map<String, Object?>>()) {
      if (raw['target'] == 'space') {
        spaceName = b64urlDecode(raw['name']! as String);
      }
    }
    events.add('created');
    return _take(chain.fork()..append(signed), body);
  }

  /// `POST /kem/v1/spaces/{id}/chain`: appends the records in order if each is by the caller, follows the head and is
  /// allowed by the chain, takes the boxes the commitments cover as the members' keys (and their seal hash list), and
  /// the items named held. All or none: 201 `{link, seq}`, 409 `{head}` when the head moved, 422 `{reason, seq}`.
  http.Response _append(String caller, http.Request request) {
    final landing = beforeAppend;
    beforeAppend = null;
    landing?.call();
    final member = state.member(caller);
    if (member == null || !member.isConfirmed) {
      return _problem(404, 'not-found');
    }
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final records = body['records']! as List<Object?>;
    if (records.isEmpty || records.length > 16) {
      return _problem(400, 'bad-request');
    }
    final staged = _stage(caller, records);
    if (staged is http.Response) {
      return staged;
    }
    return _take(staged as ChainBuilder, body);
  }

  /// Checks [records] one after the other against a copy of the chain: the staged chain, or the answer that refuses them.
  Object _stage(String caller, List<Object?> records) {
    final staged = chain.fork();
    var index = 0;
    try {
      for (final raw in records) {
        final signed = SignedChainEntry.fromJson(raw);
        final entry = signed.entry;
        if (entry.by != caller) {
          return _refusal('not-allowed', entry.seq);
        }
        if (entry.seq != staged.state.nextSeq) {
          return _moved();
        }
        final before = staged.state;
        final after = before.apply(entry);
        if (chainAuthorityProblem(before, after, entry) != null) {
          return _refusal('not-allowed', entry.seq);
        }
        staged.append(signed);
        index++;
      }
    } on ChainRefusal catch (e) {
      return _refusal(e.problem.name, state.nextSeq + index);
    } on Object {
      return _refusal('malformed', state.nextSeq + index);
    }
    return staged;
  }

  http.Response _moved() => _problem(409, 'stale-head', {'head': b64urlEncode(state.headHash ?? chainGenesisLink), 'seq': state.headSeq});

  http.Response _refusal(String reason, int seq) => _problem(422, reason, {'reason': reason, 'seq': seq});

  /// Takes [staged] as the chain, with the boxes, names and held items of [body].
  http.Response _take(ChainBuilder staged, Map<String, Object?> body) {
    chain
      ..entries.addAll(staged.entries.sublist(chain.entries.length))
      ..seq = staged.seq
      ..prev = staged.prev
      ..epoch = staged.epoch;
    final after = state;
    for (final raw in (body['seals'] as List<Object?>? ?? const []).cast<Map<String, Object?>>()) {
      final key = KeyRef.parse(raw['key']! as String);
      final account = raw['member']! as String;
      final box = b64urlDecode(raw['box']! as String);
      final version = raw['version']! as int;
      final seq = raw['seq']! as int;
      if (key.isSpace) {
        sealedSpaceKeys[account] = (version: version, sealed: box);
      } else {
        final list = collectionKeys[account] ??= [];
        list
          ..removeWhere((copy) => copy.collection == key.collection)
          ..add((collection: key.collection!, version: version, sealed: box));
      }
      chain.sealLog
          .putIfAbsent(seq, () => [])
          .add(
            ChainSealHash(
              bundleVersion: after.member(account)!.bundle!.keyVersion,
              key: key,
              member: account,
              sealHash: Uint8List.fromList(hash.sha256.convert(box).bytes),
              version: version,
            ),
          );
    }
    for (final id in (body['held'] as List<Object?>? ?? const []).cast<String>()) {
      heldItems.add(id);
      // Served again from the cursor on, marked held
      items[id]?.seq = ++_seq;
    }
    events.add('chain');
    return _created();
  }

  /// 201 with the new head.
  http.Response _created() => _json({'link': b64urlEncode(state.headHash!), 'seq': state.headSeq}, 201);

  /// The pending changes (`GET /chain/pending`, `POST /chain/pending/{n}`, `DELETE /chain/pending/{n}`), for a confirmed Owner or Admin.
  /// The answer is an append body that must hold exactly the record the queued change makes (`pending-change-mismatch`
  /// otherwise), checked as any append is, and the server then applies the change and takes it off its queue.
  http.Response _pending(String caller, http.Request request, String? id) {
    final member = state.member(caller);
    if (member == null || !member.isConfirmed) {
      return _problem(404, 'not-found');
    }
    if (member.role != SpaceRole.owner && member.role != SpaceRole.admin) {
      return _problem(403, 'forbidden');
    }
    if (id == null) {
      return request.method == 'GET' ? _json(pending) : _problem(405, 'method-not-allowed');
    }
    final index = pending.indexWhere((change) => '${change['id']}' == id);
    if (index < 0) {
      return _problem(404, 'not-found');
    }
    if (request.method == 'DELETE') {
      pending.removeAt(index);
      events.add('dropped');
      return http.Response('', 204);
    }
    if (request.method != 'POST') {
      return _problem(405, 'method-not-allowed');
    }
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final records = body['records'];
    if (records is! List<Object?> || records.length != 1) {
      return _refusal('pending-change-mismatch', state.nextSeq);
    }
    final staged = _stage(caller, records);
    if (staged is http.Response) {
      return staged;
    }
    final signed = SignedChainEntry.fromJson(records.single);
    final queued = planPending(state: state, change: PendingChange.fromJson(pending[index]), by: caller, at: signed.entry.at);
    if (queued.entry == null || !_same(queued.entry!.bytes, signed.entry.bytes)) {
      return _refusal('pending-change-mismatch', signed.entry.seq);
    }
    final taken = _take(staged as ChainBuilder, body);
    events.removeLast();
    pending.removeAt(index);
    events.add('approved');
    return taken;
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  http.Response _batch(String caller, http.Request request) {
    final landing = beforeBatch;
    beforeBatch = null;
    landing?.call();
    final member = state.member(caller);
    final confirmed = member != null && member.isConfirmed;
    if (!confirmed && !acceptAnyWriter) {
      return _problem(404, 'not-found');
    }
    if (state.spaceKeyMarked && !acceptAnyWriter) {
      return _problem(423, 'space-keys-pending');
    }
    final writes = ((jsonDecode(request.body) as Map<String, Object?>)['writes']! as List<Object?>).cast<Map<String, Object?>>();
    final staged = <FakeSpaceItem>[];
    for (final write in writes) {
      final item = write['item']! as Map<String, Object?>;
      final collection = item['collectionId'];
      if (collection is! String || !state.collections.containsKey(collection)) {
        return _problem(400, 'bad-request');
      }
      if (state.markedCollections.contains(collection) && !acceptAnyWriter) {
        return _problem(423, 'space-keys-pending');
      }
      if (!acceptAnyWriter && !(state.accessOf(caller, collection)?.edit ?? false)) {
        return _problem(403, 'forbidden');
      }
      final id = item['id']! as String;
      final deleted = item['deleted'] == true;
      if (!acceptAnyWriter && !deleted && item['keyVersion'] != state.collections[collection]!.keyVersion) {
        return _problem(409, 'stale-key-version', {'currentKeyVersion': state.collections[collection]!.keyVersion});
      }
      final stored = items[id];
      final expected = write['expectedRevision'];
      if ((stored?.revision) != expected) {
        return _problem(409, 'stale', {'itemId': id, 'currentRevision': stored?.revision});
      }
      if (item['revision'] != (stored?.revision ?? 0) + 1) {
        return _problem(400, 'bad-revision');
      }
      staged.add(
        FakeSpaceItem(
          id: id,
          kind: item['kind']! as String,
          collection: collection,
          revision: item['revision']! as int,
          keyVersion: item['keyVersion']! as int,
          seq: 0,
          ciphertext: deleted ? null : b64urlDecode(item['ciphertext']! as String),
          itemKey: deleted ? null : b64urlDecode(item['itemKey']! as String),
        ),
      );
    }
    events.add('batch');
    final written = staged.map(put).toList();
    heldItems.removeAll([for (final item in written) item.id]);
    return _json({
      'items': [for (final item in written) item.toJson(space)],
    });
  }

  /// The spec's `ManifestResponse`.
  Map<String, Object?> _manifestAnswer(int counter, Uint8List bytes, Uint8List signature, String signer) => {
    'owner': 'space:$space',
    'counter': counter,
    'manifest': b64urlEncode(bytes),
    'signature': b64urlEncode(signature),
    'signer': signer,
    'storedAt': '2026-11-22T12:00:00Z',
  };

  http.Response _getManifest(bool confirmed) {
    final held = manifest;
    if (!confirmed || held == null) {
      return _problem(404, 'not-found');
    }
    return _json(_manifestAnswer(held.counter, held.manifest, held.signature, held.signer));
  }

  http.Response _putManifest(String caller, http.Request request) {
    final member = state.member(caller);
    final mayEdit = member != null && member.isConfirmed && state.collections.keys.any((c) => state.accessOf(caller, c)?.edit ?? false);
    if (!mayEdit) {
      return _problem(403, 'forbidden');
    }
    if (state.keysNeedReplacing) {
      return _problem(423, 'space-keys-pending');
    }
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final bytes = b64urlDecode(body['manifest']! as String);
    final parsed = Manifest.parse(bytes);
    if (parsed.owner.toWire() != 'space:$space') {
      return _problem(400, 'bad-request');
    }
    final held = manifest;
    if (held != null && parsed.counter <= held.counter) {
      return _problem(409, 'stale-manifest', {'currentCounter': held.counter});
    }
    events.add('manifest');
    manifest = (manifest: bytes, signature: b64urlDecode(body['signature']! as String), signer: caller, counter: parsed.counter);
    return _json(_manifestAnswer(parsed.counter, bytes, manifest!.signature, caller));
  }
}

/// A space made on the fake server by appending its `create` to the chain route of a new id.
class FakeCreatedSpace {
  FakeCreatedSpace({required this.id, required this.records, required this.state, required this.seals, required this.names});

  final String id;
  final List<SignedChainEntry> records;
  final SpaceState state;

  /// The seals of the request, `{box, key, member, seq, version}`.
  final List<Map<String, Object?>> seals;

  /// The sealed names of the request, by target (`space`, `collection:<id>`).
  final Map<String, Uint8List> names;
}
