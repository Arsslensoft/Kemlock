import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/generator/generator_sheet.dart';
import 'package:kemlock/features/lock/gate_widgets.dart';
import 'package:kemlock/features/logins/login_edit_sheet.dart';
import 'package:kemlock/features/logins/login_inbox.dart';
import 'package:kemlock/features/logins/login_sheet.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/secret_selection.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_clipboard.dart';
import '../../fakes/fake_owner_check.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

const _larkspur = Login(
  id: 'l1',
  name: 'Larkspur Mail',
  username: 'ada@example.org',
  password: 'kT9#vq2L-wPz8!mR4x',
  websites: ['larkspur.example'],
  addedAt: 0,
);

const _account = OtpAccount(id: 'a1', issuer: 'Larkspur Mail', label: 'ada@example.org', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

void main() {
  Future<TestApp> openLogins(
    WidgetTester tester, {
    List<Login> logins = const [_larkspur],
    List<OtpAccount> accounts = const [],
    List<Override> overrides = const [],
  }) async {
    final app = TestApp();
    await startApp(tester, app, overrides: overrides);
    await createVault(tester);
    final controller = app.container.read(vaultControllerProvider.notifier);
    for (final account in accounts) {
      await controller.addAccount(account);
    }
    // The vault gives an account an id of its own: a login linked to 'a1' is linked to it
    final firstAccount = app.container.read(vaultControllerProvider).accounts.firstOrNull?.id;
    for (final login in logins) {
      await controller.addLogin(login.accountId == 'a1' ? login.copyWith(accountId: firstAccount) : login);
    }
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    // An empty vault shows no filters
    if (logins.isNotEmpty) await tapOn(tester, find.text(t('vault.filter.logins')));
    return app;
  }

  List<Login> logins(TestApp app) => app.container.read(vaultControllerProvider).logins;
  String accountId(TestApp app) => app.container.read(vaultControllerProvider).accounts.single.id;
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(LoginSheet), matching: finder);
  Finder inEdit(Finder finder) => find.descendant(of: find.byType(LoginEditSheet), matching: finder);

  testWidgets('lists logins under their filter, found by website, with their tags', (tester) async {
    final autofilled = _larkspur.copyWith(
      id: 'l2',
      name: 'Mastodon',
      username: 'ada',
      // A password of its own: a shared one would tag both Reused first
      password: 'Mq4!vX9#tR2-kW7?',
      websites: ['example.social'],
      source: Login.fromAutofill,
    );
    await openLogins(
      tester,
      logins: [
        _larkspur.copyWith(accountId: 'a1'),
        autofilled,
      ],
      accounts: [_account],
    );

    expect(find.text('Larkspur Mail'), findsOneWidget);
    expect(find.text(t('vault.login.tag.code').toUpperCase()), findsOneWidget);
    expect(find.text(t('vault.login.tag.new').toUpperCase()), findsOneWidget);
    expect(find.textContaining('AutoFill'), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byType(SearchField), matching: find.byType(TextField)), 'larkspur.example');
    await tester.pumpAndSettle();
    expect(find.text('Larkspur Mail'), findsOneWidget);
    expect(find.text('Mastodon'), findsNothing);
  });

  testWidgets('shows the password only when asked, and copies it to the clipboard that clears', (tester) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    await openLogins(tester);
    await tapOn(tester, find.text('Larkspur Mail'));

    expect(inSheet(find.text('ada@example.org')), findsOneWidget);
    expect(inSheet(find.text(_larkspur.password!)), findsNothing);
    await tapOn(tester, inSheet(find.byType(RevealPasswordButton)).first);
    expect(inSheet(find.text(_larkspur.password!)), findsOneWidget);

    await tapOn(tester, inSheet(find.byTooltip(t('logins.copy.password'))));
    expect(copies, contains(_larkspur.password));
    expect(find.text(t('logins.copied.password')), findsOneWidget);
  });

  testWidgets('asks who it is before showing a password when Settings says so, and copies it without asking', (tester) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    final check = FakeOwnerCheck(passes: false);
    const old = 'Old-larkspur-2025';
    final app = await openLogins(
      tester,
      logins: [
        _larkspur.copyWith(previousPasswords: [const PreviousPassword(password: old, until: 0)]),
      ],
      overrides: [check.asOverride],
    );
    app.container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(askBeforeSecret: true));
    await tapOn(tester, find.text('Larkspur Mail'));
    Finder reveal() => inSheet(find.byType(RevealPasswordButton));

    // Refused, the password and the previous one stay hidden
    await tapOn(tester, reveal().first);
    await tapOn(tester, reveal().last);
    expect(check.reasons, [t('logins.reveal.confirm'), t('logins.reveal.confirm')]);
    expect(inSheet(find.text(_larkspur.password!)), findsNothing);
    expect(inSheet(find.text(old)), findsNothing);

    // Copy stays one tap
    await tapOn(tester, inSheet(find.byTooltip(t('logins.copy.password'))).first);
    expect(copies, contains(_larkspur.password));
    expect(check.reasons, hasLength(2));

    check.passes = true;
    await tapOn(tester, reveal().first);
    expect(inSheet(find.text(_larkspur.password!)), findsOneWidget);
    await tapOn(tester, reveal().last);
    expect(inSheet(find.text(old)), findsOneWidget);
    expect(check.reasons, hasLength(4));

    // Hiding asks nothing
    await tapOn(tester, reveal().first);
    expect(inSheet(find.text(_larkspur.password!)), findsNothing);
    expect(check.reasons, hasLength(4));
  });

  testWidgets('the edit sheet asks before showing the saved password, and not one the person typed', (tester) async {
    final check = FakeOwnerCheck(passes: false);
    final app = await openLogins(tester, overrides: [check.asOverride]);
    app.container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(askBeforeSecret: true));
    await tapOn(tester, find.text('Larkspur Mail'));
    await tapOn(tester, inSheet(find.text(t('logins.edit'))));
    final password = inEdit(field(t('logins.field.password')));
    bool obscured() => tester.widget<TextField>(password).obscureText;

    await tapOn(tester, inEdit(find.byType(RevealPasswordButton)));
    expect(check.reasons, [t('logins.reveal.confirm')]);
    expect(obscured(), isTrue);

    // Emptied, the field holds only what is typed next
    await tester.enterText(password, '');
    await tester.enterText(password, 'typed-just-now-2026');
    await tester.pump();
    await tapOn(tester, inEdit(find.byType(RevealPasswordButton)));
    expect(check.reasons, hasLength(1));
    expect(obscured(), isFalse);
  });

  testWidgets('adds a login from Add to vault, offering the code found in the vault', (tester) async {
    final app = await openLogins(tester, logins: const [], accounts: [_account]);
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    await tapOn(tester, find.text(t('vault.add.login')));

    await tester.enterText(inEdit(field(t('logins.field.name'))), 'Larkspur Mail');
    await tester.enterText(inEdit(field(t('logins.field.website'))), 'https://Mail.Larkspur.example/login');
    await tester.pump();
    expect(inEdit(find.text(t('logins.code.found', {'name': 'Larkspur Mail'}))), findsOneWidget);
    // Neither a username nor a password yet
    expect(inEdit(find.text(t('logins.needsSecret'))), findsOneWidget);
    expect(tester.widget<FilledButton>(inEdit(find.widgetWithText(FilledButton, t('logins.save')))).onPressed, isNull);

    await tester.enterText(inEdit(field(t('logins.field.username'))), 'ada@example.org');
    await tester.enterText(inEdit(field(t('logins.field.password'))), 'kT9#vq2L-wPz8!mR4x');
    await tester.pump();
    await tapOn(tester, inEdit(find.widgetWithText(FilledButton, t('logins.save'))));

    final added = logins(app).single;
    expect(added.websites, ['mail.larkspur.example']);
    expect(added.accountId, accountId(app));
    expect(added.password, 'kT9#vq2L-wPz8!mR4x');
  });

  testWidgets('keeps the website, username and password typed from the phone’s password manager', (tester) async {
    await openLogins(tester, logins: const []);
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    await tapOn(tester, find.text(t('vault.add.login')));

    for (final id in ['logins.field.website', 'logins.field.username', 'logins.field.password']) {
      // Null keeps it out of autofill, which the empty default doesn't
      expect(tester.widget<TextField>(inEdit(field(t(id)))).autofillHints, isNull, reason: id);
    }
  });

  testWidgets('copies a password selected in the edit sheet to the clipboard that clears, as Copy does', (tester) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    // What reaches Flutter's plain clipboard
    final plain = <String?>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') plain.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
      if (call.method == 'Clipboard.hasStrings') return {'value': false};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await openLogins(tester);
    await tapOn(tester, find.text('Larkspur Mail'));
    await tapOn(tester, inSheet(find.text(t('logins.edit'))));
    final password = inEdit(field(t('logins.field.password')));
    // The selection toolbar's Copy and Cut go the same way
    expect(tester.widget<TextField>(password).contextMenuBuilder, secretTextMenu);

    await tapOn(tester, inEdit(find.byType(RevealPasswordButton)));
    // The field may sit below what the sheet shows: brought into view and focused, not tapped at a guess
    await tester.ensureVisible(password);
    await tester.showKeyboard(password);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(copies, [_larkspur.password]);
    expect(plain, isEmpty);
  });

  testWidgets('refuses a website field that isn’t a website', (tester) async {
    await openLogins(tester, logins: const []);
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    await tapOn(tester, find.text(t('vault.add.login')));

    await tester.enterText(inEdit(field(t('logins.field.name'))), 'Bank');
    await tester.enterText(inEdit(field(t('logins.field.website'))), 'my bank');
    await tester.enterText(inEdit(field(t('logins.field.password'))), 'secret');
    await tester.pump();

    expect(inEdit(find.text(t('websiteDialog.invalid'))), findsOneWidget);
    expect(tester.widget<FilledButton>(inEdit(find.widgetWithText(FilledButton, t('logins.save')))).onPressed, isNull);
  });

  testWidgets('a changed password is listed under Previous passwords', (tester) async {
    final app = await openLogins(tester);
    await tapOn(tester, find.text('Larkspur Mail'));
    await tapOn(tester, inSheet(find.text(t('logins.edit'))));

    await tester.enterText(inEdit(field(t('logins.field.password'))), 'new-password-2026');
    await tester.pump();
    await tapOn(tester, inEdit(find.widgetWithText(FilledButton, t('logins.save'))));

    expect(logins(app).single.password, 'new-password-2026');
    expect(logins(app).single.previousPasswords!.single.password, _larkspur.password);
    expect(inSheet(find.text(t('logins.previous').toUpperCase())), findsOneWidget);
  });

  testWidgets('deleting asks first, and Undo brings the login back', (tester) async {
    final app = await openLogins(tester);
    await tapOn(tester, find.text('Larkspur Mail'));
    await tester.scrollUntilVisible(inSheet(find.text(t('logins.delete'))), 200, scrollable: inSheet(find.byType(Scrollable)).first);
    await tapOn(tester, inSheet(find.text(t('logins.delete'))));
    expect(find.text(t('logins.delete.title')), findsOneWidget);
    await tapOn(tester, find.descendant(of: find.byType(Dialog), matching: find.text(t('logins.delete.confirm'))));

    expect(logins(app), isEmpty);
    await tapOn(tester, find.text(t('app.undo')));
    expect(logins(app).single.id, 'l1');
  });

  testWidgets('an account’s sheet adds the login its code goes with, linked', (tester) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addAccount(_account);
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, accountRow('Larkspur Mail'));

    final row = find.descendant(of: find.byType(AccountSheet), matching: find.text(t('accountLogin.link')));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.descendant(of: find.byType(AccountSheet), matching: find.byType(Scrollable)).first,
    );
    await tapOn(tester, row);
    expect(inEdit(find.text('Larkspur Mail')), findsWidgets);
    await tester.enterText(inEdit(field(t('logins.field.password'))), 'secret-one');
    await tester.pump();
    await tapOn(tester, inEdit(find.widgetWithText(FilledButton, t('logins.save'))));

    expect(logins(app).single.accountId, accountId(app));
    expect(logins(app).single.name, 'Larkspur Mail');
  });

  // openspec: add-passwords, task 4.6
  testWidgets('the generator lists what AutoFill generated, to copy or save as a login', (tester) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    final app = await openLogins(tester);
    final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
    await app.container.read(vaultControllerProvider.notifier).takeLoginRecords([
      LoginInboxRecord.generated(password: 'Xk9-news-generated', site: 'news.example', at: at),
      LoginInboxRecord.generated(password: 'Qz4-app-generated', at: at + 1),
    ]);
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    await tapOn(tester, find.text(t('vault.add.login')));
    await tapOn(tester, inEdit(find.text(t('generator.open'))));

    Finder inGenerator(Finder finder) => find.descendant(of: find.byType(GeneratorSheet), matching: finder);
    Finder row(String primary) => inGenerator(find.ancestor(of: find.text(primary), matching: find.byType(GroupRow)));
    // Newest first, with the day each was made; the passwords themselves stay hidden
    await tester.ensureVisible(inGenerator(find.text(t('generator.recent').toUpperCase())));
    expect(tester.getTopLeft(row(t('generator.recent.app'))).dy, lessThan(tester.getTopLeft(row('news.example')).dy));
    expect(
      find.descendant(of: row('news.example'), matching: find.text(t('generator.recent.at', {'date': 'November 19'}))),
      findsOneWidget,
    );
    expect(inGenerator(find.text('Xk9-news-generated')), findsNothing);

    await tapOn(tester, find.descendant(of: row('news.example'), matching: find.byTooltip(t('logins.copy.password'))));
    expect(copies, contains('Xk9-news-generated'));

    await tapOn(tester, find.descendant(of: row('news.example'), matching: find.text(t('generator.recent.save'))));
    final saved = logins(app).firstWhere((login) => login.name == 'news.example');
    expect(saved.password, 'Xk9-news-generated');
    expect(saved.websites, ['news.example']);
    expect(app.container.read(vaultControllerProvider).generated.map((item) => item.password), ['Qz4-app-generated']);
    expect(row('news.example'), findsNothing);
    expect(find.text(t('vault.snack.loginAdded', {'name': 'news.example'})), findsOneWidget);
  });
}
