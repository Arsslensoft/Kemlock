import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/import/credential_exchange.dart';

import '../fakes/fake_credential_exchange.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';

// Appendix A of the CXF 1.0 errata, as the fixtures folder's README says.
final _example = File('test/fixtures/import/cxf/fido-example.json').readAsStringSync();

void main() {
  testWidgets('an export that launched the app waits for the unlock, and is read only once the vault is open', (tester) async {
    final exchange = FakeIosCredentialExchange(opening: 'token-1', json: _example);
    final app = TestApp(exchange: exchange);
    await app.createVault('pw');
    await app.pump(tester);

    // The lock screen says that one waits, and nothing was asked of the system
    expect(find.text(t('import.transfer.lock.waiting')), findsOneWidget);
    expect(exchange.fetches, isEmpty);

    await app.unlock(tester, 'pw');

    expect(exchange.fetches, ['token-1']);
    expect(find.text(t('import.detected.transfer', {'app': 'Exporter app'})), findsOneWidget);
    expect(find.text(t('export.chip.logins', {'count': 1})), findsOneWidget);
    expect(app.state.logins, isEmpty, reason: 'nothing is saved until the person confirms');
  });

  testWidgets('a vault whose unlock is abandoned reads nothing, and the token is forgotten after ten minutes', (tester) async {
    final exchange = FakeIosCredentialExchange(opening: 'token-1', json: _example);
    final app = TestApp(exchange: exchange);
    await app.createVault('pw');
    await app.pump(tester);
    expect(find.text(t('import.transfer.lock.waiting')), findsOneWidget);

    await tester.pump(credentialExchangeLife + const Duration(seconds: 1));

    expect(find.text(t('import.transfer.lock.waiting')), findsNothing);
    expect(exchange.fetches, isEmpty);
    await app.unlock(tester, 'pw');
    expect(exchange.fetches, isEmpty);
    expect(find.text(t('import.title')), findsNothing);
  });

  testWidgets('"Not now" drops the token, and unlocking then opens the vault with nothing offered', (tester) async {
    final exchange = FakeIosCredentialExchange(opening: 'token-1', json: _example);
    final app = TestApp(exchange: exchange);
    await app.createVault('pw');
    await app.pump(tester);

    await tester.tap(find.text(t('import.transfer.lock.notNow')));
    await tester.pumpAndSettle();
    expect(find.text(t('import.transfer.lock.waiting')), findsNothing);
    await app.unlock(tester, 'pw');

    expect(exchange.fetches, isEmpty);
    expect(find.text(t('import.title')), findsNothing);
  });

  testWidgets('an export that arrives while the vault is open opens the import sheet at once', (tester) async {
    final exchange = FakeIosCredentialExchange(json: _example);
    final app = TestApp(exchange: exchange);
    await app.createVault('pw');
    await app.pump(tester);
    await app.unlock(tester, 'pw');
    expect(exchange.fetches, isEmpty);

    exchange.send('token-2');
    await tester.pumpAndSettle();

    expect(exchange.fetches, ['token-2']);
    expect(find.text(t('export.chip.logins', {'count': 1})), findsOneWidget);
  });
}
