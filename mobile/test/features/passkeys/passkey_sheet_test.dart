import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/passkeys/passkey_sheet.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_clipboard.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

const _key = 'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgSECRETKEYMATERIAL';

const _github = Passkey(
  id: 'p1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  rpName: 'GitHub',
  userHandle: 'dXNlci0xMjM',
  userName: 'octocat@example.com',
  userDisplayName: 'Octo Cat',
  privateKey: _key,
  addedAt: 1763200000000,
);

void main() {
  Future<TestApp> openVaultTab(WidgetTester tester, {List<Passkey> passkeys = const [_github]}) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addPasskeys(passkeys);
    await tapOn(tester, tab('nav.vault'));
    return app;
  }

  List<Passkey> passkeys(TestApp app) => app.container.read(vaultControllerProvider).passkeys;

  testWidgets('lists a passkey by its site and account, and finds it by either', (tester) async {
    await openVaultTab(tester);
    final search = find.descendant(of: find.byType(SearchField), matching: find.byType(TextField));

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('github.com · octocat@example.com'), findsOneWidget);
    await tester.enterText(search, 'octocat');
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
    await tester.enterText(search, 'gitlab');
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsNothing);
  });

  testWidgets('shows the site, account and date, and nothing that reveals the key', (tester) async {
    final clipboard = <String>[];
    answerSensitiveCopies(clipboard.add);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add('${(call.arguments as Map)['text']}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await openVaultTab(tester);

    await tapOn(tester, find.text('GitHub'));

    final sheet = find.byType(PasskeySheet);
    expect(find.descendant(of: sheet, matching: find.text('GitHub · github.com')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('octocat@example.com')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Octo Cat')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text(t('passkeys.keyHidden'))), findsOneWidget);
    // No text anywhere holds any part of the key, and no control copies, shows or exports it
    expect(find.textContaining(_key.substring(20, 40)), findsNothing);
    for (final label in ['Copy', 'Show', 'Export', 'Reveal']) {
      expect(
        find.descendant(of: sheet, matching: find.textContaining(RegExp('\\b$label\\b'))),
        findsNothing,
        reason: label,
      );
    }
    for (final button in tester.widgetList<ButtonStyleButton>(find.descendant(of: sheet, matching: find.bySubtype<ButtonStyleButton>()))) {
      button.onPressed?.call();
    }
    await tester.pumpAndSettle();
    expect(clipboard, isEmpty);
  });

  testWidgets('saves a label, a note and tags', (tester) async {
    final app = await openVaultTab(tester);
    await tapOn(tester, find.text('GitHub'));

    await tester.enterText(find.widgetWithText(TextField, t('passkeys.label')), 'Work GitHub');
    await tester.enterText(find.widgetWithText(TextField, t('passkeys.note')), 'Made on the iPad');
    await tapOn(tester, find.widgetWithText(FilledButton, t('passkeys.save')));

    final passkey = passkeys(app).single;
    expect((passkey.label, passkey.note), ('Work GitHub', 'Made on the iPad'));
    expect(passkey.privateKey, _key);
    expect(find.text('Work GitHub'), findsOneWidget);
  });

  testWidgets('deleting warns first, and Undo restores the passkey', (tester) async {
    final app = await openVaultTab(tester);
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, find.text('GitHub'));

    await tapOn(tester, find.text(t('passkeys.delete')));
    expect(find.text(t('passkeys.delete.title')), findsOneWidget);
    expect(find.text(t('passkeys.delete.body', {'site': 'github.com'})), findsOneWidget);
    await tapOn(tester, find.descendant(of: find.byType(Dialog), matching: find.text(t('export.cancel'))));
    expect(passkeys(app), hasLength(1));

    await tapOn(tester, find.text(t('passkeys.delete')));
    await tapOn(tester, find.descendant(of: find.byType(Dialog), matching: find.text(t('passkeys.delete.confirm'))));
    expect(passkeys(app), isEmpty);
    expect(find.text(t('vault.snack.passkeyRemoved', {'name': 'GitHub'})), findsOneWidget);

    await tapOn(tester, find.text(t('app.undo')));
    expect(passkeys(app).single.credentialId, _github.credentialId);
    expect(passkeys(app).single.privateKey, _key);
  });
}
