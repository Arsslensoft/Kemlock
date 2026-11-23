import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/features/spaces/server_space_sheet.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_chain_client.dart';
import 'package:kemlock/features/spaces/space_pending.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/i18n/messages.dart';

import '../../helpers/test_app.dart';
import 'chain_kit.dart';
import 'fake_space_server.dart';

// Changes from outside Kemlock clients, queued by the server for an Admin's app to sign (space_pending.dart): the
// record each makes, who may approve it, a client behind the fake server, and the sheet that lists them. The routes and
// the shape of a pending change are the server's: `GET /pending`, `POST /pending/{n}` with the body of an append, and
// `DELETE /pending/{n}`.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final finance = uuid(0xf1);
  final team = uuid(0x91);
  final alice = Person(1);
  final bob = Person(2);
  final carol = Person(3);
  final theo = Person(4);
  final dan = Person(5);
  final erin = Person(6);
  const spaceRef = KeyRef.space();
  final everyoneRef = KeyRef.collection(everyone);

  // Alice (Owner) made the space and confirmed Bob (Admin) and Carol (Member, edit on Everyone); the keys are sealed,
  // so a removal has keys to replace. Finance and a group exist.
  ChainBuilder base() => ChainBuilder(space)
    ..create(alice, collection: everyone)
    ..invite(alice, bob, role: SpaceRole.admin, grants: {everyone: CollectionPermission.manage})
    ..confirm(alice, bob)
    ..invite(alice, carol, grants: {everyone: CollectionPermission.edit})
    ..confirm(alice, carol)
    ..seal(alice, [spaceRef, everyoneRef])
    ..collection(alice, finance, grants: {'user:${alice.id}': CollectionPermission.manage, 'user:${bob.id}': CollectionPermission.manage})
    ..group(alice, team);

  /// One element of the server's list: a change of [kind] with [fields], asked for by an Admin through the Bitwarden API.
  Map<String, Object?> raw(String kind, Map<String, Object?> fields, {int n = 1, String source = 'bitwarden'}) => {
    'id': n,
    'source': source,
    'queuedAt': 1700000000,
    'requestedBy': {'account': null, 'email': 'boss@example.com', 'via': source},
    'change': {'kind': kind, 'email': 'who@example.com', ...fields},
  };

  PendingChange change(String kind, Map<String, Object?> fields, {int n = 1, String source = 'bitwarden'}) =>
      PendingChange.fromJson(raw(kind, fields, n: n, source: source));

  PendingPlan plan(ChainBuilder chain, PendingChange c, Person by) => planPending(state: chain.state, change: c, by: by.id, at: 1700000100);

  Future<SignedChainEntry> sign(Person by, SpaceChainEntry entry) async =>
      SignedChainEntry(entry, fakeSignature(by.bundle.sig1PublicKey, 'space-chain', entry.bytes));

  Future<bool> verifies(ChainBuilder chain) async =>
      (await verifyChain(space: space, entries: chain.entries, anchor: null, crypto: const FakeChainCrypto())).ok;

  group('a change becomes the record that answers it', () {
    test('an Admin approves an invite, and the record verifies on the chain', () async {
      final chain = base();
      final p = plan(
        chain,
        change('add-member', {
          'account': theo.id,
          'role': 'member',
          'grants': [
            {'collection': everyone, 'permission': 'view'},
          ],
        }),
        bob,
      );

      expect(p.canApprove, isTrue, reason: p.detail);
      expect(p.effect!.kind, ChainKind.invite);
      expect(p.effect!.member, theo.id);
      expect(p.effect!.role, SpaceRole.member);
      chain.append(await approvePending(p, (entry) => sign(bob, entry)));
      expect(await verifies(chain), isTrue);
      expect(chain.state.member(theo.id)!.status, MemberStatus.invited);
      expect(chain.state.accessOf(theo.id, everyone)!.edit, isFalse, reason: 'an invitation grants no more than the request asked');
    });

    test('a removal names the keys the person held, so approving it marks them for replacement', () async {
      final chain = base();
      final p = plan(chain, change('remove-member', {'account': carol.id}), alice);

      expect(p.canApprove, isTrue, reason: p.detail);
      expect(p.effect!.replaces, {spaceRef, everyoneRef});
      expect(p.entry!.body['replace'], [everyoneRef.wire, 'space']);
      chain.append(await approvePending(p, (entry) => sign(alice, entry)));
      expect(await verifies(chain), isTrue);
      expect(chain.state.member(carol.id)!.status, MemberStatus.removed);
      expect(chain.state.keysNeedReplacing, isTrue);
    });

    test('a role change, a grant and an ungrant each verify', () async {
      final chain = base();
      final steps = [
        change('role', {'account': carol.id, 'role': 'admin'}, n: 1),
        change('grant-set', {'account': carol.id, 'collection': finance, 'permission': 'edit-hide-passwords'}, n: 2),
        change('grant-remove', {'account': carol.id, 'collection': finance}, n: 3),
      ];
      for (final step in steps) {
        final p = plan(chain, step, alice);
        expect(p.canApprove, isTrue, reason: '${step.kind}: ${p.detail}');
        chain.append(await approvePending(p, (entry) => sign(alice, entry)));
      }
      expect(await verifies(chain), isTrue);
      expect(chain.state.member(carol.id)!.role, SpaceRole.admin);
    });

    test('a Custom member’s permissions are read as the chain spells them, in order', () {
      final p = plan(
        base(),
        change('add-member', {
          'account': theo.id,
          'role': 'custom',
          'custom': ['manage-users', 'create-collections'],
        }),
        alice,
      );
      expect(p.canApprove, isTrue, reason: p.detail);
      expect(p.entry!.body['custom'], ['create-collections', 'manage-users']);
    });
  });

  group('only a role the chain allows may approve', () {
    test('a Member finds an invite, a removal and a role change blocked', () {
      final chain = base();
      for (final c in [
        change('add-member', {'account': theo.id, 'role': 'member'}, n: 1),
        change('remove-member', {'account': bob.id}, n: 2),
        change('role', {'account': carol.id, 'role': 'admin'}, n: 3),
      ]) {
        final p = plan(chain, c, carol);
        expect(p.canApprove, isFalse, reason: c.kind);
        expect(p.block, PendingBlock.notAllowed, reason: c.kind);
      }
    });

    test('an Admin may not touch an Owner, and a Custom member invites only within their own permissions', () {
      final chain = base()
        ..invite(alice, erin)
        ..confirm(alice, erin)
        ..role(alice, erin, SpaceRole.owner)
        ..invite(alice, dan, role: SpaceRole.custom, custom: [CustomPermission.manageUsers])
        ..confirm(alice, dan);
      expect(plan(chain, change('remove-member', {'account': alice.id}), bob).block, PendingBlock.notAllowed);
      expect(plan(chain, change('role', {'account': alice.id, 'role': 'member'}), bob).block, PendingBlock.notAllowed);

      expect(plan(chain, change('add-member', {'account': theo.id, 'role': 'member'}), dan).canApprove, isTrue);
      expect(plan(chain, change('add-member', {'account': theo.id, 'role': 'admin'}), dan).block, PendingBlock.notAllowed);
    });

    test('a blocked change is never approved', () async {
      final p = plan(base(), change('add-member', {'account': theo.id, 'role': 'member'}), carol);
      await expectLater(approvePending(p, (entry) => sign(carol, entry)), throwsStateError);
    });

    test('a change the app makes no record of is refused as a failed future, not thrown by the call', () async {
      final p = plan(base(), change('rename', {'collection': finance}), alice);
      expect(p.canApprove, isFalse);
      final answer = approvePending(p, (entry) => sign(alice, entry));
      await expectLater(answer, throwsStateError);
    });

    test('the server tells a Member nothing of the queue and takes no record from them', () async {
      final chain = base();
      final server = FakeSpaceServer(space, chain);
      final c = change('add-member', {'account': theo.id, 'role': 'member'});
      server.pending.add(raw('add-member', {'account': theo.id, 'role': 'member'}));
      final forged = SignedChainEntry(
        buildForged(chain, carol),
        fakeSignature(carol.bundle.sig1PublicKey, 'space-chain', buildForged(chain, carol).bytes),
      );
      await expectLater(_client(server, carol).list(), throwsA(isA<KmError>().having((e) => e.status, 'status', 403)));
      await expectLater(_client(server, carol).approve(c, forged), throwsA(isA<KmError>().having((e) => e.status, 'status', 403)));
      expect(server.events, isNot(contains('approved')));
    });
  });

  group('a change the app can’t approve is dropped, not made', () {
    test('a member who left since, and a grant already given, no longer apply', () {
      final chain = base()..remove(alice, carol, replace: [spaceRef, everyoneRef]);
      final gone = plan(chain, change('remove-member', {'account': carol.id}), alice);
      expect(gone.block, PendingBlock.cantApply);
      expect(gone.canApprove, isFalse);
      final already = plan(chain, change('grant-set', {'account': alice.id, 'collection': everyone, 'permission': 'manage'}), alice);
      expect(already.block, PendingBlock.cantApply);
    });

    test('a kind the app makes no record of, and a change that is not the kind’s shape, are unsupported', () {
      final chain = base();
      final rename = change('rename', {'collection': finance});
      expect(rename.supported, isFalse);
      expect(plan(chain, rename, alice).block, PendingBlock.unsupported);
      expect(plan(chain, change('role', {'account': carol.id, 'role': 'chief'}), alice).block, PendingBlock.unsupported);
      expect(
        plan(chain, change('grant-set', {'account': carol.id, 'collection': 'finance', 'permission': 'edit'}), alice).block,
        PendingBlock.unsupported,
      );
      expect(
        plan(chain, change('remove-member', {'account': null}), alice).block,
        PendingBlock.unsupported,
        reason: 'no account to act on',
      );
    });

    test('a pending change is read from the server’s JSON, and a malformed one is refused', () {
      final read = PendingChange.fromJson({
        'id': 7,
        'source': 'sso',
        'queuedAt': 5,
        'requestedBy': {'account': theo.id, 'email': 'theo@example.com', 'via': 'sso'},
        'change': {
          'kind': 'add-member',
          'account': carol.id,
          'email': 'carol@example.com',
          'role': 'custom',
          'custom': ['manage-users'],
          'grants': [
            {'collection': everyone, 'permission': 'edit'},
          ],
        },
      });
      expect(read.id, '7');
      expect(read.source, 'sso');
      expect(read.queuedAt, 5);
      expect(read.requestedByAccount, theo.id);
      expect(read.account, carol.id);
      expect(read.email, 'carol@example.com');
      expect(read.custom, ['manage-users']);
      expect(read.grants, [(collection: everyone, permission: 'edit')]);
      expect(read.supported, isTrue);

      final bitwarden = PendingChange.fromJson(raw('remove-member', {'account': carol.id}));
      expect(bitwarden.requestedByAccount, isNull, reason: 'a Bitwarden request has no account');
      expect(
        PendingChange.fromJson({
          'id': 1,
          'change': {'kind': 'x'},
        }).source,
        'other',
      );
      expect(
        () => PendingChange.fromJson({
          'id': 'not good',
          'change': {'kind': 'role'},
        }),
        throwsA(anything),
      );
      expect(() => PendingChange.fromJson({'id': 1}), throwsA(anything));
      expect(() => PendingChange.fromJson('no'), throwsA(anything));
    });
  });

  group('the client behind the fake server', () {
    late ChainBuilder chain;
    late FakeSpaceServer server;

    PendingChange queue(String kind, Map<String, Object?> fields, {int n = 1, String source = 'bitwarden'}) {
      server.pending.add(raw(kind, fields, n: n, source: source));
      return change(kind, fields, n: n, source: source);
    }

    setUp(() {
      chain = base();
      server = FakeSpaceServer(space, chain);
    });

    test('lists the queue, leaving out an entry it can’t read, and approving appends the record to the chain', () async {
      final c = queue('add-member', {'account': theo.id, 'role': 'member'});
      server.pending.add({
        'id': 'not good',
        'change': {'kind': 'remove-member'},
      });
      final client = _client(server, bob);

      final listed = await client.list();
      expect([for (final item in listed) item.id], [c.id]);

      final p = plan(chain, listed.single, bob);
      final appended = await client.approve(listed.single, await approvePending(p, (entry) => sign(bob, entry)));

      expect(appended.seq, chain.state.headSeq);
      expect(server.events, ['approved']);
      expect(chain.entries.last.entry.kind, ChainKind.invite);
      expect(await verifies(chain), isTrue);
      expect(chain.state.member(theo.id)!.status, MemberStatus.invited);
      expect((await client.list()).length, 0, reason: 'the server took the change off its queue');
    });

    test('asks the routes the server has, under the space’s chain', () async {
      final seen = <String>[];
      final spy = MockClient((request) async {
        seen.add('${request.method} ${request.url.path}');
        return server.handle(request);
      });
      final client = _client(server, bob, over: spy);
      queue('add-member', {'account': theo.id, 'role': 'member'});
      final dropped = queue('remove-member', {'account': carol.id}, n: 2);

      final listed = await client.list();
      final p = plan(chain, listed.first, bob);
      await client.approve(listed.first, await approvePending(p, (entry) => sign(bob, entry)));
      await client.drop(dropped);

      expect(seen, [
        'GET /kem/v1/spaces/$space/chain/pending',
        'POST /kem/v1/spaces/$space/chain/pending/1',
        'DELETE /kem/v1/spaces/$space/chain/pending/2',
      ]);
    });

    test('dropping discards the change, and the chain is as it was', () async {
      final c = queue('remove-member', {'account': carol.id});
      final length = chain.entries.length;

      await _client(server, alice).drop(c);

      expect(server.events, ['dropped']);
      expect(server.pending, isEmpty);
      expect(chain.entries, hasLength(length));
      await expectLater(_client(server, alice).drop(c), throwsA(isA<KmError>()), reason: 'there is nothing left to drop');
    });

    test('a record that is not exactly the queued change is refused as pending-change-mismatch', () async {
      final c = queue('add-member', {'account': theo.id, 'role': 'member'});
      final length = chain.entries.length;
      // Alice's own record, valid on the chain but not what was queued
      final other = await sign(alice, buildForged(chain, alice));

      await expectLater(
        _client(server, alice).approve(c, other),
        throwsA(
          isA<ChainAppendError>()
              .having((e) => e.failure, 'failure', ChainAppendFailure.refused)
              .having((e) => e.reason, 'reason', 'pending-change-mismatch'),
        ),
      );
      expect(chain.entries, hasLength(length));
      expect(server.pending, hasLength(1), reason: 'the change stays queued');
    });

    test('a record made on an older head is a headMoved and the chain is not touched', () async {
      final c = queue('add-member', {'account': theo.id, 'role': 'member'});
      final p = plan(chain, c, alice);
      final signed = await approvePending(p, (entry) => sign(alice, entry));
      // Someone else's record took its place first
      chain.invite(alice, dan);
      final length = chain.entries.length;

      await expectLater(
        _client(server, alice).approve(c, signed),
        throwsA(isA<ChainAppendError>().having((e) => e.failure, 'failure', ChainAppendFailure.headMoved)),
      );
      expect(chain.entries, hasLength(length));
    });

    test('a record the chain refuses is a refusal that names the reason and the seq', () async {
      // Carol is a confirmed Member: the server takes her record to the chain's rules and refuses it as not allowed
      final forged = SignedChainEntry(
        buildForged(chain, carol),
        fakeSignature(carol.bundle.sig1PublicKey, 'space-chain', buildForged(chain, carol).bytes),
      );
      final client = SpaceChainClient(connection: _client(server, carol).connection, server: FakeSpaceServer.url, space: space);
      final mismatch = chain.state.nextSeq;

      await expectLater(
        client.append({
          'records': [forged.toJson()],
          'seals': <Object?>[],
          'names': <Object?>[],
        }),
        throwsA(
          isA<ChainAppendError>()
              .having((e) => e.failure, 'failure', ChainAppendFailure.refused)
              .having((e) => e.problem, 'problem', ChainProblem.notAllowed)
              .having((e) => e.seq, 'seq', mismatch),
        ),
      );
    });

    test('reads the chain from a sequence number, and all of it by default', () async {
      final client = SpaceChainClient(connection: _client(server, alice).connection, server: FakeSpaceServer.url, space: space);
      final all = await client.read();
      final tail = await client.read(from: 5);

      expect(all, hasLength(chain.entries.length));
      expect([for (final signed in tail) signed.entry.seq], [for (var seq = 5; seq < chain.entries.length; seq++) seq]);
      expect(await client.read(from: chain.entries.length), isEmpty);
    });
  });

  for (final locale in AppLocale.values) {
    group('the space’s sheet in ${locale.name}', () {
      late ChainBuilder chain;
      late FakeSpaceServer server;
      final messages = testCatalog.of(locale);

      PendingChange queue(String kind, Map<String, Object?> fields, {int n = 1, String source = 'bitwarden'}) {
        server.pending.add(raw(kind, fields, n: n, source: source));
        return change(kind, fields, n: n, source: source);
      }

      setUp(() {
        // A second Owner, so that taking the first away is a change the chain makes sense of and then refuses to Bob
        chain = base()
          ..invite(alice, erin)
          ..confirm(alice, erin)
          ..role(alice, erin, SpaceRole.owner);
        server = FakeSpaceServer(space, chain);
      });

      Widget sheet(Person who) {
        final client = _client(server, who);
        return Scaffold(
          body: ServerSpaceSheet(
            state: chain.state,
            account: who.id,
            load: client.list,
            approve: client.approve,
            drop: client.drop,
            sign: (entry) => sign(who, entry),
            reloadState: () async => chain.state,
            now: () => 1700000100,
          ),
        );
      }

      testWidgets('an Admin sees each change with what it would do, and Approve appends the record', (tester) async {
        final invite = queue('add-member', {'account': theo.id, 'email': 'theo@example.com', 'role': 'member'}, n: 1);
        final remove = queue('remove-member', {'account': carol.id, 'email': 'carol@example.com'}, n: 2, source: 'sso');
        await pumpScreen(tester, sheet(bob), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.pending.title')), findsOneWidget);
        expect(
          find.text(
            messages.t('space.pending.effect', {
              'kind': 'invite',
              'member': 'theo@example.com',
              'role': messages.t('space.pending.role', {'role': 'member'}),
            }),
          ),
          findsOneWidget,
        );
        expect(find.text(messages.t('space.pending.effect', {'kind': 'remove', 'member': 'carol@example.com'})), findsOneWidget);
        expect(find.text(messages.t('space.pending.source', {'source': 'sso'})), findsOneWidget);
        expect(find.text(messages.t('space.pending.replaces')), findsOneWidget, reason: 'a removal says the keys are replaced afterwards');

        await _tapOn(tester, find.byKey(approveKey(invite.id)));
        await tester.pump(const Duration(seconds: 10));

        expect(server.events, ['approved']);
        expect(chain.state.member(theo.id)!.status, MemberStatus.invited);
        expect(find.byKey(approveKey(invite.id)), findsNothing, reason: 'the list is read again');
        expect(find.byKey(approveKey(remove.id)), findsOneWidget);
      });

      testWidgets('a change about a person with no email shows the start of their account id', (tester) async {
        final withoutEmail = {'account': theo.id, 'email': null, 'role': 'member'};
        queue('add-member', withoutEmail);
        await pumpScreen(tester, sheet(bob), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(
          find.text(
            messages.t('space.pending.effect', {
              'kind': 'invite',
              'member': theo.id.substring(0, 8),
              'role': messages.t('space.pending.role', {'role': 'member'}),
            }),
          ),
          findsOneWidget,
        );
      });

      testWidgets('Drop discards a change and nothing changes in the space', (tester) async {
        final remove = queue('remove-member', {'account': carol.id}, source: 'sso');
        final length = chain.entries.length;
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(dropKey(remove.id)));
        await tester.pump(const Duration(seconds: 10));

        expect(server.events, ['dropped']);
        expect(chain.entries, hasLength(length));
        expect(find.text(messages.t('space.pending.none')), findsOneWidget);
      });

      testWidgets('a change the chain does not allow shows why and can only be dropped', (tester) async {
        // Bob, an Admin, may not remove the Owner
        final remove = queue('remove-member', {'account': alice.id});
        await pumpScreen(tester, sheet(bob), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.pending.block', {'block': 'notAllowed'})), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byKey(approveKey(remove.id))).onPressed, isNull);
        expect(tester.widget<TextButton>(find.byKey(dropKey(remove.id))).onPressed, isNotNull);
      });

      testWidgets('a Member is told only an owner or an admin reviews them', (tester) async {
        queue('remove-member', {'account': bob.id});
        await pumpScreen(tester, sheet(carol), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.pending.reviewers')), findsOneWidget);
        expect(find.text(messages.t('space.pending.title')), findsNothing);
        expect(find.byType(FilledButton), findsOneWidget, reason: 'only Close');
      });
    });
  }
}

/// The client of [who]'s phone for [server].
SpacePendingClient _client(FakeSpaceServer server, Person who, {http.Client? over}) => SpacePendingClient(
  connection: KmConnection(
    api: KmApi(over ?? server.client),
    server: FakeSpaceServer.url,
    session: KmSession(
      userId: who.id,
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: who.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    ),
    save: (_) async {},
  ),
  server: FakeSpaceServer.url,
  space: server.space,
);

/// A record by [by] that the chain accepts from an Owner or an Admin and refuses from a Member, and that is not what any
/// queued change here asks for: an invite of a new member.
SpaceChainEntry buildForged(ChainBuilder chain, Person by) {
  final state = chain.state;
  return SpaceChainEntry(
    space: state.space,
    seq: state.nextSeq,
    prev: state.headHash!,
    epoch: state.epoch,
    at: 1700000100,
    by: by.id,
    kind: ChainKind.invite,
    body: {'custom': <String>[], 'grants': <Object?>[], 'member': uuid(0x44), 'role': 'member'},
  );
}

/// Scrolls [finder] into view, taps it and lets the screen settle.
Future<void> _tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
