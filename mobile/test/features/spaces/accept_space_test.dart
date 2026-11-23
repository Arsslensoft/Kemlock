import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/accept_space_sheet.dart';
import 'package:kemlock/features/spaces/fingerprint.dart';
import 'package:kemlock/features/spaces/fingerprint_view.dart';
import 'package:kemlock/features/spaces/space_contact.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/i18n/messages.dart';

import '../../helpers/test_app.dart';
import 'chain_kit.dart';

// The first-contact accept screen (the space chain section, "First contact"): the invitee compares the inviter's
// fingerprint as the verified chain records it, by digits or by scan, before the Accept button, an anchor, the keys or
// the notices. The logic is space_contact_test.dart's; these are the screen's cases, in both languages.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);
  final theo = Person(4);
  final mallory = Person(9);

  /// Alice made the space and invited Theo.
  ChainBuilder invited() => ChainBuilder(space)
    ..create(alice, collection: everyone)
    ..invite(alice, theo, grants: {everyone: CollectionPermission.view});

  FirstContact contactOf(ChainBuilder chain, Person account) => firstContact(state: chain.state, chain: chain.entries, account: account.id);

  for (final locale in AppLocale.values) {
    group('the accept screen in ${locale.name}', () {
      final messages = testCatalog.of(locale);
      var compared = 0;
      var accepted = 0;
      var declined = 0;

      setUp(() {
        compared = 0;
        accepted = 0;
        declined = 0;
      });

      Widget sheet(
        FirstContact contact, {
        bool invitedHere = true,
        bool recovery = false,
        Future<String?> Function()? scan,
        FirstContact Function(String)? pick,
        SpaceState? state,
        String? spaceName,
        VoidCallback? onReject,
        LeaveFirst? leaveFirst,
      }) => Scaffold(
        body: AcceptSpaceSheet(
          contact: contact,
          invited: invitedHere,
          accountRecovery: recovery,
          onCompared: () async => compared++,
          onAccept: () async => accepted++,
          onDecline: () => declined++,
          scan: scan,
          pick: pick,
          state: state,
          spaceName: spaceName,
          onReject: onReject,
          leaveFirst: leaveFirst,
        ),
      );

      Future<void> show(WidgetTester tester, Widget child) async {
        await pumpScreen(tester, child, locale: locale);
        await tester.pump(const Duration(seconds: 10));
      }

      testWidgets('shows the inviter’s fingerprint as the chain records it, and no Accept until it matches', (tester) async {
        await show(tester, sheet(contactOf(invited(), theo)));

        final groups = alice.bundle.fingerprintDigits.split(' ');
        for (var i = 0; i < 12; i++) {
          expect((tester.widget(find.byKey(fingerprintGroupKey(i))) as Text).data, groups[i]);
        }
        expect(find.byKey(acceptKey), findsNothing);
        expect(find.byKey(acceptMatchesKey), findsOneWidget);
        expect(find.text(messages.t('accept.compare', {'who': 'inviter', 'person': alice.id.substring(0, 8)})), findsOneWidget);
        expect(compared, 0);
        expect(accepted, 0);
      });

      testWidgets('“It matches” stores the anchor first, then offers Accept with the recovery notice before it', (tester) async {
        await show(tester, sheet(contactOf(invited(), theo), recovery: true));
        expect(find.text(messages.t('accept.recovery')), findsNothing, reason: 'the space’s notices wait for the comparison');

        await _tapOn(tester, find.byKey(acceptMatchesKey));

        expect(compared, 1);
        expect(find.byKey(fingerprintGroupKey(0)), findsNothing);
        expect(find.text(messages.t('accept.matched')), findsOneWidget);
        expect(find.text(messages.t('accept.recovery')), findsOneWidget);
        expect(tester.getTopLeft(find.text(messages.t('accept.recovery'))).dy, lessThan(tester.getTopLeft(find.byKey(acceptKey)).dy));

        await _tapOn(tester, find.byKey(acceptKey));
        expect(accepted, 1);
        expect(declined, 0);
      });

      testWidgets('an invitation to a second space offers no Accept, and says which space to leave first', (tester) async {
        const current = LeaveFirst(space: '5b000000-0000-4000-8000-000000000001', name: 'Example Co', byCurrent: true);
        await show(tester, sheet(contactOf(invited(), theo), leaveFirst: current));
        expect(find.byKey(acceptLeaveFirstKey), findsNothing, reason: 'the space’s notices wait for the comparison');

        await _tapOn(tester, find.byKey(acceptMatchesKey));

        expect(find.byKey(acceptKey), findsNothing);
        expect(find.byKey(acceptLeaveFirstKey), findsOneWidget);
        expect(find.text(messages.t('accept.leaveFirst', {'side': 'current', 'space': 'Example Co'})), findsOneWidget);
        expect(find.byKey(acceptDeclineKey), findsOneWidget, reason: 'the invitation can still be declined');
        expect(accepted, 0);
      });

      testWidgets('says to leave the current space when the space to join allows only one, naming it by its id with no name', (
        tester,
      ) async {
        const current = LeaveFirst(space: '5b000000-0000-4000-8000-000000000001', name: null, byCurrent: false);
        await show(tester, sheet(contactOf(invited(), theo), leaveFirst: current));

        await _tapOn(tester, find.byKey(acceptMatchesKey));

        expect(find.text(messages.t('accept.leaveFirst', {'side': 'joined', 'space': '5b000000'})), findsOneWidget);
        expect(find.byKey(acceptKey), findsNothing);
      });

      testWidgets('“Not now” stores nothing and offers no Accept', (tester) async {
        await show(tester, sheet(contactOf(invited(), theo)));

        await _tapOn(tester, find.byKey(acceptNotNowKey));

        expect(declined, 1);
        expect(compared, 0);
        expect(accepted, 0);
        expect(find.byKey(acceptKey), findsNothing);
      });

      testWidgets('a scan of the inviter’s own code matches, and one of another fingerprint is refused with the warning', (tester) async {
        var scanned = fingerprintQrText(bob.bundle.fingerprint);
        await show(tester, sheet(contactOf(invited(), theo), scan: () async => scanned));

        await _tapOn(tester, find.byKey(acceptScanKey));

        expect(find.text(messages.t('accept.mismatch')), findsOneWidget);
        expect(compared, 0, reason: 'nothing is stored');
        expect(find.byKey(acceptKey), findsNothing);
        expect(find.byKey(acceptMatchesKey), findsNothing);

        scanned = fingerprintQrText(alice.bundle.fingerprint);
        await show(tester, sheet(contactOf(invited(), theo), scan: () async => scanned));
        await _tapOn(tester, find.byKey(acceptScanKey));

        expect(compared, 1);
        expect(find.byKey(acceptKey), findsOneWidget);
      });

      testWidgets('a code that isn’t a fingerprint is said so, and the comparison goes on', (tester) async {
        await show(tester, sheet(contactOf(invited(), theo), scan: () async => 'otpauth://totp/x?secret=ABC'));

        await _tapOn(tester, find.byKey(acceptScanKey));

        expect(find.text(messages.t('accept.unreadable')), findsOneWidget);
        expect(find.byKey(acceptMatchesKey), findsOneWidget);
        expect(compared, 0);
      });

      testWidgets('a chain the server made with its own Owner shows the server’s digits, which the real inviter’s code refuses', (
        tester,
      ) async {
        // The server made a space with Mallory as Owner and invited Theo, as though Alice had
        final forged = ChainBuilder(space)
          ..create(mallory, collection: everyone)
          ..invite(mallory, theo);
        await show(tester, sheet(contactOf(forged, theo), scan: () async => fingerprintQrText(alice.bundle.fingerprint)));

        expect((tester.widget(find.byKey(fingerprintGroupKey(0))) as Text).data, mallory.bundle.fingerprintDigits.split(' ').first);
        expect(mallory.bundle.fingerprintDigits, isNot(alice.bundle.fingerprintDigits));

        await _tapOn(tester, find.byKey(acceptScanKey));

        expect(find.text(messages.t('accept.mismatch')), findsOneWidget);
        expect(compared, 0);
        expect(accepted, 0);
        expect(find.byKey(acceptKey), findsNothing);
      });

      testWidgets('an inviter who left leaves the invitee to pick an Owner, whose fingerprint is then compared', (tester) async {
        final chain = ChainBuilder(space)
          ..create(alice, collection: everyone)
          ..invite(alice, bob, role: SpaceRole.admin)
          ..confirm(alice, bob)
          ..invite(bob, theo)
          ..remove(alice, bob);
        final contact = contactOf(chain, theo);
        expect(contact.kind, ContactKind.pickOwner);

        await show(
          tester,
          sheet(
            contact,
            pick: (person) => compareWith(state: chain.state, chain: chain.entries, person: person, admittedAt: contact.admittedAt!),
          ),
        );
        expect(find.text(messages.t('accept.pick')), findsOneWidget);
        expect(find.byKey(acceptMatchesKey), findsNothing);

        await _tapOn(tester, find.byKey(acceptPickKey(alice.id)));

        expect((tester.widget(find.byKey(fingerprintGroupKey(0))) as Text).data, alice.bundle.fingerprintDigits.split(' ').first);
        expect(find.byKey(acceptMatchesKey), findsOneWidget);
      });

      testWidgets('a person whose key signed nothing since the account was admitted offers no comparison', (tester) async {
        final contact = FirstContact(kind: ContactKind.compare, person: alice.id, bundle: alice.bundle, admittedAt: 1, bundleSigned: false);
        await show(tester, sheet(contact));

        expect(find.text(messages.t('accept.cantCompare')), findsOneWidget);
        expect(find.byKey(acceptMatchesKey), findsNothing);
        expect(find.byKey(fingerprintGroupKey(0)), findsNothing);
        expect(find.byKey(acceptKey), findsNothing);
      });

      testWidgets('the creator, and a device the account’s own key vouches for, compare nothing and go straight to Accept', (tester) async {
        await show(tester, sheet(const FirstContact(kind: ContactKind.creator)));
        expect(find.text(messages.t('accept.creator')), findsOneWidget);
        expect(find.byKey(acceptKey), findsOneWidget);
        expect(find.byKey(acceptMatchesKey), findsNothing);

        await show(tester, sheet(const FirstContact(kind: ContactKind.vouched)));
        expect(find.text(messages.t('accept.vouched')), findsOneWidget);
        await _tapOn(tester, find.byKey(acceptKey));
        expect(accepted, 1);
        expect(compared, 0);
      });

      testWidgets('shows the space’s name, its policies and their notices only after the digits matched, and before Accept', (
        tester,
      ) async {
        // Tall enough that nothing scrolls: the notices sit in the scrolling part above the pinned Accept row, and a
        // widget's position in a clipped, scrolled-off list would say nothing about the order
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final chain = invited()..policies(alice, {'centralOwnership': true, 'disableExport': true});
        await show(tester, sheet(contactOf(chain, theo), state: chain.state, spaceName: 'Example Co', recovery: true));

        expect(find.text(messages.t('accept.space', {'name': 'Example Co'})), findsNothing);
        expect(find.text(messages.t('space.policies.title')), findsNothing);
        expect(find.byKey(const ValueKey('accept-notice-disableExport')), findsNothing);

        await _tapOn(tester, find.byKey(acceptMatchesKey));

        expect(find.text(messages.t('accept.space', {'name': 'Example Co'})), findsOneWidget);
        expect(find.text(messages.t('space.policies.title')), findsOneWidget);
        expect(
          find.text('${messages.t('space.policy.flag', {'policy': 'disableExport'})} · ${messages.t('space.policy.state', {'on': 'yes'})}'),
          findsOneWidget,
        );
        expect(find.text(messages.t('accept.recovery')), findsOneWidget);
        expect(find.text(messages.t('accept.notice', {'policy': 'centralOwnership'})), findsOneWidget);
        expect(find.text(messages.t('accept.notice', {'policy': 'disableExport'})), findsOneWidget);
        final accept = tester.getTopLeft(find.byKey(acceptKey)).dy;
        expect(tester.getTopLeft(find.text(messages.t('accept.recovery'))).dy, lessThan(accept));
        expect(tester.getTopLeft(find.text(messages.t('accept.notice', {'policy': 'disableExport'}))).dy, lessThan(accept));
        expect(accepted, 0, reason: 'nothing is accepted until the person taps Accept');
      });

      testWidgets('Decline answers for good through its own callback, where Not now leaves the invitation alone', (tester) async {
        var rejected = 0;
        await show(tester, sheet(contactOf(invited(), theo), onReject: () => rejected++));
        await _tapOn(tester, find.byKey(acceptMatchesKey));

        await _tapOn(tester, find.byKey(acceptDeclineKey));

        expect(rejected, 1);
        expect(declined, 0);
        expect(accepted, 0);
      });

      testWidgets('a new device of a confirmed member compares the confirmer, in the confirmer’s words', (tester) async {
        final chain = invited()..confirm(alice, theo);
        final contact = contactOf(chain, theo);
        expect(contact.kind, ContactKind.compare);

        await show(tester, sheet(contact, invitedHere: false));

        expect(find.text(messages.t('accept.compare', {'who': 'confirmer', 'person': alice.id.substring(0, 8)})), findsOneWidget);
      });
    });
  }
}

/// Scrolls [finder] into view, taps it and lets the screen settle.
Future<void> _tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
