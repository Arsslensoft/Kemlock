import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_setup_links.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';

const _link = 'otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub';

void main() {
  testWidgets('a set-up link the app was opened with waits for the unlock, then is added once confirmed', (tester) async {
    final app = TestApp(links: FakeSetupLinks(opening: _link));
    await app.createVault('pw');
    await app.pump(tester);
    expect(find.text(t('addAccount.add')), findsNothing, reason: 'nothing shows on the lock screen');

    await app.unlock(tester, 'pw');

    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('alice'), findsWidgets);
    expect(app.state.accounts, isEmpty, reason: 'nothing is added without the person');
    await tester.tap(find.widgetWithText(FilledButton, t('addAccount.add')));
    await tester.pumpAndSettle();

    expect(app.state.accounts.single.issuer, 'GitHub');
    expect(app.state.accounts.single.secret, 'JBSWY3DPEHPK3PXP');
  });

  testWidgets('a set-up link that arrives while the vault is open opens the sheet at once', (tester) async {
    final app = TestApp();
    await app.createVault('pw');
    await app.pump(tester);
    await app.unlock(tester, 'pw');

    app.links.send(_link);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, t('addAccount.add')), findsOneWidget);
  });

  testWidgets('a link that isn’t a set-up link is ignored', (tester) async {
    final app = TestApp(links: FakeSetupLinks(opening: 'https://example.com/otpauth://totp/x'));
    await app.createVault('pw');
    await app.pump(tester);
    await app.unlock(tester, 'pw');

    expect(find.widgetWithText(FilledButton, t('addAccount.add')), findsNothing);
  });

  testWidgets('a set-up link that holds no account says so', (tester) async {
    final app = TestApp(links: FakeSetupLinks(opening: 'otpauth://totp/Broken?issuer=Broken'));
    await app.createVault('pw');
    await app.pump(tester);
    await app.unlock(tester, 'pw');

    expect(find.text(t('addAccount.scan.error', {'raw': 'otpauth://totp/Broken?issuer=Broken'})), findsOneWidget);
    expect(app.state.accounts, isEmpty);
  });
}
