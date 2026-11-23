import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_card.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'codes_fakes.dart';

/// What the card called back with.
class _Calls {
  final updated = <OtpAccount>[];
  final deleted = <String>[];
  final copied = <OtpAccount>[];
}

/// Pumps the card for [account] on a page at [atMs] (Unix ms), 55 s by
/// default: code 287082 with five seconds left.
Future<_Calls> _pump(WidgetTester tester, OtpAccount account, {int atMs = 55000}) async {
  final calls = _Calls();
  await pumpAt(
    tester,
    atMs: atMs,
    Scaffold(
      body: SafeArea(
        child: AccountCard(account: account, onDelete: calls.deleted.add, onUpdate: calls.updated.add, onCopied: calls.copied.add),
      ),
    ),
  );
  return calls;
}

Finder get _sheet => find.byType(AccountSheet);

Finder _inSheet(Finder finder) => find.descendant(of: _sheet, matching: finder);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip(t('accountCard.details', {'name': 'GitHub'})));
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// How visible the "Copied!" label under the code is.
double _copiedOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.ancestor(of: find.text(t('accountCard.tooltip.copied')), matching: find.byType(AnimatedOpacity)).first)
    .opacity;

void main() {
  late FakeClipboard clipboard;

  setUp(() => clipboard = FakeClipboard());

  group('the row', () {
    testCodes('shows the account and its current code', (tester) async {
      await _pump(tester, rfcAccount);

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('octocat'), findsOneWidget);
      expect(findCode('287 082'), findsOneWidget);
    });

    testCodes('rolls over to the next code when the period ends', (tester) async {
      await _pump(tester, rfcAccount);

      await tester.pump(const Duration(seconds: 6));

      expect(findCode('359 152'), findsOneWidget);
      expect(findCode('287 082'), findsNothing);
    });

    testCodes('previews the next code in the last five seconds', (tester) async {
      await _pump(tester, rfcAccount);

      expect(find.text(t('accountCard.next', {'code': '359 152'})), findsOneWidget);
    });

    testCodes('does not preview the next code earlier in the window', (tester) async {
      await _pump(tester, rfcAccount, atMs: 65000);

      expect(findCode('359 152'), findsOneWidget);
      expect(find.text(t('accountCard.next', {'code': '969 429'})), findsNothing);
    });

    testCodes('turns the code to the warning colour in its last five seconds', (tester) async {
      await _pump(tester, rfcAccount);
      final context = tester.element(find.byType(AccountCard));
      expect(tester.widget<CodeDigits>(findCode('287 082')).style!.color, context.palette.warning);

      await tester.pump(const Duration(seconds: 6));

      expect(tester.widget<CodeDigits>(findCode('359 152')).style!.color, context.palette.text);
    });

    testCodes('groups 8-digit codes in fours', (tester) async {
      await _pump(tester, rfcAccount.copyWith(digits: 8));

      expect(findCode('9428 7082'), findsOneWidget);
    });

    testCodes('falls back to the label when there is no issuer', (tester) async {
      await _pump(tester, rfcAccount.copyWith(issuer: ''));

      expect(find.text('octocat'), findsOneWidget);
    });

    testCodes('says Unknown for an account with neither issuer nor label', (tester) async {
      await _pump(tester, rfcAccount.copyWith(issuer: '', label: ''));

      expect(find.text(t('accountCard.unknown')), findsOneWidget);
    });

    testCodes('copies the code with a single tap on the row', (tester) async {
      final calls = await _pump(tester, rfcAccount);

      await tester.tap(find.text('GitHub'));
      await tester.pump();

      expect(clipboard.text, '287082');
      expect(calls.copied.single.id, 'acc');
    });

    testCodes('flashes Copied! for a moment after copying', (tester) async {
      await _pump(tester, rfcAccount);
      expect(_copiedOpacity(tester), 0);

      await tester.tap(find.text('GitHub'));
      await tester.pump();
      expect(_copiedOpacity(tester), 1);
      expect(find.text(t('accountCard.next', {'code': '359 152'})), findsNothing);

      await tester.pump(const Duration(milliseconds: 1600));
      expect(_copiedOpacity(tester), 0);
    });

    testCodes('shows its own countdown only when the period differs from the shared 30 s clock', (tester) async {
      await _pump(tester, rfcAccount);

      expect(find.byType(CountdownRing), findsNothing);
    });

    testCodes('draws a countdown ring for a 60 s account', (tester) async {
      await _pump(tester, rfcAccount.copyWith(period: 60));

      expect(find.byType(CountdownRing), findsOneWidget);
    });
  });

  group('the detail sheet', () {
    testCodes('opens from the chevron and shows the upcoming code', (tester) async {
      await _pump(tester, rfcAccount);

      await _openSheet(tester);

      expect(_inSheet(find.text('359 152')), findsOneWidget);
      expect(_inSheet(find.text(t('accountCard.nextCodes.in', {'seconds': 5}))), findsOneWidget);
    });

    testCodes('copies the code from the sheet', (tester) async {
      final calls = await _pump(tester, rfcAccount);
      await _openSheet(tester);

      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.copy'))));

      expect(clipboard.text, '287082');
      expect(calls.copied, hasLength(1));
    });

    testCodes('pins the account', (tester) async {
      final calls = await _pump(tester, rfcAccount);
      await _openSheet(tester);

      await _tap(tester, _inSheet(find.text(t('accountSheet.pin'))));

      expect(calls.updated.single, rfcAccount.copyWith(pinned: true));
    });

    testCodes('requests deletion from the sheet', (tester) async {
      final calls = await _pump(tester, rfcAccount);
      await _openSheet(tester);

      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.remove'))));

      expect(calls.deleted, ['acc']);
    });
  });

  group('HOTP and Steam', () {
    // RFC 4226: counter 0 → 755224, counter 1 → 287082
    final hotp = rfcAccount.copyWith(type: OtpType.hotp, counter: 0);

    testCodes('shows the HOTP code for the stored counter, whatever the time', (tester) async {
      await _pump(tester, hotp);

      expect(findCode('755 224'), findsOneWidget);
      await tester.pump(const Duration(seconds: 60));
      expect(findCode('755 224'), findsOneWidget);
      expect(find.text(t('accountCard.next', {'code': '287 082'})), findsNothing);
    });

    testCodes('moves an HOTP account to its next code on request', (tester) async {
      final calls = await _pump(tester, hotp);

      await tester.tap(find.byTooltip(t('accountCard.hotpNext', {'name': 'GitHub'})));

      expect(calls.updated.single, hotp.copyWith(counter: 1));
    });

    testCodes('shows 5-character Steam Guard codes', (tester) async {
      // python-steam's test vector: b"superdupersecret" at t=3000030 → YRGQJ
      await _pump(tester, rfcAccount.copyWith(type: OtpType.steam, secret: 'ON2XAZLSMR2XAZLSONSWG4TFOQ'), atMs: 3000030000);

      expect(findCode('YRGQJ'), findsOneWidget);
    });
  });
}
