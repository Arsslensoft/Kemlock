import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/breaches/breach_providers.dart';
import 'package:kemlock/features/breaches/breach_scan.dart';
import 'package:kemlock/features/breaches/breach_widgets.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_owner_check.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../breaches/breach_kit.dart';
import '../security_keys/key_codes_harness.dart';
import '../sync/sync_screen_kit.dart' show fakeSync;
import 'codes_fakes.dart';

/// The vault's settings with "Ask before showing a secret" on.
class _AskingPrefs extends PrefsNotifier {
  @override
  Prefs build() => const Prefs(askBeforeSecret: true);
}

/// What the sheet called back with.
class _Calls {
  final updated = <OtpAccount>[];
  final deleted = <String>[];
  final copied = <OtpAccount>[];
}

/// Pumps a page with a button that opens [account]'s sheet, at 55 s
/// (code 287082, five seconds left) unless [atMs] says otherwise, and opens it.
Future<_Calls> _open(
  WidgetTester tester,
  OtpAccount account, {
  int atMs = 55000,
  List<String> allTags = const [],
  List<Override> overrides = const [],
}) async {
  final calls = _Calls();
  await pumpAt(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showAccountSheet(
              context,
              account: account,
              allTags: allTags,
              onDelete: calls.deleted.add,
              onUpdate: calls.updated.add,
              onCopied: calls.copied.add,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
    atMs: atMs,
    overrides: overrides,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return calls;
}

/// Sync with one shared space, "Family".
final _familySpace = SyncSnapshot(
  settings: SyncSettings(
    spaces: [
      Space(
        id: 'fam',
        name: 'Family',
        target: SyncTarget(
          dav: const DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'pw'),
          file: spaceFile('fam'),
          key: 'a2V5',
        ),
        joinedAt: 1,
      ),
    ],
  ),
);
Finder get _sheet => find.byType(AccountSheet);

Finder _inSheet(Finder finder) => find.descendant(of: _sheet, matching: finder);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The detail row labelled [labelId].
Finder _row(String labelId) => find.ancestor(of: _inSheet(find.text(t(labelId))), matching: find.byType(Row)).first;

Finder _field(String labelId) => _inSheet(find.widgetWithText(TextField, t(labelId)));

void main() {
  late FakeClipboard clipboard;

  setUp(() => clipboard = FakeClipboard());

  group('the code', () {
    testCodes('shows the code, the upcoming one and when it comes', (tester) async {
      await _open(tester, rfcAccount);

      expect(find.bySemanticsLabel('GitHub'), findsWidgets);
      expect(_inSheet(findCode('287 082')), findsOneWidget);
      expect(_inSheet(find.text('359 152')), findsOneWidget);
      expect(_inSheet(find.text(t('accountCard.nextCodes.in', {'seconds': 5}))), findsOneWidget);
      expect(_inSheet(find.text(t('accountSheet.secondsShort', {'seconds': 5}))), findsOneWidget);
    });

    testCodes('copies the code from the copy button', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.copy'))));

      expect(clipboard.text, '287082');
      expect(calls.copied.single.id, 'acc');
    });

    testCodes('copies the code with a tap on it', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.tapToCopy'))));

      expect(clipboard.text, '287082');
      expect(calls.copied, hasLength(1));
    });

    testCodes('shows the counter instead of a countdown for HOTP', (tester) async {
      await _open(tester, rfcAccount.copyWith(type: OtpType.hotp, counter: 4));

      expect(_inSheet(find.text(t('accountSheet.counter', {'counter': 4}))), findsOneWidget);
      expect(_inSheet(find.text(t('accountSheet.upNext'))), findsNothing);
    });

    testCodes('moves an HOTP account on to its next code', (tester) async {
      final hotp = rfcAccount.copyWith(type: OtpType.hotp, counter: 0);
      final calls = await _open(tester, hotp);

      await _tap(tester, find.bySemanticsLabel(t('accountCard.hotpNext', {'name': 'GitHub'})));

      expect(calls.updated.single, hotp.copyWith(counter: 1));
    });

    testCodes('closes with the close button', (tester) async {
      await _open(tester, rfcAccount);

      await _tap(tester, find.byTooltip(t('accountSheet.close')));

      expect(_sheet, findsNothing);
    });
  });

  group('pinning', () {
    testCodes('pins the account', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.pin'))));

      expect(calls.updated.single, rfcAccount.copyWith(pinned: true));
    });

    testCodes('shows the pin as soon as the vault has it', (tester) async {
      final vault = FakeVaultController(openVault(accounts: [rfcAccount]), apply: true);
      await _open(tester, rfcAccount, overrides: [fakeVault(vault)]);

      await vault.updateAccount(rfcAccount.copyWith(pinned: true));
      await tester.pump();
      expect(_inSheet(find.text(t('accountSheet.pinned'))), findsOneWidget);
      expect(tester.getSemantics(_inSheet(find.text(t('accountSheet.pinned')))), isSemantics(isToggled: true, hasToggledState: true));
    });
  });

  group('the details', () {
    testCodes('lists the type, algorithm, digits and period', (tester) async {
      await _open(tester, rfcAccount.copyWith(algorithm: 'SHA256', digits: 8, period: 60));

      expect(_inSheet(find.text('TOTP')), findsOneWidget);
      expect(_inSheet(find.text('SHA-256')), findsOneWidget);
      expect(find.descendant(of: _row('viewQr.label.digits'), matching: find.text('8')), findsOneWidget);
      expect(_inSheet(find.text(t('accountSheet.secondsShort', {'seconds': 60}))), findsOneWidget);
    });

    testCodes('leaves out the algorithm and digits for Steam, and the period for HOTP', (tester) async {
      await _open(tester, rfcAccount.copyWith(type: OtpType.steam));
      expect(_inSheet(find.text('Steam')), findsOneWidget);
      expect(_inSheet(find.text(t('viewQr.label.algorithm'))), findsNothing);

      await _open(tester, rfcAccount.copyWith(type: OtpType.hotp));
      expect(_inSheet(find.text('HOTP')), findsOneWidget);
      expect(_inSheet(find.text(t('viewQr.label.period'))), findsNothing);
    });

    testCodes('shows the note and tags', (tester) async {
      await _open(tester, rfcAccount.copyWith(note: 'Second phone', tags: ['Work']));

      expect(_inSheet(find.text('Second phone')), findsOneWidget);
      expect(_inSheet(find.text('Work')), findsOneWidget);
    });

    testCodes('shows when the account was added', (tester) async {
      await _open(tester, rfcAccount.copyWith(addedAt: testNow.millisecondsSinceEpoch));

      expect(_inSheet(find.text('Oct 16, 2026')), findsOneWidget);
    });

    testCodes('names the shared space the account is in', (tester) async {
      await _open(tester, rfcAccount.copyWith(spaceId: 'sp1'), overrides: [spaceNameProvider('sp1').overrideWithValue('Family')]);

      expect(_inSheet(find.text(t('spaces.picker.label'))), findsOneWidget);
      expect(_inSheet(find.text('Family')), findsOneWidget);
    });

    testCodes('counts the backup codes left', (tester) async {
      const service = BackupService(
        id: 's',
        serviceName: 'GitHub',
        codes: [
          BackupCode(code: 'a'),
          BackupCode(code: 'b', used: true),
          BackupCode(code: 'c'),
        ],
        addedAt: 0,
      );
      await _open(
        tester,
        rfcAccount,
        overrides: [
          fakeVault(FakeVaultController(openVault(backupServices: [service]))),
        ],
      );

      expect(_inSheet(find.text(t('accountSheet.backupCodes.left', {'count': 2}))), findsOneWidget);
    });

    testCodes('says when no backup codes are saved, unless the service gives none', (tester) async {
      await _open(tester, rfcAccount);
      expect(_inSheet(find.text(t('accountSheet.backupCodes.none'))), findsOneWidget);

      await _open(tester, rfcAccount.copyWith(noBackupCodes: true));
      expect(_inSheet(find.text(t('accountSheet.backupCodes'))), findsNothing);
    });
  });

  group('the secret', () {
    const grouped = 'GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ';

    testCodes('keeps the secret off the screen until it is revealed', (tester) async {
      await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.viewQr'))));
      expect(_inSheet(find.text(grouped)), findsNothing);
      expect(find.textContaining(rfcAccount.secret), findsNothing);
      expect(find.byType(QrImageView), findsNothing);

      await _tap(tester, _inSheet(find.text(t('accountSheet.reveal'))));
      expect(_inSheet(find.text(grouped)), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testCodes('copies the secret and hides it again', (tester) async {
      await _open(tester, rfcAccount);
      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.viewQr'))));
      await _tap(tester, _inSheet(find.text(t('accountSheet.reveal'))));

      await _tap(tester, find.bySemanticsLabel(t('viewQr.secret.copy')));
      expect(clipboard.text, rfcAccount.secret);

      await _tap(tester, find.byTooltip(t('viewQr.secret.hide')));
      expect(_inSheet(find.text(grouped)), findsNothing);
    });

    testCodes('asks who it is first when Settings says so, and a refusal keeps it hidden', (tester) async {
      final check = FakeOwnerCheck(passes: false);
      await _open(tester, rfcAccount, overrides: [check.asOverride, prefsProvider.overrideWith(_AskingPrefs.new)]);
      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.viewQr'))));

      await _tap(tester, _inSheet(find.text(t('accountSheet.reveal'))));
      expect(check.reasons, [t('accountSheet.reveal.confirm')]);
      expect(_inSheet(find.text(grouped)), findsNothing);
      expect(find.byType(QrImageView), findsNothing);

      check.passes = true;
      await _tap(tester, _inSheet(find.text(t('accountSheet.reveal'))));
      expect(check.reasons, hasLength(2));
      expect(_inSheet(find.text(grouped)), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testCodes('asks nothing while Settings does not', (tester) async {
      final check = FakeOwnerCheck();
      await _open(tester, rfcAccount, overrides: [check.asOverride]);
      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.viewQr'))));

      await _tap(tester, _inSheet(find.text(t('accountSheet.reveal'))));

      expect(check.reasons, isEmpty);
      expect(_inSheet(find.text(grouped)), findsOneWidget);
    });
  });

  group('editing', () {
    testCodes('renames the account', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await tester.enterText(_field('addAccount.field.issuer'), 'GitHub Work');
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount.copyWith(issuer: 'GitHub Work'));
      expect(_field('addAccount.field.issuer'), findsNothing);
    });

    testCodes('saves a note with the account', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await tester.enterText(_field('accountSheet.note'), 'Recovery email: work');
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount.copyWith(note: 'Recovery email: work'));
    });

    testCodes('drops an emptied note and trims the names', (tester) async {
      final calls = await _open(tester, rfcAccount.copyWith(note: 'old'));

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await tester.enterText(_field('addAccount.field.label'), '  octo  ');
      await tester.enterText(_field('accountSheet.note'), '   ');
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount.copyWith(label: 'octo'));
      expect(calls.updated.single.toJson().containsKey('note'), isFalse);
    });

    testCodes('needs a service or an account name', (tester) async {
      await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await tester.enterText(_field('addAccount.field.issuer'), ' ');
      await tester.enterText(_field('addAccount.field.label'), '');
      await tester.pump();

      final save = tester.widget<FilledButton>(find.ancestor(of: find.text(t('accountSheet.save')), matching: find.byType(FilledButton)));
      expect(save.onPressed, isNull);
    });

    testCodes('cancels without saving', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await tester.enterText(_field('addAccount.field.issuer'), 'Other');
      await _tap(tester, _inSheet(find.text(t('addAccount.cancel'))));

      expect(calls.updated, isEmpty);
      expect(_inSheet(find.text(t('accountSheet.type'))), findsOneWidget);
    });

    testCodes('saves tags, with the one still being typed', (tester) async {
      final calls = await _open(tester, rfcAccount, allTags: ['Work', 'Games']);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await _tap(tester, _inSheet(find.text('Work')));
      await tester.enterText(_field('tags.label'), 'Bank');
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount.copyWith(tags: ['Work', 'Bank']));
    });

    testCodes('marks a service that gives no backup codes', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await _tap(tester, _inSheet(find.text(t('accountSheet.noBackupCodes'))));
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount.copyWith(noBackupCodes: true));
    });

    testCodes('moves the account into a shared space', (tester) async {
      final calls = await _open(tester, rfcAccount, overrides: [fakeSync(_familySpace)]);

      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await _tap(tester, _inSheet(find.text(t('spaces.picker.mine'))));
      await _tap(tester, find.text('Family').last);
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount.copyWith(spaceId: 'fam'));
    });

    testCodes('takes the account out of its shared space', (tester) async {
      final calls = await _open(tester, rfcAccount.copyWith(spaceId: 'fam'), overrides: [fakeSync(_familySpace)]);
      await _tap(tester, _inSheet(find.text(t('accountSheet.edit'))));
      await _tap(tester, _inSheet(find.text('Family')));
      await _tap(tester, find.text(t('spaces.picker.mine')).last);
      await _tap(tester, _inSheet(find.text(t('accountSheet.save'))));

      expect(calls.updated.single, rfcAccount);
    });
  });

  group('breaches of the service', () {
    Override found(OtpAccount account) => breachFindingsProvider.overrideWithValue(scanBreaches([account], const [], fixtureBreaches));

    testCodes('warns of a breach listed since the account was added, with a way to mark it dealt with', (tester) async {
      final account = rfcAccount.copyWith(issuer: 'Canva', addedAt: addedIn2019);
      await _open(tester, account, overrides: [found(account)]);

      expect(_inSheet(find.text(t('breaches.alert.title', {'name': 'Canva'}))), findsOneWidget);
      expect(_inSheet(find.text(t('breaches.passwords'))), findsOneWidget);
      expect(_inSheet(find.text(t('breaches.dealtWith'))), findsOneWidget);
      expect(_inSheet(find.byType(BreachCredit)), findsOneWidget);
    });

    testCodes('lists a breach from before the account was added by name and year, without a warning', (tester) async {
      final account = rfcAccount.copyWith(issuer: 'Adobe', addedAt: addedIn2019);
      await _open(tester, account, overrides: [found(account)]);

      expect(_inSheet(find.text('Adobe, 2013')), findsOneWidget);
      expect(_inSheet(find.text(t('breaches.dealtWith'))), findsNothing);
      expect(_inSheet(find.byType(BreachCredit)), findsOneWidget);
    });

    testCodes('lists a breach that was dealt with among the earlier ones', (tester) async {
      final account = rfcAccount.copyWith(issuer: 'Canva', addedAt: addedIn2019, breachesDismissed: ['Canva']);
      await _open(tester, account, overrides: [found(account)]);

      expect(_inSheet(find.text(t('breaches.alert.title', {'name': 'Canva'}))), findsNothing);
      expect(_inSheet(find.text('Canva, 2019')), findsOneWidget);
    });

    testCodes('says nothing of breaches for a service that had none', (tester) async {
      final account = rfcAccount.copyWith(issuer: 'GitHub');
      await _open(tester, account, overrides: [found(account)]);

      expect(_inSheet(find.byType(BreachCredit)), findsNothing);
      expect(_inSheet(find.text(t('breaches.earlier'))), findsNothing);
    });
  });

  group('removing', () {
    testCodes('closes the sheet and asks the page to remove the account', (tester) async {
      final calls = await _open(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('accountCard.tooltip.remove'))));

      expect(calls.deleted, ['acc']);
      expect(_sheet, findsNothing);
    });
  });

  // openspec: add-security-key-codes, task 6.2
  group('putting it on a key', () {
    const known = KeyAccount(id: 'ka1', device: '0102030405060708', name: 'Bank:ada', issuer: 'Bank', label: 'ada', addedAt: 1);

    Future<({FakeVaultController vault, FakeOathKey oath})> openWithKey(
      WidgetTester tester,
      OtpAccount account, {
      List<KeyAccount> keys = const [known],
    }) async {
      final vault = FakeVaultController(openVault(accounts: [account], keyAccounts: keys));
      final phone = FakeSecurityKeys();
      final oath = FakeOathKey(accounts: usualAccounts());
      await _open(tester, account, overrides: [fakeVault(vault), phone.asOverride]);
      phone.arrive(FakeKey(applets: [oath]).device(kinds: nfcKey));
      return (vault: vault, oath: oath);
    }

    testCodes('move and copy are offered once the vault knows a key', (tester) async {
      await openWithKey(tester, rfcAccount);

      expect(_inSheet(find.text(t('keyCodes.move'))), findsOneWidget);
      expect(_inSheet(find.text(t('keyCodes.copy'))), findsOneWidget);
    });

    testCodes('neither is offered to a vault that knows no key', (tester) async {
      await openWithKey(tester, rfcAccount, keys: const []);

      expect(_inSheet(find.text(t('keyCodes.move'))), findsNothing);
      expect(_inSheet(find.text(t('keyCodes.copy'))), findsNothing);
    });

    testCodes('neither is offered for a shared space’s account', (tester) async {
      await openWithKey(tester, rfcAccount.copyWith(spaceId: 'fam'));

      expect(_inSheet(find.text(t('keyCodes.move'))), findsNothing);
      expect(_inSheet(find.text(t('keyCodes.copy'))), findsNothing);
    });

    testCodes('the move warns that a lost key takes the codes and that older backups hold the secret; cancelling sends nothing', (
      tester,
    ) async {
      final sheet = await openWithKey(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('keyCodes.move'))));

      expect(find.text(t('keyCodes.move.warning.lost')), findsOneWidget);
      expect(find.text(t('keyCodes.move.warning.backups')), findsOneWidget);
      await _tap(tester, find.text(t('export.cancel')));
      expect(sheet.oath.received, isEmpty);
      expect(sheet.vault.deleted, isEmpty);
      expect(_sheet, findsOneWidget);
    });

    testCodes('a confirmed move puts the account on the key, takes it out of the vault and closes the sheet', (tester) async {
      final sheet = await openWithKey(tester, rfcAccount);

      await _tap(tester, _inSheet(find.text(t('keyCodes.move'))));
      await _tap(tester, find.text(t('keyCodes.move.confirm')));

      expect(sheet.oath.find('GitHub:octocat'), isNotNull);
      expect(sheet.vault.deleted.single.id, 'acc');
      expect(sheet.vault.state.keyAccounts.map((account) => account.name), contains('GitHub:octocat'));
      expect(_sheet, findsNothing);
    });
  });
}
