import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/autofill.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../features/backup/backup_test_kit.dart';
import '../helpers/app_harness.dart';

typedef Json = Map<String, Object?>;

OtpAccount account(String id, {String issuer = 'GitHub', OtpType? type}) =>
    OtpAccount(id: id, type: type, issuer: issuer, label: 'alice@example.com', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

List<Object?> ids(Json? doc) => [for (final a in doc!['accounts']! as List<Object?>) (a! as Json)['id']];

void main() {
  late TestApp app;

  /// The main vault, with autofill as [prefs] set it, and two accounts, one HOTP.
  Future<void> setUp(WidgetTester tester, {String prefs = '{"autofill":true}'}) async {
    app = TestApp();
    final session = await app.createVault('pw');
    await app.vaultStore.saveAccounts([account('a1'), account('h1', issuer: 'Counter', type: OtpType.hotp)], session);
    app.store.setItem('backmycodes_prefs', prefs);
    // The directory gives the accounts their domains; the asset bundle can't load it in fake time.
    await app.pump(tester, overrides: [realDirectory]);
  }

  testWidgets('writes the open vault’s copy and index on unlock, without HOTP accounts', (tester) async {
    await setUp(tester);
    expect(app.autofill.calls, isEmpty, reason: 'nothing while locked');

    await app.unlock(tester, 'pw');

    expect(app.autofill.calls, ['write $mainVault']);
    expect(ids(app.autofill.copies[mainVault]), ['a1']);
    expect(app.autofill.indexes[mainVault], {
      'v': 1,
      'vault': mainVault,
      'accounts': [
        {
          'id': 'a1',
          'issuer': 'GitHub',
          'domains': ['github.com'],
        },
      ],
    });
  });

  testWidgets('writes no index when suggestions shouldn’t name the service', (tester) async {
    await setUp(tester, prefs: '{"autofill":true,"autofillNames":false}');
    await app.unlock(tester, 'pw');

    expect(ids(app.autofill.copies[mainVault]), ['a1']);
    expect(app.autofill.indexes[mainVault], isNull);
  });

  testWidgets('writes the copy again when the accounts change, and only then', (tester) async {
    await setUp(tester);
    await app.unlock(tester, 'pw');

    await app.controller.addAccount(account('a2', issuer: 'Google'));
    await tester.pumpAndSettle();
    final added = (app.autofill.copies[mainVault]!['accounts']! as List<Object?>).cast<Json>();
    expect([for (final a in added) a['issuer']], containsAll(['GitHub', 'Google']));

    final writes = app.autofill.calls.length;
    app.controller.biometricOffered();
    await tester.pumpAndSettle();
    expect(app.autofill.calls, hasLength(writes), reason: 'the same copy isn’t written twice');

    await app.controller.deleteAccount(app.state.accounts.firstWhere((a) => a.issuer == 'GitHub'));
    await tester.pumpAndSettle();
    expect([for (final a in app.autofill.copies[mainVault]!['accounts']! as List<Object?>) (a! as Json)['issuer']], ['Google']);
  });

  testWidgets('writes what sync merged, which bumps no revision', (tester) async {
    await setUp(tester);
    await app.unlock(tester, 'pw');

    await app.controller.applySynced(
      Lists(
        accounts: [
          account('a1'),
          account('s1', issuer: 'Steam', type: OtpType.steam),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(ids(app.autofill.copies[mainVault]), ['a1', 's1']);
  });

  testWidgets('removes the copy, and writes none, while autofill is off', (tester) async {
    await setUp(tester, prefs: '{}');
    await app.unlock(tester, 'pw');

    expect(app.autofill.calls, ['remove $mainVault']);
    expect(app.autofill.copies, isEmpty);
  });

  testWidgets('removes the copy when autofill is turned off, and writes it when turned back on', (tester) async {
    await setUp(tester);
    await app.unlock(tester, 'pw');

    app.store.setItem('backmycodes_prefs', '{}');
    await tester.pumpAndSettle();
    expect(app.autofill.calls.last, 'remove $mainVault');
    expect(app.autofill.copies, isEmpty);

    app.store.setItem('backmycodes_prefs', '{"autofill":true}');
    await tester.pumpAndSettle();
    expect(app.autofill.calls.last, 'write $mainVault');
  });

  testWidgets('never writes a hidden vault’s copy', (tester) async {
    await setUp(tester);
    final hidden = await app.vaultStore.createVault('Secret', 'pw2', listed: false);
    app.store.setItem(app.vaults.vaultKey('backmycodes_prefs', hidden), '{"autofill":true}');
    app = await app.restart(tester);

    await app.unlock(tester, 'pw2');

    expect(app.state.vault.id, hidden);
    expect(app.autofill.calls, ['remove $hidden']);
    expect(app.autofill.copies, isEmpty);
  });

  testWidgets('removes the copy of a vault that is deleted', (tester) async {
    await setUp(tester);
    await app.unlock(tester, 'pw');

    app.controller.deleteVault();
    await tester.pumpAndSettle();

    expect(app.autofill.calls.last, 'remove $mainVault');
    expect(app.autofill.copies, isEmpty);
  });

  testWidgets('removes every copy and the key when the lock screen wipes the phone’s vaults', (tester) async {
    await setUp(tester);
    await app.unlock(tester, 'pw');
    app.controller.lock();
    await tester.pumpAndSettle();

    app.vaultStore.wipeVault();
    app.controller.wiped();
    await tester.pumpAndSettle();

    expect(app.autofill.calls.last, 'removeAll');
    expect(app.autofill.copies, isEmpty);
  });

  // openspec: add-passwords, task 4.3
  group('logins', () {
    const github = Login(id: 'l1', name: 'GitHub', username: 'octocat', password: 'hunter2', websites: ['accounts.github.com'], addedAt: 1);

    /// The main vault with one GitHub account and [logins], open, with the settings [prefs].
    Future<void> openWith(WidgetTester tester, String prefs, {List<Login> logins = const [github]}) async {
      app = TestApp();
      final session = await app.createVault('pw');
      await app.vaultStore.saveAccounts([account('a1')], session);
      await app.vaultStore.saveLogins(logins, session);
      app.store.setItem('backmycodes_prefs', prefs);
      await app.pump(tester, overrides: [realDirectory]);
      await app.unlock(tester, 'pw');
    }

    testWidgets('puts the logins in the copy, and in the index without their passwords', (tester) async {
      await openWith(tester, '{"passwords":true}');

      expect(app.autofill.copies[mainVault]!['logins'], [
        {
          'id': 'l1',
          'name': 'GitHub',
          'username': 'octocat',
          'password': 'hunter2',
          'domains': ['github.com'],
        },
      ]);
      expect(app.autofill.indexes[mainVault]!['logins'], [
        {
          'id': 'l1',
          'name': 'GitHub',
          'username': 'octocat',
          'domains': ['github.com'],
        },
      ]);
      expect(jsonEncode(app.autofill.indexes[mainVault]), isNot(contains('hunter2')));
      // No inbox key yet: suggesting, but not saving
      expect(app.autofill.takes[mainVault], const VaultTakes(suggest: true));
    });

    testWidgets('lets the phone save logins once the vault has its inbox key', (tester) async {
      await openWith(tester, '{"passwords":true}');
      await tester.runAsync(() => app.controller.passkeyInbox(create: true));
      app.store.setItem('backmycodes_prefs', '{"passwords":true,"passwordSuggesting":false}');
      await tester.pumpAndSettle();

      expect(app.autofill.takes[mainVault], const VaultTakes(logins: true));
      expect(app.autofill.inboxKeys[mainVault], isNotNull);
    });

    testWidgets('gives an account the domains of the login linked to it', (tester) async {
      const linked = Login(id: 'l2', name: 'Git', password: 'p', websites: ['git.example.org'], accountId: 'a1', addedAt: 1);
      await openWith(tester, '{"autofill":true}', logins: [linked]);

      final accounts = (app.autofill.copies[mainVault]!['accounts']! as List<Object?>).cast<Json>();
      expect(accounts.single['domains'], ['github.com', 'example.org']);
      // Passwords are off: no login is in the copy
      expect(app.autofill.copies[mainVault]!.containsKey('logins'), isFalse);
    });

    testWidgets('takes the logins off the phone when passwords are turned off', (tester) async {
      await openWith(tester, '{"passwords":true,"autofill":true}');
      expect(app.autofill.copies[mainVault]!['logins'], hasLength(1));

      app.store.setItem('backmycodes_prefs', '{"autofill":true}');
      await tester.pumpAndSettle();
      expect(app.autofill.copies[mainVault]!.containsKey('logins'), isFalse);
      expect(app.autofill.indexes[mainVault]!.containsKey('logins'), isFalse);

      app.store.setItem('backmycodes_prefs', '{}');
      await tester.pumpAndSettle();
      expect(app.autofill.calls.last, 'remove $mainVault');
    });

    testWidgets('never writes a hidden vault’s logins', (tester) async {
      app = TestApp();
      await app.createVault('pw');
      final hidden = await app.vaultStore.createVault('Secret', 'pw2', listed: false);
      final session = await app.vaultStore.unlockAnyVault('pw2', hidden);
      await app.vaultStore.saveLogins(const [github], session);
      app.store.setItem(app.vaults.vaultKey('backmycodes_prefs', hidden), '{"passwords":true}');
      await app.pump(tester, overrides: [realDirectory]);
      await app.unlock(tester, 'pw2');

      expect(app.autofill.calls, ['remove $hidden']);
      expect(app.autofill.copies, isEmpty);
    });
  });
}
