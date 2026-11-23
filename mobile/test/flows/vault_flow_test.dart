import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

/// The flows of `e2e/vault.spec.ts`, through the whole app on a phone.
///
/// In the browser a reload kept the vault open, as the open session lived
/// in sessionStorage, and a new tab asked for the password. The phone app
/// keeps the open vault in its memory, as sessionStorage lived in the
/// WebView, so both are a restart here, and a restart asks for the password.
void main() {
  testWidgets('shows the right code for a new account and stores it only encrypted', (tester) async {
    final app = await startApp(tester, TestApp(now: () => rfcTime));
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', rfcSecret);

    expect(accountRow('GitHub'), findsOneWidget);
    expect(code(rfcCode), findsOneWidget);

    final stored = storedText(app);
    expect(stored, contains('backmycodes_vault_data'));
    expect(stored, isNot(contains(rfcSecret)));
    expect(stored, isNot(contains('GitHub')));
  });

  testWidgets('locks on demand and opens again with the right password only', (tester) async {
    await startApp(tester, TestApp());
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', rfcSecret);

    await tapOn(tester, find.byTooltip(t('app.tooltip.lockVault')));
    expect(passwordField, findsOneWidget);
    expect(accountRow('GitHub'), findsNothing);

    await submitPassword(tester, 'wrong password');
    await pumpUntil(tester, find.text(t('unlock.error.incorrectPassword')));
    expect(accountRow('GitHub'), findsNothing);

    await submitPassword(tester, masterPassword);
    await pumpUntil(tester, accountRow('GitHub'));
  });

  testWidgets('asks for the password when the app starts again, and opens with it', (tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', rfcSecret);

    await app.restart(tester);

    expect(find.text(t('lock.title.locked')), findsOneWidget);
    expect(passwordField, findsOneWidget);
    expect(accountRow('GitHub'), findsNothing);

    await submitPassword(tester, masterPassword);
    await pumpUntil(tester, accountRow('GitHub'));
  });
}
