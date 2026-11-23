import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/core/now.dart';
import 'package:kemlock/features/accounts/add_account_sheet.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_scanner.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../security_keys/key_codes_harness.dart';

const _secret = 'JBSWY3DPEHPK3PXP';

void main() {
  group('scan', () {
    testWidgets('opens on the scanner and explains when the camera is unavailable', (tester) async {
      final semantics = tester.ensureSemantics();
      final scanner = FakeScanner()..deny();
      await _open(tester, scanner: scanner);

      expect(tester.getSemantics(find.bySemanticsLabel(t('addAccount.tab.scan'))), isSemantics(isSelected: true));
      expect(find.text(t('qrScanner.error.denied')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('offers a photo picker as the second method', (tester) async {
      await _open(tester);

      await _tab(tester, 'addAccount.tab.photo');

      expect(find.text(t('qrScanner.chooseImage')), findsOneWidget);
    });

    testWidgets('shows a scanned account with its live code and settings, then adds it', (tester) async {
      final scanner = FakeScanner();
      final sheet = await _open(tester, scanner: scanner);

      await scanner.emitScan(tester, 'otpauth://totp/GitHub:octocat?secret=$_secret&issuer=GitHub');
      await tester.pumpAndSettle();

      expect(find.text(t('addAccount.scan.success')), findsOneWidget);
      expect(find.text('octocat'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d{3} \d{3}$')), findsOneWidget);
      expect(find.text('SHA-1'), findsOneWidget);
      expect(find.text(t('addAccount.digitsValue', {'digits': 6})), findsOneWidget);
      expect(find.text(t('accountSheet.secondsShort', {'seconds': 30})), findsOneWidget);
      // The viewfinder froze on the code it found.
      expect(scanner.isScanning, isFalse);
      expect(find.text(t('addAccount.scan.hint')), findsNothing);

      await _add(tester);

      expect(_fields(sheet.vault.added.single), {
        'type': 'totp',
        'issuer': 'GitHub',
        'label': 'octocat',
        'secret': _secret,
        'algorithm': 'SHA1',
        'digits': 6,
        'period': 30,
      });
      expect(find.byType(AddAccountSheet), findsNothing);
    });

    testWidgets("shows a scanned counter-based account's counter", (tester) async {
      final scanner = FakeScanner();
      await _open(tester, scanner: scanner);

      await scanner.emitScan(tester, 'otpauth://hotp/Bank?secret=$_secret&counter=12');
      await tester.pumpAndSettle();

      expect(find.text('HOTP'), findsOneWidget);
      expect(find.text(t('addAccount.counterValue', {'counter': 12})), findsOneWidget);
    });

    testWidgets('explains a QR code that holds no account, and keeps scanning', (tester) async {
      final scanner = FakeScanner();
      final sheet = await _open(tester, scanner: scanner);

      await scanner.emitScan(tester, 'https://example.com');

      expect(find.text(t('addAccount.scan.error', {'raw': 'https://example.com'})), findsOneWidget);
      expect(find.text(t('addAccount.add')), findsNothing);

      await scanner.emitScan(tester, 'otpauth://totp/GitHub?secret=$_secret');
      await tester.pumpAndSettle();
      expect(find.text(t('addAccount.scan.error', {'raw': 'https://example.com'})), findsNothing);
      expect(find.text(t('addAccount.scan.success')), findsOneWidget);
      expect(sheet.vault.added, isEmpty);
    });

    testWidgets('scans again', (tester) async {
      final scanner = FakeScanner();
      await _open(tester, scanner: scanner);
      await scanner.emitScan(tester, 'otpauth://totp/GitHub?secret=$_secret');
      await tester.pumpAndSettle();

      await tester.tap(find.text(t('addAccount.scan.again')));
      await tester.pumpAndSettle();

      expect(find.text(t('addAccount.scan.success')), findsNothing);
      expect(find.text(t('addAccount.scan.hint')), findsOneWidget);
      expect(scanner.isScanning, isTrue);
    });

    testWidgets('reads the QR code in a picked picture', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('setup.png');
      final reader = FakeQrImageReader()..result = 'otpauth://totp/Proton:me?secret=$_secret&issuer=Proton';
      final sheet = await _open(tester, files: files, reader: reader);
      await _tab(tester, 'addAccount.tab.photo');

      await tester.tap(find.text(t('qrScanner.chooseImage')));
      await tester.pumpAndSettle();

      expect(files.opened, ['photos']);
      expect(reader.paths, ['/picked/setup.png']);
      // The picture holds the secret: the picker's copy is deleted once it is read
      expect(files.forgotten, ['/picked/setup.png']);
      expect(find.text(t('addAccount.scan.success')), findsOneWidget);
      await _add(tester);
      expect(sheet.vault.added.single.issuer, 'Proton');
    });

    testWidgets('explains a picture without a QR code', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('cat.png');
      await _open(tester, files: files, reader: FakeQrImageReader());
      await _tab(tester, 'addAccount.tab.photo');

      await tester.tap(find.text(t('qrScanner.chooseImage')));
      await tester.pumpAndSettle();

      expect(find.text(t('qrScanner.error.notFound')), findsOneWidget);
      expect(files.forgotten, ['/picked/cat.png']);
    });

    testWidgets('closes without adding anything', (tester) async {
      final sheet = await _open(tester);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(AddAccountSheet), findsNothing);
      expect(sheet.vault.added, isEmpty);
    });
  });

  group('manual entry', () {
    testWidgets('adds an account with default TOTP parameters', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'GitHub');
      await _type(tester, 'addAccount.field.label', 'octocat');
      await _type(tester, 'addAccount.field.secret', 'jbsw y3dp ehpk 3pxp');
      await _add(tester);

      expect(_fields(sheet.vault.added.single), {
        'type': 'totp',
        'issuer': 'GitHub',
        'label': 'octocat',
        'secret': _secret,
        'algorithm': 'SHA1',
        'digits': 6,
        'period': 30,
      });
      expect(find.byType(AddAccountSheet), findsNothing);
    });

    testWidgets('previews the live code once the key is valid', (tester) async {
      await _openManual(tester);

      expect(find.text('––– –––'), findsOneWidget);
      await _type(tester, 'addAccount.field.secret', _secret);

      expect(find.textContaining(RegExp(r'^\d{3} \d{3}$')), findsOneWidget);
    });

    testWidgets('lets the user choose algorithm and digits under Advanced', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'Bank');
      await _type(tester, 'addAccount.field.secret', _secret);
      await _advanced(tester);
      await tester.tap(find.text('SHA-512'));
      await tester.tap(find.text('8'));
      await tester.pump();
      await _add(tester);

      final account = sheet.vault.added.single;
      expect((account.algorithm, account.digits), ('SHA512', 8));
    });

    testWidgets('requires a secret', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'GitHub');
      await _add(tester);

      expect(find.text(t('addAccount.manual.error.secret')), findsOneWidget);
      expect(sheet.vault.added, isEmpty);
      expect(find.byType(AddAccountSheet), findsOneWidget);
    });

    testWidgets('rejects a key that is not Base32', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'GitHub');
      await _type(tester, 'addAccount.field.secret', 'NOT-BASE-1890');
      await _add(tester);

      expect(find.text(t('addAccount.manual.error.secretInvalid')), findsOneWidget);
      expect(sheet.vault.added, isEmpty);
    });

    testWidgets('requires an issuer or a label', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.secret', _secret);
      await _add(tester);

      expect(find.text(t('addAccount.manual.error.name')), findsOneWidget);
      expect(sheet.vault.added, isEmpty);
    });

    testWidgets('rejects periods outside 15–300 seconds', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'GitHub');
      await _type(tester, 'addAccount.field.secret', _secret);
      await _advanced(tester);
      await tester.enterText(_numberField('addAccount.field.period'), '5');
      await _add(tester);

      expect(find.text(t('addAccount.manual.error.period')), findsOneWidget);
      expect(sheet.vault.added, isEmpty);
    });

    testWidgets('keeps what was typed while trying the other tabs', (tester) async {
      await _openManual(tester);
      await _type(tester, 'addAccount.field.issuer', 'GitHub');

      await _tab(tester, 'addAccount.tab.photo');
      await _tab(tester, 'addAccount.tab.manual');

      expect(find.widgetWithText(TextField, 'GitHub'), findsOneWidget);
    });

    testWidgets('tells screen readers whether Advanced is open, and hides its fields until it is', (tester) async {
      final semantics = tester.ensureSemantics();
      await _openManual(tester);
      final toggle = find.bySemanticsLabel(t('addAccount.advanced'));

      expect(tester.getSemantics(toggle), isSemantics(isButton: true, hasExpandedState: true, isExpanded: false));
      expect(find.bySemanticsLabel(t('addAccount.field.period')), findsNothing);

      await _advanced(tester);

      expect(tester.getSemantics(toggle), isSemantics(isExpanded: true));
      expect(find.bySemanticsLabel(t('addAccount.field.period')), findsOneWidget);
      semantics.dispose();
    });
  });

  group('HOTP and Steam', () {
    testWidgets('adds a counter-based account with its starting counter', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'Bank');
      await _type(tester, 'addAccount.field.secret', _secret);
      await _advanced(tester);
      await tester.tap(find.text('HOTP'));
      await tester.pump();
      await tester.enterText(_numberField('addAccount.field.counter'), '7');
      await _add(tester);

      expect(_fields(sheet.vault.added.single), {
        'type': 'hotp',
        'issuer': 'Bank',
        'label': '',
        'secret': _secret,
        'algorithm': 'SHA1',
        'digits': 6,
        'period': 30,
        'counter': 7,
      });
    });

    testWidgets('adds a Steam Guard account without asking for algorithm or digits', (tester) async {
      final sheet = await _openManual(tester);

      await _type(tester, 'addAccount.field.issuer', 'Steam');
      await _type(tester, 'addAccount.field.secret', _secret);
      await _advanced(tester);
      await tester.tap(find.descendant(of: find.byType(SegmentedControl<OtpType>), matching: find.text('Steam')));
      await tester.pump();

      expect(find.text('SHA-256'), findsNothing);
      expect(find.text(t('addAccount.steamHint')), findsOneWidget);
      // Steam codes are five characters from Steam's alphabet.
      expect(find.textContaining(RegExp(r'^[2-9BCDFGHJKMNPQRTVWXY]{5}$')), findsOneWidget);
      await _add(tester);

      final account = sheet.vault.added.single;
      expect((account.kind, account.period), (OtpType.steam, 30));
    });
  });

  group('Google Authenticator transfer', () {
    testWidgets('adds every account in a transfer QR code at once', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('transfer.png');
      final reader = FakeQrImageReader()
        ..result = _migrationUri([(name: 'GitHub:octocat', issuer: 'GitHub'), (name: 'alice@example.com', issuer: 'Google')]);
      final sheet = await _open(tester, files: files, reader: reader);
      await _tab(tester, 'addAccount.tab.photo');
      await tester.tap(find.text(t('qrScanner.chooseImage')));
      await tester.pumpAndSettle();

      expect(find.text(t('addAccount.migration.found', {'count': 2})), findsOneWidget);
      await tester.tap(find.text(t('addAccount.migration.add', {'count': 2})));
      await tester.pumpAndSettle();

      final [github, google] = sheet.vault.addedMany.single;
      expect((github.issuer, github.label, github.kind), ('GitHub', 'octocat', OtpType.totp));
      expect((google.issuer, google.label), ('Google', 'alice@example.com'));
      expect(find.byType(AddAccountSheet), findsNothing);
    });

    testWidgets('explains when a transfer QR code is damaged', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('transfer.png');
      final reader = FakeQrImageReader()..result = 'otpauth-migration://offline?data=%%%';
      final sheet = await _open(tester, files: files, reader: reader);
      await _tab(tester, 'addAccount.tab.photo');
      await tester.tap(find.text(t('qrScanner.chooseImage')));
      await tester.pumpAndSettle();

      expect(find.text(t('addAccount.migration.error')), findsOneWidget);
      expect(sheet.vault.addedMany, isEmpty);
    });

    testWidgets('takes a transfer QR code from the camera too', (tester) async {
      final scanner = FakeScanner();
      final sheet = await _open(tester, scanner: scanner);

      await scanner.emitScan(tester, _migrationUri([(name: 'alice', issuer: 'ACME')]));
      await tester.pumpAndSettle();

      expect(find.text(t('addAccount.migration.found', {'count': 1})), findsOneWidget);
      expect(find.text(t('addAccount.migration.hint')), findsOneWidget);
      await tester.tap(find.text(t('addAccount.migration.add', {'count': 1})));
      await tester.pumpAndSettle();
      expect(sheet.vault.addedMany.single.single.issuer, 'ACME');
    });
  });

  // openspec: add-security-key-codes, task 6.3
  group('keeping it on a security key', () {
    const known = KeyAccount(id: 'ka1', device: '0102030405060708', name: 'Bank:ada', issuer: 'Bank', label: 'ada', addedAt: 1);
    final keep = find.text(t('keyCodes.keep.key'));

    for (final (keys, shown) in [
      (const [known], true),
      (const <KeyAccount>[], false),
    ]) {
      testWidgets('is ${shown ? '' : 'not '}offered to a vault that knows ${keys.isEmpty ? 'no' : 'a'} key', (tester) async {
        await _openManual(tester, keyAccounts: keys);

        expect(keep, shown ? findsOneWidget : findsNothing);
      });
    }

    testWidgets('chosen, writes the account to the key and adds a key entry, with nothing for the vault', (tester) async {
      final phone = FakeSecurityKeys();
      final oath = FakeOathKey(accounts: usualAccounts());
      final sheet = await _openManual(tester, keyAccounts: const [known], overrides: [phone.asOverride]);
      phone.arrive(FakeKey(applets: [oath]).device(kinds: nfcKey));

      await _type(tester, 'addAccount.field.issuer', 'GitHub');
      await _type(tester, 'addAccount.field.label', 'octocat');
      await _type(tester, 'addAccount.field.secret', _secret);
      await tester.ensureVisible(keep);
      await tester.pumpAndSettle();
      await tester.tap(keep);
      await tester.pumpAndSettle();
      expect(find.text(t('keyCodes.keep.detail')), findsOneWidget);
      await _add(tester);

      expect(oath.find('GitHub:octocat'), isNotNull);
      expect(sheet.vault.added, isEmpty);
      expect(sheet.vault.keyAccountSaves.last.map((account) => account.name), contains('GitHub:octocat'));
      expect(
        jsonEncode([for (final save in sheet.vault.keyAccountSaves) ...save]),
        isNot(contains(_secret)),
        reason: 'no secret reaches the vault',
      );
      expect(find.byType(AddAccountSheet), findsNothing);
    });

    testWidgets('a write that fails adds nothing anywhere, and keeps the form filled', (tester) async {
      final phone = FakeSecurityKeys();
      final sheet = await _openManual(tester, keyAccounts: const [known], overrides: [phone.asOverride]);
      // A key without the code application.
      phone.arrive(FakeKey().device(kinds: nfcKey));

      await _type(tester, 'addAccount.field.issuer', 'GitHub');
      await _type(tester, 'addAccount.field.secret', _secret);
      await tester.ensureVisible(keep);
      await tester.pumpAndSettle();
      await tester.tap(keep);
      await tester.pumpAndSettle();
      await _add(tester);

      expect(sheet.vault.added, isEmpty);
      expect(sheet.vault.keyAccountSaves, isEmpty);
      expect(find.byType(AddAccountSheet), findsOneWidget);
      expect(find.widgetWithText(TextField, 'GitHub'), findsOneWidget);
      expect(find.text(t('keyCodes.unsupported')), findsOneWidget);
    });
  });

  testWidgets('adds the account to the open vault from the tab bar', (tester) async {
    final semantics = tester.ensureSemantics();
    _useTallScreen(tester);
    final app = TestApp();
    await tester.runAsync(() => app.createVault('pw'));
    // The codes on the Codes tab would tick on otherwise, leaving a timer behind.
    await app.pump(tester, overrides: [FakeScanner().asOverride, nowSecondsProvider.overrideWith(_StillSecond.new)]);
    await app.unlock(tester, 'pw');

    await tester.tap(find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addAccount'))));
    await tester.pumpAndSettle();
    await _tab(tester, 'addAccount.tab.manual');
    await _type(tester, 'addAccount.field.issuer', 'GitHub');
    await _type(tester, 'addAccount.field.secret', _secret);
    await _add(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(app.state.accounts.single.issuer, 'GitHub');
    expect(find.text(t('app.snack.accountAdded', {'name': 'GitHub'})), findsOneWidget);
    semantics.dispose();
  });
}

/// The vault, recording what the sheet adds instead of saving it.
class _RecordingVault extends VaultController {
  _RecordingVault({this.keyAccounts = const []});

  /// What the vault remembers of the accounts on a key, at the start.
  final List<KeyAccount> keyAccounts;

  /// Every list of on-key accounts the sheet had saved, in order.
  final keyAccountSaves = <List<KeyAccount>>[];

  final added = <OtpAccount>[];
  final addedMany = <List<OtpAccount>>[];

  @override
  VaultState build() => VaultState(
    phase: VaultPhase.unlocked,
    keyAccounts: keyAccounts,
    vault: const VaultInfo(id: 'main'),
  );

  @override
  Future<void> addAccount(OtpAccount data) async => added.add(data);

  @override
  Future<void> addAccounts(List<OtpAccount> list) async => addedMany.add(list);

  @override
  Future<bool> saveKeyAccounts(List<KeyAccount> next) async {
    keyAccountSaves.add(next);
    state = state.copyWith(keyAccounts: next);
    return true;
  }
}

/// The clock's second, standing still: the codes on screen don't tick, so no timer outlives a test.
class _StillSecond extends NowSeconds {
  @override
  int build() => testNow.millisecondsSinceEpoch ~/ 1000;
}

/// A phone screen tall enough for every tab without scrolling: 393 by 1200 points.
void _useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 1200) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Opens the sheet over a page, with a fake camera, pickers and picture reader.
Future<({_RecordingVault vault})> _open(
  WidgetTester tester, {
  FakeScanner? scanner,
  FakeFiles? files,
  FakeQrImageReader? reader,
  List<KeyAccount> keyAccounts = const [],
  List<Override> overrides = const [],
}) async {
  _useTallScreen(tester);
  final vault = _RecordingVault(keyAccounts: keyAccounts);
  await pumpScreen(
    tester,
    const Scaffold(body: SizedBox.expand()),
    overrides: [
      vaultControllerProvider.overrideWith(() => vault),
      nowSecondsProvider.overrideWith(_StillSecond.new),
      (scanner ?? FakeScanner()).asOverride,
      (files ?? FakeFiles()).asOverride,
      (reader ?? FakeQrImageReader()).asOverride,
      ...overrides,
    ],
  );
  unawaited(showAddAccountSheet(tester.element(find.byType(Scaffold))));
  await tester.pumpAndSettle();
  return (vault: vault);
}

Future<({_RecordingVault vault})> _openManual(
  WidgetTester tester, {
  List<KeyAccount> keyAccounts = const [],
  List<Override> overrides = const [],
}) async {
  final sheet = await _open(tester, keyAccounts: keyAccounts, overrides: overrides);
  await _tab(tester, 'addAccount.tab.manual');
  return sheet;
}

Future<void> _tab(WidgetTester tester, String id) async {
  await tester.tap(find.text(t(id)));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String labelId, String text) async {
  await tester.enterText(find.widgetWithText(TextField, t(labelId)), text);
  await tester.pump();
}

Future<void> _advanced(WidgetTester tester) async {
  await tester.tap(find.text(t('addAccount.advanced')));
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, t('addAccount.add')));
  await tester.pumpAndSettle();
}

/// The number field beside the advanced row named [labelId].
Finder _numberField(String labelId) => find.descendant(of: find.widgetWithText(Row, t(labelId)), matching: find.byType(TextField));

/// What the sheet hands the vault, without the id and date the vault sets.
Map<String, Object?> _fields(OtpAccount account) => account.toJson()
  ..remove('id')
  ..remove('addedAt');

/// A Google Authenticator "Transfer accounts" link, its payload protobuf-encoded by hand.
String _migrationUri(List<({String name, String issuer})> accounts) {
  List<int> lengthDelimited(int no, List<int> data) => [(no << 3) | 2, data.length, ...data];
  List<int> varint(int no, int value) => [no << 3, value];
  final payload = [
    for (final (:name, :issuer) in accounts)
      ...lengthDelimited(1, [
        ...lengthDelimited(1, utf8.encode('12345678901234567890')),
        ...lengthDelimited(2, utf8.encode(name)),
        ...lengthDelimited(3, utf8.encode(issuer)),
        ...varint(4, 1), // SHA1
        ...varint(5, 1), // 6 digits
        ...varint(6, 2), // TOTP
      ]),
    ...varint(2, 1),
  ];
  return 'otpauth-migration://offline?data=${Uri.encodeComponent(base64.encode(payload))}';
}
