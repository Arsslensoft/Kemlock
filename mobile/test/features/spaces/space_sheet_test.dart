import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/fingerprint.dart';
import 'package:kemlock/features/spaces/server_space_sheet.dart';
import 'package:kemlock/features/spaces/server_spaces_list.dart';
import 'package:kemlock/features/spaces/space_actions.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_invites.dart';
import 'package:kemlock/features/spaces/space_overview.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/i18n/messages.dart';

import '../../helpers/test_app.dart';
import 'chain_kit.dart';
import 'policy_kit.dart';

Future<void> _tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

// The sheet of a server space (task 5.1) and the actions it offers (tasks 5.2 to 5.6): each member with their role and
// state, the collections with their grants, the policies and keys, what each role is offered, the confirmation by the
// fingerprint, removing, leaving and inviting. The chain is kept in memory and the sheet reads and appends to it.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);
  final carol = Person(3);
  final theo = Person(4);
  final dave = Person(5);
  final dave2 = Person(5, keyVersion: 2);
  final newcomer = Person(6);

  /// Alice makes the space and confirms Bob (edit on "Everyone") and Dave, who then replaces his key pair; Carol is
  /// invited, Theo is invited and has accepted.
  ChainBuilder build() => ChainBuilder(space)
    ..create(alice, collection: everyone)
    ..invite(alice, bob, grants: {everyone: CollectionPermission.edit})
    ..confirm(alice, bob)
    ..invite(alice, dave)
    ..confirm(alice, dave)
    ..seal(alice, [const KeyRef.space(), KeyRef.collection(everyone)])
    ..invite(alice, carol)
    ..invite(alice, theo)
    ..rekey(dave, dave2);

  late SpaceState chain;
  late List<String> calls;

  SpaceActions actionsFor(Person who) => SpaceActions(
    account: who.id,
    readChain: () async => chain,
    openKeyring: (state) async => throw StateError('no key is opened in these tests'),
    append: (request) async {
      final signed = SignedChainEntry.fromJson((request['records']! as List<Object?>).single);
      chain = chain.apply(signed.entry);
      calls.add(signed.entry.kind.wire);
    },
    sign: (entry) async => SignedChainEntry(entry, fakeSignature(who.bundle.sig1PublicKey, 'space-chain', entry.bytes)),
    now: () => 2000,
  );

  Widget sheet(
    Person who, {
    String? homeDown,
    bool withActions = true,
    Future<String?> Function()? scan,
    VoidCallback? onLeft,
    Future<void> Function(String member)? resendInvite,
    Future<InviteeLookup?> Function(String email)? lookup,
    Future<SpaceState> Function(String member, MemberOffer offer)? confirmMember,
    bool copyOpen = false,
  }) => Scaffold(
    body: ServerSpaceSheet(
      state: chain,
      account: who.id,
      load: () async => [],
      approve: (change, record) async {},
      drop: (change) async {},
      sign: (entry) async => SignedChainEntry(entry, fakeSignature(who.bundle.sig1PublicKey, 'space-chain', entry.bytes)),
      reloadState: () async => chain,
      now: () => 2000,
      actions: withActions ? actionsFor(who) : null,
      copyOpen: copyOpen,
      homeDown: homeDown,
      scan: scan,
      onLeft: onLeft,
      resendInvite: resendInvite,
      confirmMember: confirmMember,
      lookupAccount: lookup ?? ((email) async => email == 'new@example.com' ? (account: newcomer.id, bundle: newcomer.bundle) : null),
      itemCount: (collection) => 12,
      data: SpaceSheetData(
        spaceName: 'Example Co',
        collectionNames: {everyone: 'Everyone'},
        memberNames: {alice.id: 'Alice', bob.id: 'Bob', carol.id: 'Carol', theo.id: 'Theo', dave.id: 'Dave', newcomer.id: 'New'},
        offers: {theo.id: (bundle: theo.bundle, bundleSignature: theo.bundleSignature)},
      ),
    ),
  );

  setUp(() {
    chain = build().state;
    calls = [];
  });

  testWidgets('says that a grant which hides passwords closes the WebDAV copy, and makes it only once agreed', (tester) async {
    final messages = testCatalog.of(AppLocale.en);
    await pumpScreen(tester, sheet(alice, copyOpen: true));
    await tester.pump(const Duration(seconds: 10));

    Future<void> chooseHiding() async {
      await _tapOn(tester, find.byKey(actionKey('grant-$everyone', bob.id)));
      await _tapOn(tester, find.text(messages.t('space.pending.permission', {'permission': 'editHidePasswords'})));
    }

    await chooseHiding();
    expect(find.text(messages.t('space.bridge.warn.body')), findsOneWidget, reason: 'the warning comes before the grant');
    await _tapOn(tester, find.text(messages.t('space.leave.cancel')));
    expect(calls, isEmpty, reason: 'declining makes no record');

    await chooseHiding();
    await _tapOn(tester, find.text(messages.t('space.bridge.warn.confirm')));
    expect(calls, contains('grant'));
  });

  testWidgets('makes a grant that hides passwords without a warning when no WebDAV copy is open', (tester) async {
    final messages = testCatalog.of(AppLocale.en);
    await pumpScreen(tester, sheet(alice));
    await tester.pump(const Duration(seconds: 10));

    await _tapOn(tester, find.byKey(actionKey('grant-$everyone', bob.id)));
    await _tapOn(tester, find.text(messages.t('space.pending.permission', {'permission': 'editHidePasswords'})));

    expect(find.text(messages.t('space.bridge.warn.body')), findsNothing);
    expect(calls, contains('grant'));
  });

  for (final locale in AppLocale.values) {
    group('the sheet of a server space in ${locale.name}', () {
      final messages = testCatalog.of(locale);

      String status(SpaceRole role, String state) =>
          '${messages.t('space.pending.role', {'role': role.wire})} · ${messages.t('space.member.status', {'status': state})}';

      testWidgets('lists each member with their role and state, one per status', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text('Example Co'), findsOneWidget);
        expect(find.text(status(SpaceRole.owner, 'confirmed')), findsOneWidget);
        expect(find.text(status(SpaceRole.member, 'confirmed')), findsOneWidget, reason: 'Bob');
        expect(find.text(status(SpaceRole.member, 'rekeyed')), findsOneWidget, reason: 'Dave replaced his keys');
        expect(find.text(status(SpaceRole.member, 'invited')), findsOneWidget, reason: 'Carol');
        expect(find.text(status(SpaceRole.member, 'accepted')), findsOneWidget, reason: 'Theo accepted and waits to be confirmed');
      });

      testWidgets('lists the collections with their grants, the policies and the keys', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text('Everyone'), findsOneWidget);
        expect(find.text(messages.t('space.collection.keyVersion', {'version': 1})), findsOneWidget);
        expect(find.text('Bob · ${messages.t('space.pending.permission', {'permission': 'edit'})}'), findsOneWidget);
        expect(find.text(messages.t('space.policy.none')), findsOneWidget);
        expect(find.byKey(const ValueKey('space-key-version')), findsOneWidget);
        expect(find.text(messages.t('space.keys.need')), findsNothing);
      });

      testWidgets('shows "Keys need replacing" after a removal, and a Member is offered no action', (tester) async {
        chain = (build()..remove(alice, bob, replace: [const KeyRef.space(), KeyRef.collection(everyone)])).state;
        await pumpScreen(tester, sheet(dave), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.keys.need')), findsOneWidget);
        expect(find.byKey(const ValueKey('space-invite')), findsNothing);
        expect(find.byKey(actionKey('member-remove', bob.id)), findsNothing);
      });

      testWidgets('offers an Owner Invite, Confirm for the member who accepted, and Remove or Revoke', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.byKey(const ValueKey('space-invite')), findsOneWidget);
        expect(find.byKey(actionKey('member-confirm', theo.id)), findsOneWidget);
        expect(find.byKey(actionKey('member-confirm', carol.id)), findsNothing, reason: 'Carol has not accepted yet');
        expect(find.byKey(actionKey('member-remove', bob.id)), findsOneWidget);
        expect(find.byKey(actionKey('member-remove', carol.id)), findsOneWidget);
        expect(find.byKey(actionKey('member-resend', carol.id)), findsNothing, reason: 'no route to send it again is wired');
      });

      testWidgets('offers Resend for an invited member only when a resend is provided', (tester) async {
        final resent = <String>[];
        await pumpScreen(
          tester,
          sheet(
            alice,
            resendInvite: (member) async {
              resent.add(member);
            },
          ),
          locale: locale,
        );
        await tester.pump(const Duration(seconds: 10));

        expect(find.byKey(actionKey('member-resend', carol.id)), findsOneWidget);
        expect(find.byKey(actionKey('member-resend', bob.id)), findsNothing, reason: 'Bob is confirmed');
        expect(find.byKey(actionKey('member-resend', theo.id)), findsNothing, reason: 'Theo accepted');

        await _tapOn(tester, find.byKey(actionKey('member-resend', carol.id)));
        expect(resent, [carol.id]);
      });

      testWidgets('waits while the home is down, says so and disables the actions, which items’ syncing doesn’t need', (tester) async {
        await pumpScreen(tester, sheet(alice, homeDown: 'kem.example.com'), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.homeDown', {'home': 'kem.example.com'})), findsOneWidget);
        expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('space-invite'))).onPressed, isNull);
        expect(tester.widget<TextButton>(find.byKey(actionKey('member-remove', bob.id))).onPressed, isNull);
        expect(tester.widget<TextButton>(find.byKey(const ValueKey('space-leave'))).onPressed, isNull);
      });

      testWidgets('confirms a member after "It matches", with the digits of the bundle the server gave', (tester) async {
        final confirmed = <String>[];
        await pumpScreen(
          tester,
          sheet(
            alice,
            confirmMember: (member, offer) async {
              confirmed.add(member);
              return chain;
            },
          ),
          locale: locale,
        );
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(actionKey('member-confirm', theo.id)));
        expect(find.text(messages.t('space.confirm.title', {'name': 'Theo'})), findsOneWidget);
        expect(find.text(fingerprintRows(theo.bundle.fingerprint).first.first), findsOneWidget);
        expect(confirmed, isEmpty, reason: 'nothing is confirmed before they compare');

        await _tapOn(tester, find.byKey(const ValueKey('space-confirm-matches')));

        expect(confirmed, [theo.id]);
        expect(find.text('Example Co'), findsOneWidget, reason: 'back on the space');
      });

      testWidgets('"Not now" confirms nothing', (tester) async {
        final confirmed = <String>[];
        await pumpScreen(
          tester,
          sheet(
            alice,
            confirmMember: (member, offer) async {
              confirmed.add(member);
              return chain;
            },
          ),
          locale: locale,
        );
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(actionKey('member-confirm', theo.id)));
        await _tapOn(tester, find.byKey(const ValueKey('space-confirm-not-now')));

        expect(confirmed, isEmpty);
        expect(find.byKey(actionKey('member-confirm', theo.id)), findsOneWidget);
      });

      testWidgets('a scanned code that is another fingerprint is refused with the warning, and a matching one confirms', (tester) async {
        final confirmed = <String>[];
        var scanned = fingerprintQrText(carol.bundle.fingerprint);
        await pumpScreen(
          tester,
          sheet(
            alice,
            scan: () async => scanned,
            confirmMember: (member, offer) async {
              confirmed.add(member);
              return chain;
            },
          ),
          locale: locale,
        );
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(actionKey('member-confirm', theo.id)));
        await _tapOn(tester, find.byKey(const ValueKey('space-confirm-scan')));

        expect(find.text(messages.t('space.confirm.mismatch')), findsOneWidget);
        expect(find.byKey(const ValueKey('space-confirm-matches')), findsNothing, reason: 'a differing fingerprint offers no way on');
        expect(confirmed, isEmpty);

        scanned = fingerprintQrText(theo.bundle.fingerprint);
        await _tapOn(tester, find.byKey(const ValueKey('space-confirm-not-now')));
        await _tapOn(tester, find.byKey(actionKey('member-confirm', theo.id)));
        await _tapOn(tester, find.byKey(const ValueKey('space-confirm-scan')));

        expect(confirmed, [theo.id]);
      });

      testWidgets('removing lists what the member could open, then records the removal and marks the keys', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(actionKey('member-remove', bob.id)));
        final items = messages.t('space.remove.items', {'form': 'other', 'items': 12});
        expect(find.text(messages.t('space.remove.title', {'name': 'Bob'})), findsOneWidget);
        expect(
          find.text(
            messages.t('space.remove.opens', {
              'list': messages.t('space.remove.item', {'name': 'Everyone', 'items': items}),
            }),
          ),
          findsOneWidget,
        );

        await _tapOn(tester, find.byKey(const ValueKey('space-remove-confirm')));

        expect(calls, ['remove']);
        expect(chain.member(bob.id)!.status, MemberStatus.removed);
        expect(find.text(messages.t('space.keys.need')), findsOneWidget);
      });

      testWidgets('revoking an invitation says nothing of keys and marks none', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(actionKey('member-remove', carol.id)));
        expect(find.text(messages.t('space.remove.revokeTitle', {'name': 'Carol'})), findsOneWidget);
        await _tapOn(tester, find.byKey(const ValueKey('space-remove-confirm')));

        expect(chain.member(carol.id)!.status, MemberStatus.removed);
        expect(chain.keysNeedReplacing, isFalse);
      });

      testWidgets('a member leaves, and is told the keys they held will be replaced', (tester) async {
        var left = false;
        await pumpScreen(tester, sheet(bob, onLeft: () => left = true), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(const ValueKey('space-leave')));
        expect(find.text(messages.t('space.leave.body')), findsOneWidget);
        await _tapOn(tester, find.byKey(const ValueKey('space-leave-confirm')));

        expect(left, isTrue);
        expect(chain.member(bob.id)!.status, MemberStatus.removed);
        expect(chain.keysNeedReplacing, isTrue);
      });

      testWidgets('the only Owner can’t leave, and is told to make another confirmed member Owner first', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.leave.onlyOwner')), findsOneWidget);
        expect(tester.widget<TextButton>(find.byKey(const ValueKey('space-leave'))).onPressed, isNull);
      });

      testWidgets('invites by email: the account is found and shown, then the member is invited without a key', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(const ValueKey('space-invite')));
        await tester.enterText(find.byKey(const ValueKey('space-invite-email')), 'new@example.com');
        await _tapOn(tester, find.byKey(const ValueKey('space-invite-send')));

        // Who would be invited is shown first, and nothing is made until it is confirmed
        final role = messages.t('space.pending.role', {'role': 'member'});
        expect(
          find.text(messages.t('space.invite.review', {'email': 'new@example.com', 'role': role, 'account': newcomer.id.substring(0, 8)})),
          findsOneWidget,
        );
        expect(find.text(messages.t('space.invite.reviewKeys')), findsOneWidget);
        expect(calls, isEmpty);

        await _tapOn(tester, find.byKey(const ValueKey('space-invite-confirm')));

        expect(calls, ['invite']);
        expect(chain.member(newcomer.id)!.status, MemberStatus.invited);
        // Dave replaced his key pair, so he awaits a seal to his new bundle: the chain entitles him. The invited
        // newcomer is entitled to no key, and nothing awaits them, until a confirm.
        expect(chain.entitled(const KeyRef.space()), isNot(contains(newcomer.id)));
        expect(chain.awaiting(const KeyRef.space()), isNot(contains(newcomer.id)));
        expect(chain.awaiting(KeyRef.collection(everyone)), isNot(contains(newcomer.id)));
        expect(chain.awaiting(const KeyRef.space()), [dave.id]);
      });

      testWidgets('an email no account has is said so, and nothing is made', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(const ValueKey('space-invite')));
        await tester.enterText(find.byKey(const ValueKey('space-invite-email')), 'nobody@example.com');
        await _tapOn(tester, find.byKey(const ValueKey('space-invite-send')));

        expect(find.text(messages.t('space.invite.unknown')), findsOneWidget);
        expect(calls, isEmpty);
      });

      for (final problem in [InviteLookupProblem.notAllowed, InviteLookupProblem.rateLimited]) {
        testWidgets('a lookup the server refuses or limits says so (${problem.name}), and nothing is made', (tester) async {
          await pumpScreen(tester, sheet(alice, lookup: (email) async => throw InviteLookupError(problem)), locale: locale);
          await tester.pump(const Duration(seconds: 10));

          await _tapOn(tester, find.byKey(const ValueKey('space-invite')));
          await tester.enterText(find.byKey(const ValueKey('space-invite-email')), 'new@example.com');
          await _tapOn(tester, find.byKey(const ValueKey('space-invite-send')));

          expect(find.text(messages.t('space.invite.lookupFailed', {'problem': problem.name})), findsOneWidget);
          expect(find.byKey(const ValueKey('space-invite-confirm')), findsNothing);
          expect(calls, isEmpty);
        });
      }

      testWidgets('going back from the review makes nothing', (tester) async {
        await pumpScreen(tester, sheet(alice), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(const ValueKey('space-invite')));
        await tester.enterText(find.byKey(const ValueKey('space-invite-email')), 'new@example.com');
        await _tapOn(tester, find.byKey(const ValueKey('space-invite-send')));
        await _tapOn(tester, find.byKey(const ValueKey('space-invite-review-back')));

        expect(find.byKey(const ValueKey('space-invite-email')), findsOneWidget);
        expect(calls, isEmpty);
      });

      testWidgets('a resend that is too soon says so, and one that goes through says it was sent', (tester) async {
        var tooSoon = true;
        await pumpScreen(
          tester,
          sheet(
            alice,
            resendInvite: (member) async {
              if (tooSoon) {
                throw const ResendError(ResendProblem.tooSoon);
              }
            },
          ),
          locale: locale,
        );
        await tester.pump(const Duration(seconds: 10));

        await _tapOn(tester, find.byKey(actionKey('member-resend', carol.id)));
        expect(find.text(messages.t('space.error', {'problem': 'tooSoon'})), findsOneWidget);
        expect(find.text(messages.t('space.member.resent')), findsNothing);

        tooSoon = false;
        await _tapOn(tester, find.byKey(actionKey('member-resend', carol.id)));
        expect(find.text(messages.t('space.member.resent')), findsOneWidget);
        expect(find.text(messages.t('space.error', {'problem': 'tooSoon'})), findsNothing);
      });

      testWidgets('a member who has not been confirmed sees "waiting to be confirmed" and nothing of the space', (tester) async {
        await pumpScreen(tester, sheet(theo), locale: locale);
        await tester.pump(const Duration(seconds: 10));

        expect(find.text(messages.t('space.waiting.title')), findsOneWidget);
        expect(find.text(messages.t('space.members.title')), findsNothing);
        expect(find.text(messages.t('space.collections.title')), findsNothing);
      });
    });
  }

  _listTests();
}

class _Source implements ServerSpacesSource {
  _Source(this.entries);

  final List<ServerSpaceEntry> entries;
  final made = <String>[];

  @override
  Future<List<ServerSpaceEntry>> load() async => entries;

  @override
  Widget sheetFor(ServerSpaceEntry entry) => Text('sheet of ${entry.name}');

  @override
  Future<ServerSpaceEntry> make(String name) async {
    made.add(name);
    final entry = (id: 'new', name: name, status: 'owner');
    entries.add(entry);
    return entry;
  }
}

void _listTests() {
  // A confirmed Member of the spaces `spaceWithPolicies` makes
  final policyMember = Person(3);

  for (final locale in AppLocale.values) {
    final messages = testCatalog.of(locale);

    testWidgets('lists a person’s server spaces apart from their WebDAV ones, each with its status, in ${locale.name}', (tester) async {
      final source = _Source([
        (id: 'a', name: 'Example Co', status: 'owner'),
        (id: 'b', name: 'Family', status: 'invited'),
        (id: 'c', name: 'Odd', status: 'cantBeChecked'),
        (id: 'd', name: 'Team', status: 'keysNeedReplacing'),
      ]);
      await pumpScreen(
        tester,
        const Scaffold(body: SingleChildScrollView(child: ServerSpacesList())),
        locale: locale,
        overrides: [serverSpacesSourceProvider.overrideWithValue(source)],
      );
      await tester.pump(const Duration(seconds: 10));

      expect(find.text(messages.t('spaces.server.title')), findsOneWidget);
      expect(find.text('Example Co'), findsOneWidget);
      for (final entry in source.entries) {
        expect(find.text(messages.t('spaces.server.row', {'status': entry.status})), findsOneWidget, reason: entry.name);
      }
    });

    testWidgets('holds back making a space while the account is in one that allows one per member, in ${locale.name}', (tester) async {
      final source = _Source([]);
      final held = const SpacePolicies().remembering(
        uuid(0x5a),
        policyMember.id,
        spaceWithPolicies(0x5a, policyMember, {'singleSpace': true}),
      );
      await pumpScreen(
        tester,
        const Scaffold(body: SingleChildScrollView(child: ServerSpacesList())),
        locale: locale,
        overrides: [serverSpacesSourceProvider.overrideWithValue(source), spacePoliciesProvider.overrideWith(() => HeldPolicies(held))],
      );
      await tester.pump(const Duration(seconds: 10));

      expect(
        find.text(messages.t('spaces.make.singleSpace', {'space': shortSpaceId(uuid(0x5a))})),
        findsOneWidget,
        reason: 'it names the space to leave first',
      );
      await tester.enterText(find.byKey(const ValueKey('server-space-name')), 'Example Co');
      await tester.pump();

      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('server-space-make'))).onPressed, isNull);
      expect(source.made, isEmpty);
    });

    testWidgets('tells a member of two spaces, one of which allows one per member, to leave one, in ${locale.name}', (tester) async {
      final source = _Source([]);
      final held = const SpacePolicies()
          .remembering(uuid(0x5a), policyMember.id, spaceWithPolicies(0x5a, policyMember))
          .remembering(uuid(0x5b), policyMember.id, spaceWithPolicies(0x5b, policyMember, {'singleSpace': true}));
      await pumpScreen(
        tester,
        const Scaffold(body: SingleChildScrollView(child: ServerSpacesList())),
        locale: locale,
        overrides: [serverSpacesSourceProvider.overrideWithValue(source), spacePoliciesProvider.overrideWith(() => HeldPolicies(held))],
      );
      await tester.pump(const Duration(seconds: 10));

      expect(find.byKey(serverSpacesLeaveOneKey), findsOneWidget);
      expect(
        find.text(messages.t('spaces.server.leaveOne', {'single': shortSpaceId(uuid(0x5b)), 'other': shortSpaceId(uuid(0x5a))})),
        findsOneWidget,
      );
    });

    testWidgets('shows nothing for a vault with no server, and makes a space by its name, in ${locale.name}', (tester) async {
      await pumpScreen(tester, const Scaffold(body: ServerSpacesList()), locale: locale);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text(messages.t('spaces.server.title')), findsNothing);

      final source = _Source([]);
      await pumpScreen(
        tester,
        const Scaffold(body: SingleChildScrollView(child: ServerSpacesList())),
        locale: locale,
        overrides: [serverSpacesSourceProvider.overrideWithValue(source)],
      );
      await tester.pump(const Duration(seconds: 10));
      expect(find.text(messages.t('spaces.server.empty')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('server-space-name')), 'Example Co');
      await tester.pump();
      await _tapOn(tester, find.byKey(const ValueKey('server-space-make')));

      expect(source.made, ['Example Co']);
      expect(find.text('Example Co'), findsOneWidget);
    });
  }
}
