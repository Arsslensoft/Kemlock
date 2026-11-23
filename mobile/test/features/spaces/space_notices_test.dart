import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/server_space_sheet.dart';
import 'package:kemlock/features/spaces/space_actions.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_notices.dart';
import 'package:kemlock/features/spaces/space_overview.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/i18n/messages.dart';

import '../../helpers/test_app.dart';
import 'chain_kit.dart';

Future<void> _tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

// The notices a space's policies owe a member, in the space's details (docs/plans/add-server-spaces.md, task group 7): the
// account recovery notice with Agree and Leave (7.2), and the duplicate-matching notice, told once and kept in the details (7.3).
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final sam = Person(1);
  final theo = Person(3);
  final ana = Person(4);

  /// Sam's space with Theo a confirmed Member and Ana invited; account recovery is [recovery].
  SpaceState chainOf({bool recovery = true, bool matching = false}) {
    final chain = ChainBuilder(space)
      ..create(sam, collection: everyone)
      ..invite(sam, theo)
      ..confirm(sam, theo)
      ..invite(sam, ana);
    if (recovery) {
      chain
        ..recoveryKey(sam)
        ..policies(sam, {'accountRecovery': true});
    }
    if (matching) {
      chain.policies(sam, {'duplicateMatching': true});
    }
    return chain.state;
  }

  Widget sheet(
    Person who,
    SpaceState chain, {
    Future<void> Function()? agree,
    VoidCallback? onLeft,
    bool matchingSeen = false,
    bool compared = true,
    Future<void> Function()? markSeen,
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
      actions: SpaceActions(
        account: who.id,
        readChain: () async => chain,
        openKeyring: (state) async => throw StateError('no key is opened in these tests'),
        append: (request) async {},
        sign: (entry) async => SignedChainEntry(entry, fakeSignature(who.bundle.sig1PublicKey, 'space-chain', entry.bytes)),
        now: () => 2000,
      ),
      compared: compared,
      agreeRecovery: agree,
      matchingSeen: matchingSeen,
      markMatchingSeen: markSeen,
      onLeft: onLeft,
      data: const SpaceSheetData(spaceName: 'Example Co'),
    ),
  );

  for (final locale in AppLocale.values) {
    group('the notices in ${locale.name}', () {
      final messages = testCatalog.of(locale);

      Future<void> show(WidgetTester tester, Widget child) async {
        await pumpScreen(tester, child, locale: locale);
        await tester.pump(const Duration(seconds: 10));
      }

      testWidgets('account recovery explains itself to a member, and seals nothing until they agree', (tester) async {
        var agreed = 0;
        await show(tester, sheet(theo, chainOf(), agree: () async => agreed++));

        expect(find.text(messages.t('space.recovery.title')), findsOneWidget);
        expect(find.text(messages.t('space.recovery.body')), findsOneWidget);
        expect(find.byKey(recoveryAgreeKey), findsOneWidget);
        expect(find.byKey(recoveryLeaveKey), findsOneWidget);
        expect(agreed, 0, reason: 'nothing is made by showing the notice');

        await _tapOn(tester, find.byKey(recoveryAgreeKey));

        expect(agreed, 1);
        expect(find.text(messages.t('space.recovery.agreed')), findsOneWidget);
        expect(find.byKey(recoveryAgreeKey), findsNothing);
      });

      testWidgets('a member who can’t be enrolled from this phone is offered Leave, and no Agree', (tester) async {
        await show(tester, sheet(theo, chainOf()));

        expect(find.text(messages.t('space.recovery.body')), findsOneWidget);
        expect(find.byKey(recoveryAgreeKey), findsNothing);
        expect(find.byKey(recoveryLeaveKey), findsOneWidget);
      });

      testWidgets('Leave asks to leave the space, and agrees to nothing', (tester) async {
        var agreed = 0;
        await show(tester, sheet(theo, chainOf(), agree: () async => agreed++));

        await _tapOn(tester, find.byKey(recoveryLeaveKey));

        expect(find.byKey(const ValueKey('space-leave-confirm')), findsOneWidget);
        expect(agreed, 0);
      });

      testWidgets('an agreement that fails says so, seals nothing and can be tried again', (tester) async {
        var tries = 0;
        await show(
          tester,
          sheet(
            theo,
            chainOf(),
            agree: () async {
              tries++;
              throw StateError('no route yet');
            },
          ),
        );

        await _tapOn(tester, find.byKey(recoveryAgreeKey));

        expect(tries, 1);
        expect(find.text(messages.t('space.recovery.failed')), findsOneWidget);
        expect(find.text(messages.t('space.recovery.agreed')), findsNothing);
        expect(find.byKey(recoveryAgreeKey), findsOneWidget);
      });

      testWidgets('there is no notice while the chain has account recovery off, whatever else is shown', (tester) async {
        await show(tester, sheet(theo, chainOf(recovery: false), agree: () async {}));

        expect(find.text(messages.t('space.recovery.title')), findsNothing);
        expect(find.byKey(recoveryAgreeKey), findsNothing);
      });

      testWidgets('a space whose fingerprint this device never compared shows no recovery or matching notice', (tester) async {
        await show(tester, sheet(theo, chainOf(matching: true), agree: () async {}, markSeen: () async {}, compared: false));

        expect(find.text(messages.t('space.recovery.title')), findsNothing, reason: 'a chain nobody compared owes no notice');
        expect(find.byKey(recoveryAgreeKey), findsNothing);
        expect(find.byKey(matchingNoticeKey), findsNothing);
      });

      testWidgets('an invitation not yet confirmed has no recovery notice: its own comes before Accept', (tester) async {
        await show(tester, sheet(ana, chainOf(), agree: () async {}));

        expect(find.text(messages.t('space.recovery.title')), findsNothing);
      });

      testWidgets('duplicate matching is told once, as a notice with “Got it”, and the details keep it', (tester) async {
        var seen = 0;
        await show(tester, sheet(theo, chainOf(recovery: false, matching: true), markSeen: () async => seen++));

        expect(find.text(messages.t('space.matching.title')), findsOneWidget);
        expect(find.text(messages.t('space.matching.new')), findsOneWidget);
        expect(find.text(messages.t('space.matching.body')), findsOneWidget);
        expect(seen, 0, reason: 'showing it remembers nothing');

        await _tapOn(tester, find.byKey(matchingGotItKey));

        expect(seen, 1);
        expect(find.byKey(matchingGotItKey), findsNothing);
        expect(find.text(messages.t('space.matching.new')), findsNothing);
        expect(find.text(messages.t('space.matching.body')), findsOneWidget, reason: 'it stays under the space’s details');
      });

      testWidgets('a member who was told already sees the details, and no notice or button', (tester) async {
        await show(tester, sheet(theo, chainOf(recovery: false, matching: true), matchingSeen: true, markSeen: () async {}));

        expect(find.byKey(matchingNoticeKey), findsOneWidget);
        expect(find.text(messages.t('space.matching.body')), findsOneWidget);
        expect(find.text(messages.t('space.matching.new')), findsNothing);
        expect(find.byKey(matchingGotItKey), findsNothing);
      });

      testWidgets('where nothing can be remembered the notice is the details alone, never a button that does nothing', (tester) async {
        await show(tester, sheet(theo, chainOf(recovery: false, matching: true)));

        expect(find.text(messages.t('space.matching.body')), findsOneWidget);
        expect(find.byKey(matchingGotItKey), findsNothing);
      });

      testWidgets('there is no matching notice while the chain has it off, or for an invitation', (tester) async {
        await show(tester, sheet(theo, chainOf(recovery: false), markSeen: () async {}));
        expect(find.byKey(matchingNoticeKey), findsNothing);
        expect(find.text(messages.t('space.matching.body')), findsNothing);

        await show(tester, sheet(ana, chainOf(recovery: false, matching: true), markSeen: () async {}));
        expect(find.byKey(matchingNoticeKey), findsNothing);
      });
    });
  }
}
