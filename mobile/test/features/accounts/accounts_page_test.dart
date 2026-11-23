import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/accounts/account_card.dart';
import 'package:kemlock/features/accounts/accounts_page.dart';
import 'package:kemlock/features/accounts/add_account_sheet.dart';
import 'package:kemlock/features/accounts/key_account_card.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/security_key/oath/oath_name.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_scanner.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../security_keys/key_codes_harness.dart';
import 'codes_fakes.dart';

OtpAccount _account(String id, String issuer, {List<String>? tags, int? order, bool? pinned, String label = ''}) => OtpAccount(
  id: id,
  type: OtpType.totp,
  issuer: issuer,
  label: label,
  secret: 'JBSWY3DPEHPK3PXP',
  tags: tags,
  order: order,
  pinned: pinned,
  addedAt: 1,
);

final _github = _account('gh', 'GitHub', tags: ['Work'], order: 0);
final _dropbox = _account('db', 'Dropbox', order: 1);
final _steam = _account('st', 'Steam', tags: ['Games'], order: 2);

/// The page as the tests see it: the fake vault it asks and the providers.
typedef _Page = ({FakeVaultController vault, ProviderContainer container});

/// Pumps the Codes tab over [accounts] at 09:00:55 on the test day (five
/// seconds left in the window). The
/// vault records what the page asks of it and, as the stubbed context of
/// the Vitest tests did, changes nothing.
Future<_Page> _pump(
  WidgetTester tester, {
  List<OtpAccount>? accounts,
  List<KeyAccount> keyAccounts = const [],
  List<Override> overrides = const [],
}) async {
  // Tall enough that every row is built
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final vault = FakeVaultController(openVault(accounts: accounts ?? [_github, _dropbox, _steam], keyAccounts: keyAccounts));
  final container = await pumpAt(
    tester,
    atMs: testNow.millisecondsSinceEpoch + 55000,
    // The shell's Scaffold, which the page sits in
    const Scaffold(body: AccountsPage()),
    overrides: [fakeVault(vault), ...overrides],
  );
  await tester.pumpAndSettle();
  return (vault: vault, container: container);
}

/// The accounts in the order the page lists them.
List<String> _names(WidgetTester tester) => [
  for (final card in tester.widgetList<AccountCard>(find.byType(AccountCard))) card.account.issuer,
];

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openSortMenu(WidgetTester tester) => _tap(tester, find.byTooltip(t('accounts.sort')));

Finder get _tagFilter => find.bySemanticsLabel(t('accounts.tagFilter'));

Finder _section(String id, [Map<String, Object?> args = const {}]) => find.text(t(id, args).toUpperCase());

IconButton _iconButton(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)));

void main() {
  setUp(FakeClipboard.new);

  group('tags', () {
    testCodes('filters the list by tag', (tester) async {
      await _pump(tester);

      await _tap(tester, find.descendant(of: _tagFilter, matching: find.text('Work')));

      expect(_section('accounts.section.tagged', {'tag': 'Work'}), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Dropbox'), findsNothing);

      await _tap(tester, find.descendant(of: _tagFilter, matching: find.text(t('accounts.tag.all'))));
      expect(find.text('Dropbox'), findsOneWidget);
    });

    testCodes('has no tag filter when no account is tagged', (tester) async {
      await _pump(tester, accounts: [_dropbox]);

      expect(_tagFilter, findsNothing);
    });

    testCodes('lists the tags A to Z after All', (tester) async {
      await _pump(tester);

      final chips = tester.widgetList<Text>(find.descendant(of: _tagFilter, matching: find.byType(Text))).map((text) => text.data);
      expect(chips, [t('accounts.tag.all'), 'Games', 'Work']);
    });
  });

  group('order', () {
    testCodes('sorts by name until a custom order is chosen', (tester) async {
      final page = await _pump(tester);
      expect(_names(tester), ['Dropbox', 'GitHub', 'Steam']);

      await _openSortMenu(tester);
      await _tap(tester, find.text(t('accounts.sort.custom')));

      expect(page.container.read(prefsProvider).accountSort, AccountSort.custom);
      expect(_names(tester), ['GitHub', 'Dropbox', 'Steam']);
    });

    testCodes('moves an account in reorder mode', (tester) async {
      final page = await _pump(tester);

      await _openSortMenu(tester);
      await _tap(tester, find.text(t('accounts.reorder')));
      await _tap(tester, find.byTooltip(t('accounts.reorder.down', {'name': 'GitHub'})));

      expect(page.vault.reordered.single, ['db', 'gh', 'st']);
      expect(_iconButton(tester, t('accounts.reorder.up', {'name': 'GitHub'})).onPressed, isNull);

      await _tap(tester, find.text(t('accounts.reorder.done')));
      expect(find.bySemanticsLabel(RegExp('^${t('accounts.searchLabel')}')), findsOneWidget);
    });

    testCodes('starts a first custom order from the A–Z order the user was looking at', (tester) async {
      final unordered = [
        for (final a in [_github, _dropbox, _steam]) a.copyWith(order: null),
      ];
      final page = await _pump(tester, accounts: unordered);

      await _openSortMenu(tester);
      await _tap(tester, find.text(t('accounts.sort.custom')));

      expect(page.vault.reordered.single, ['db', 'gh', 'st']);
    });

    testCodes('keeps pinned accounts on top of a first custom order', (tester) async {
      final unordered = [_github.copyWith(order: null), _dropbox.copyWith(order: null), _steam.copyWith(order: null, pinned: true)];
      final page = await _pump(tester, accounts: unordered);

      await _openSortMenu(tester);
      await _tap(tester, find.text(t('accounts.sort.custom')));

      expect(page.vault.reordered.single, ['st', 'db', 'gh']);
    });

    testCodes('moves pinned accounts among themselves', (tester) async {
      final page = await _pump(tester, accounts: [_github.copyWith(pinned: true), _dropbox, _steam.copyWith(pinned: true)]);

      await _openSortMenu(tester);
      await _tap(tester, find.text(t('accounts.reorder')));
      await _tap(tester, find.byTooltip(t('accounts.reorder.up', {'name': 'Steam'})));

      expect(page.vault.reordered.single, ['st', 'gh', 'db']);
    });
  });

  group('sections and search', () {
    testCodes('lists pinned accounts first, in their own section', (tester) async {
      await _pump(tester, accounts: [_github, _dropbox, _steam.copyWith(pinned: true)]);

      expect(_section('accounts.section.pinned'), findsOneWidget);
      expect(_section('accounts.section.all'), findsOneWidget);
      expect(_names(tester), ['Steam', 'Dropbox', 'GitHub']);
    });

    testCodes('finds accounts by service or account name, pinned or not', (tester) async {
      await _pump(
        tester,
        accounts: [
          _github.copyWith(label: 'octocat', pinned: true),
          _dropbox,
          _steam,
        ],
      );

      await tester.enterText(find.byType(TextField), 'OCTO');
      await tester.pumpAndSettle();

      expect(_section('accounts.section.results'), findsOneWidget);
      expect(_section('accounts.section.pinned'), findsNothing);
      expect(_names(tester), ['GitHub']);
      expect(find.text(t('accounts.hint')), findsNothing);
    });

    testCodes('says when nothing matches, and clears the search', (tester) async {
      await _pump(tester);

      await tester.enterText(find.byType(TextField), ' zzz ');
      await tester.pumpAndSettle();
      expect(find.text(t('accounts.noMatches.title', {'query': 'zzz'})), findsOneWidget);

      await _tap(tester, find.byTooltip(t('accounts.clearSearch')));
      expect(_names(tester), ['Dropbox', 'GitHub', 'Steam']);
      expect(find.text(t('accounts.hint')), findsOneWidget);
    });

    testCodes('counts the accounts in the title and the search box', (tester) async {
      await _pump(tester);

      expect(tester.widget<PageTitle>(find.byType(PageTitle)).count, 3);
      expect(find.text(t('accounts.search', {'count': 3})), findsOneWidget);
    });

    testCodes('shows the shared clock beside the title', (tester) async {
      await _pump(tester);

      expect(find.bySemanticsLabel(t('accounts.clock', {'seconds': 5})), findsOneWidget);
    });
  });

  group('backup reminder', () {
    testCodes('suggests a backup once three entries are missing from one', (tester) async {
      await _pump(tester);

      expect(find.text(t('accounts.backupNudge', {'count': 3})), findsOneWidget);
      await _tap(tester, find.text(t('settings.health.backUp')));

      expect(find.byType(ExportSheet), findsOneWidget);
    });

    testCodes('stays quiet after a recent backup', (tester) async {
      final page = await _pump(tester);

      page.container.read(prefsProvider.notifier).recordBackup();
      await tester.pumpAndSettle();

      expect(find.text(t('accounts.backupNudge', {'count': 3})), findsNothing);
    });

    testCodes('stays quiet with fewer than three new entries', (tester) async {
      await _pump(tester, accounts: [_github, _dropbox]);

      expect(find.text(t('accounts.backupNudge', {'count': 2})), findsNothing);
    });

    testCodes('can be dismissed until more accounts are added', (tester) async {
      final page = await _pump(tester);

      await _tap(tester, find.byTooltip(t('accounts.backupNudge.dismiss')));

      expect(find.text(t('accounts.backupNudge', {'count': 3})), findsNothing);
      final dismissedAt = testNow.millisecondsSinceEpoch + 55000;
      expect(page.container.read(prefsProvider).backupNudgeDismissedAt, inInclusiveRange(dismissedAt, dismissedAt + 1000));
    });
  });

  group('the vault', () {
    testCodes('offers to add the first account', (tester) async {
      await _pump(tester, accounts: [], overrides: [FakeScanner().asOverride]);

      expect(find.text(t('app.empty.otp.title')), findsOneWidget);
      expect(find.byTooltip(t('accounts.sort')), findsNothing);
      await _tap(tester, find.text(t('app.empty.otp.action')));

      expect(find.byType(AddAccountSheet), findsOneWidget);
    });

    testCodes('locks the vault', (tester) async {
      final page = await _pump(tester);

      await _tap(tester, find.byTooltip(t('app.tooltip.lockVault')));

      expect(page.vault.locks, 1);
    });

    testCodes('says which code was copied', (tester) async {
      final page = await _pump(tester);

      await tester.tap(find.text('GitHub'));
      await tester.pump();

      final toast = page.container.read(toastsProvider);
      expect(toast?.message, t('accounts.copied', {'name': 'GitHub'}));
      expect(toast?.severity, ToastSeverity.success);
    });

    testCodes('saves an account changed in its sheet', (tester) async {
      final page = await _pump(tester);

      await _tap(tester, find.byTooltip(t('accountCard.details', {'name': 'GitHub'})));
      await _tap(tester, find.text(t('accountSheet.pin')));

      expect(page.vault.updated.single, _github.copyWith(pinned: true));
    });

    testCodes('asks before removing an account', (tester) async {
      final page = await _pump(tester);
      await _tap(tester, find.byTooltip(t('accountCard.details', {'name': 'GitHub'})));
      await _tap(tester, find.text(t('accountCard.tooltip.remove')));

      expect(find.text(t('app.deleteAccount.title')), findsOneWidget);
      expect(find.textContaining('GitHub', findRichText: true), findsWidgets);
      await _tap(tester, find.text(t('app.deleteAccount.cancel')));
      expect(page.vault.deleted, isEmpty);

      await _tap(tester, find.byTooltip(t('accountCard.details', {'name': 'GitHub'})));
      await _tap(tester, find.text(t('accountCard.tooltip.remove')));
      await _tap(tester, find.text(t('app.deleteAccount.confirm')));

      expect(page.vault.deleted.single.id, 'gh');
    });
  });

  // openspec: add-security-key-codes, task 4.4
  group('accounts on a security key', () {
    const device = '0102030405060708';
    const keySection = 'accounts.section.onKey';
    const keyArgs = {'key': 'YubiKey 5C NFC'};

    KeyAccount onKey(String id, String name, {List<String>? tags, String? note, bool touch = false, bool hotp = false}) {
      final parts = parseOathName(name, timeBased: !hotp);
      return KeyAccount(
        id: id,
        device: device,
        keyName: 'YubiKey 5C NFC',
        name: name,
        issuer: parts.issuer,
        label: parts.label,
        period: parts.period,
        type: hotp ? KeyAccountType.hotp : KeyAccountType.totp,
        touch: touch,
        tags: tags,
        note: note,
        addedAt: 1,
      );
    }

    // The four accounts of the fake key's usual set, as a read remembers them.
    final keyAccounts = [
      onKey('k1', 'Example:alice@example.org', tags: ['Work']),
      onKey('k2', '60/Slow:bob', note: 'the old server'),
      onKey('k3', 'Registrar:root', touch: true),
      onKey('k4', 'Example:counter', hotp: true),
    ];

    List<String> keyRows(WidgetTester tester) => [
      for (final card in tester.widgetList<KeyAccountCard>(find.byType(KeyAccountCard))) card.account.id,
    ];

    Future<_Page> pumpWithKey(WidgetTester tester, {List<KeyAccount>? onKeys, List<Override> overrides = const []}) =>
        _pump(tester, accounts: [_github, _dropbox], keyAccounts: onKeys ?? keyAccounts, overrides: overrides);

    testCodes('a vault with no key account has the labels and rows it had', (tester) async {
      await _pump(tester);

      expect(_section('accounts.section.all'), findsOneWidget);
      expect(_section('accounts.section.inVault'), findsNothing);
      expect(_section('accounts.section.onKeyUnnamed'), findsNothing);
      expect(find.byType(KeyAccountCard), findsNothing);
      expect(find.text(t('keyCodes.read')), findsNothing);
      expect(find.text(t('keyCodes.neverLeave')), findsNothing);
      expect(_names(tester), ['Dropbox', 'GitHub', 'Steam']);
    });

    testCodes('two vault and four key accounts count six, under the vault’s label and the key’s', (tester) async {
      await pumpWithKey(tester);

      expect(tester.widget<PageTitle>(find.byType(PageTitle)).count, 6);
      expect(find.text(t('accounts.search', {'count': 6})), findsOneWidget);
      expect(_section('accounts.section.inVault'), findsOneWidget);
      expect(_section('accounts.section.all'), findsNothing);
      expect(_section(keySection, keyArgs), findsOneWidget);
      expect(_names(tester), ['Dropbox', 'GitHub']);
      // A to Z by what the row shows, the two Example accounts in the order they were read.
      expect(keyRows(tester), ['k1', 'k4', 'k3', 'k2']);
      // The key's rows come under the vault's.
      expect(tester.getTopLeft(_section(keySection, keyArgs)).dy, greaterThan(tester.getTopLeft(find.text('GitHub')).dy));
      // Before any read: the second sentence of the note alone, and "Read the key".
      expect(find.text(t('keyCodes.neverLeave')), findsOneWidget);
      expect(find.text(t('keyCodes.read')), findsOneWidget);
    });

    testCodes('each key has its own section', (tester) async {
      await pumpWithKey(
        tester,
        onKeys: [
          ...keyAccounts,
          const KeyAccount(id: 'n1', device: 'aabbccdd', name: 'Forge:carol', issuer: 'Forge', label: 'carol', addedAt: 1),
        ],
      );

      expect(_section(keySection, keyArgs), findsOneWidget);
      expect(_section('accounts.section.onKeyUnnamed'), findsOneWidget);
      expect(keyRows(tester), ['k1', 'k4', 'k3', 'k2', 'n1']);
    });

    testCodes('search finds both kinds, by issuer, name, tag and note', (tester) async {
      await pumpWithKey(tester);

      await tester.enterText(find.byType(TextField), 'example');
      await tester.pumpAndSettle();
      expect(_names(tester), isEmpty);
      expect(keyRows(tester), ['k1', 'k4']);
      expect(_section(keySection, keyArgs), findsOneWidget, reason: 'the rows are marked as on the key');
      expect(find.text(t('accounts.noMatches.title', {'query': 'example'})), findsNothing);

      await tester.enterText(find.byType(TextField), 'old server');
      await tester.pumpAndSettle();
      expect(keyRows(tester), ['k2']);

      await tester.enterText(find.byType(TextField), 'hub');
      await tester.pumpAndSettle();
      expect(_names(tester), ['GitHub']);
      expect(keyRows(tester), isEmpty);
    });

    testCodes('the tag filter offers and applies the tags of both kinds', (tester) async {
      await pumpWithKey(tester);

      final chips = tester.widgetList<Text>(find.descendant(of: _tagFilter, matching: find.byType(Text))).map((text) => text.data);
      expect(chips, [t('accounts.tag.all'), 'Work']);

      await _tap(tester, find.descendant(of: _tagFilter, matching: find.text('Work')));

      expect(_names(tester), ['GitHub']);
      expect(keyRows(tester), ['k1']);
    });

    testCodes('a touch account says so and offers “Tap key”', (tester) async {
      await pumpWithKey(tester);

      expect(find.text(t('keyCodes.touch')), findsOneWidget);
      expect(find.text(t('keyCodes.tapKey')), findsOneWidget);
      expect(find.byTooltip(t('keyCodes.counter.next', {'name': 'Example'})), findsOneWidget);
    });

    testCodes('a stale row shows no code, and a tap on it reads the key and copies nothing; a fresh one copies', (tester) async {
      final phone = FakeSecurityKeys();
      final fake = FakeOathKey(accounts: usualAccounts());
      final key = FakeKey(productName: 'YubiKey 5C NFC', applets: [fake]);
      final page = await pumpWithKey(tester, overrides: [phone.asOverride]);
      final clipboard = FakeClipboard();
      int nowSec() => page.container.read(clockProvider)().millisecondsSinceEpoch ~/ 1000;

      expect(
        find.descendant(of: find.byType(KeyAccountCard), matching: find.byType(CodeDigits)),
        findsNothing,
        reason: 'no code before the key is read',
      );
      expect(find.text(t('keyCodes.stale')), findsNWidgets(2));

      phone.arrive(key.device(kinds: nfcKey));
      await _tap(tester, find.text('Slow'));

      expect(fake.received, contains(0xa1), reason: 'the key was listed');
      expect(clipboard.writes, isEmpty);
      expect([for (final account in page.vault.state.keyAccounts) account.id], ['k1', 'k2', 'k3', 'k4'], reason: 'the same names, kept');
      final slow = codeAt(rfcVaultAccount(algorithm: 'SHA256', digits: 8, period: 60), nowSec());
      expect(findCode(CodeDigits.grouped(slow)), findsOneWidget);
      expect(find.text(t('keyCodes.readAgain')), findsOneWidget);
      final ago = nowSec() - page.container.read(keyCodesProvider).readAt!;
      expect(find.text('${t('keyCodes.readAgo', {'seconds': ago})} ${t('keyCodes.neverLeave')}'), findsOneWidget);

      await tester.tap(find.text('Slow'));
      await tester.pump();

      expect(clipboard.writes, [slow]);
      expect(page.container.read(toastsProvider)?.message, t('accounts.copied', {'name': 'Slow'}));
    });

    testCodes('reorder mode lists the vault’s accounts only', (tester) async {
      await pumpWithKey(tester);

      await _openSortMenu(tester);
      await _tap(tester, find.text(t('accounts.reorder')));

      expect(find.byType(KeyAccountCard), findsNothing);
      expect(_section(keySection, keyArgs), findsNothing);
      expect(find.byTooltip(t('accounts.reorder.down', {'name': 'Dropbox'})), findsOneWidget);
    });
  });
}
