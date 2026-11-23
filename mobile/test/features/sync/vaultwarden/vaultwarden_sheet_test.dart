// Setting Vaultwarden sync up from the sync sheet, and what the sheet shows
// and does once it's on, against the fake server.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_messages.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vaultwarden_sheet.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_formats.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/ui/ui.dart';

import '../../../fakes/fake_fido_key.dart';
import '../../../fakes/fake_ndef_applet.dart';
import '../../../fakes/fake_security_keys.dart';
import '../../../helpers/test_app.dart';
import '../../../security_key/hex.dart';
import '../../../vault/fast_kdf.dart';
import '../sync_screen_kit.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

List<Override> _overrides(FakeVaultwarden server, {String? untrusted, String? Function(String? pin)? refuse, Exception? failure}) => [
  vwClientFactoryProvider.overrideWithValue((pin) {
    final client = server.newClient();
    // A connection that fails before any answer, for another reason than a certificate
    if (failure != null) return MockClient((_) async => throw failure);
    if (refuse == null) return client;
    // A server whose certificate the phone doesn't trust, until it's pinned
    return _Refusing(client, refuse(pin));
  }),
  vwKeyDerivationProvider.overrideWithValue(const CheapKeyDerivation()),
  vwCertificateProbeProvider.overrideWithValue((_) async => untrusted),
];

Future<(SyncSheetKit, FakeVaultwarden)> _open(
  WidgetTester tester, {
  Future<void> Function(FakeVaultwarden server)? prepare,
  String? untrusted,
  String? Function(String? pin)? refuse,
  Exception? failure,
  SyncSettings? settings,
  FakeSecurityKeys? phone,
  DateTime Function()? clock,
}) async {
  final server = FakeVaultwarden();
  await server.allowSignIn();
  await prepare?.call(server);
  // Without a phone given, the phone reaches no security key
  final kit = SyncSheetKit(phone: phone);
  await kit.pump(
    tester,
    showSyncSheet,
    clock: clock,
    overrides: _overrides(server, untrusted: untrusted, refuse: refuse, failure: failure),
  );
  if (settings != null) {
    await kit.save(settings);
    await tester.pumpAndSettle();
  }
  await kit.open(tester);
  return (kit, server);
}

Future<void> _signIn(WidgetTester tester, {String password = 'master password'}) async {
  await tester.tap(find.text(t('sync.where.vaultwarden')));
  await tester.pumpAndSettle();
  await tester.enterText(field(t('vaultwarden.field.server')), 'https://vault.example.com');
  await tester.enterText(field(t('vaultwarden.field.email')), 'me@example.com');
  await tester.enterText(field(t('vaultwarden.field.password')), password);
  await tester.pump();
  await tapButton(tester, t('vaultwarden.signIn'));
}

Future<VwCredentials?> _stored(SyncSheetKit kit) async {
  final value = await kit.vaultStore.loadEncryptedValue(keyVaultwardenSession, kit.session);
  return value is Map<String, Object?> ? VwCredentials.fromJson(value) : null;
}

Future<List<String>> _names(FakeVaultwarden server) async => [
  for (final cipher in server.ciphers.values)
    if (cipher['deletedDate'] == null) await bwDecryptString(cipher['name']! as String, server.userKey),
];

void main() {
  testWidgets('turns sealed sync on with a new home', (tester) async {
    final (kit, server) = await _open(tester);
    await _signIn(tester);

    // Sealed is chosen first and recommended
    expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
    expect(find.text(t('vaultwarden.storage.recommended')), findsOneWidget);
    expect(find.text(t('vaultwarden.session')), findsOneWidget);
    await tapButton(tester, t('vaultwarden.continue'));

    expect(find.text(t('vaultwarden.home.new')), findsOneWidget);
    expect(button(tester, t('vaultwarden.continue')).onPressed, isNull);
    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));
    await tapButton(tester, t('vaultwarden.turnOn'));

    final target = kit.settings!.vaultwarden!;
    expect((target.mode, target.email, target.server), (VaultwardenMode.sealed, 'me@example.com', 'https://vault.example.com'));
    expect(target.seal, isNotNull);
    expect(kit.settings!.personal, isNull);
    expect(await _names(server), contains(homeNoteName));
    final credentials = await _stored(kit);
    expect(credentials?.userId, FakeVaultwarden.userId);
    expect(credentials!.toJson().toString(), isNot(contains('master password')));
    // The sheet now shows the sync
    expect(
      find.text(t('vaultwarden.on.body', {'host': 'vault.example.com', 'email': 'me@example.com', 'mode': t('vaultwarden.mode.sealed')})),
      findsOneWidget,
    );
  });

  testWidgets('says when the password is wrong', (tester) async {
    await _open(tester);
    await _signIn(tester, password: 'not it');

    expect(find.text(t('vaultwarden.problem.auth')), findsOneWidget);
    expect(find.text(t('vaultwarden.storage.title')), findsNothing);
  });

  testWidgets('asks for the second step, and takes the right code', (tester) async {
    final (kit, server) = await _open(tester, prepare: (server) async => server.twoFactor = {0, 1});
    await _signIn(tester);

    expect(find.text(t('vaultwarden.step.title')), findsOneWidget);
    // Email: send the code first
    await tester.tap(find.text(t('vaultwarden.step.email')));
    await tester.pumpAndSettle();
    await tapButton(tester, t('vaultwarden.step.send'));
    expect(server.emailsSent, 1);

    await tester.enterText(field(t('vaultwarden.step.code')), '000000');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));
    expect(find.text(t('vaultwarden.problem.code')), findsOneWidget);

    await tester.enterText(field(t('vaultwarden.step.code')), '123456');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));
    expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
    expect(kit.settings?.vaultwarden, isNull, reason: 'not on until a home is chosen');
  });

  testWidgets('says when the account only has a second step it cannot do', (tester) async {
    await _open(tester, prepare: (server) async => server.twoFactor = {VwTwoFactor.duo});
    await _signIn(tester);

    expect(find.text(t('vaultwarden.step.unsupported')), findsOneWidget);
    expect(t('vaultwarden.step.unsupported'), isNot(contains('security key')));
    expect(find.text(t('vaultwarden.step.code')), findsNothing);
    // The API key is the way in: one step back
    await tapButton(tester, t('vaultwarden.back'));
    await tapButton(tester, t('vaultwarden.apiKey.use'));
    expect(field(t('vaultwarden.field.clientId')), findsOneWidget);
  });

  testWidgets('needs the acknowledgement before plain storage', (tester) async {
    final (kit, _) = await _open(tester);
    await _signIn(tester);

    await tester.tap(find.text(t('vaultwarden.storage.plain')));
    await tester.pumpAndSettle();
    expect(button(tester, t('vaultwarden.continue')).onPressed, isNull);

    await tester.ensureVisible(find.text(t('vaultwarden.storage.plainAgree')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('vaultwarden.storage.plainAgree')));
    await tester.pumpAndSettle();
    await tapButton(tester, t('vaultwarden.continue'));
    await tapButton(tester, t('vaultwarden.continue'));
    await tapButton(tester, t('vaultwarden.turnOn'));

    expect(kit.settings!.vaultwarden!.mode, VaultwardenMode.plain);
    expect(kit.settings!.vaultwarden!.seal, isNull);
  });

  testWidgets('joins a sealed home only with its passphrase', (tester) async {
    late VaultwardenTarget existing;
    final (kit, _) = await _open(
      tester,
      prepare: (server) async {
        // Another phone made a home sealed with "the right phrase"
        final setup = VwAccountSetup(VwApi(server.newClient()), derive: const CheapKeyDerivation());
        await setup.connect('https://vault.example.com', server.email);
        final done = await setup.signIn(server.password, deviceId: 'other') as VwSignInDone;
        existing = await setup.createHome(
          setup.connection(done.credentials),
          mode: VaultwardenMode.sealed,
          passphrase: 'the right phrase',
          derive: fastKdf,
        );
      },
    );
    await _signIn(tester);
    await tapButton(tester, t('vaultwarden.continue'));

    expect(
      find.text(t('vaultwarden.home.existing', {'name': 'Kemlock', 'mode': t('vaultwarden.mode.sealed'), 'count': 0})),
      findsOneWidget,
    );
    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'the wrong phrase');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));
    expect(find.text(t('vaultwarden.error.passphrase')), findsOneWidget);
    expect(kit.settings?.vaultwarden, isNull);

    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'the right phrase');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));
    await tapButton(tester, t('vaultwarden.turnOn'));
    expect(kit.settings!.vaultwarden!.home, existing.home);
    expect(kit.settings!.vaultwarden!.seal!.key, existing.seal!.key);
  });

  testWidgets('trusts a self-signed certificate once its fingerprint is confirmed', (tester) async {
    const fingerprint = 'AB:CD:EF';
    final (kit, _) = await _open(tester, untrusted: fingerprint, refuse: (pin) => pin == fingerprint ? null : 'untrusted');
    await _signIn(tester);

    expect(find.text(t('vaultwarden.cert.title')), findsOneWidget);
    expect(find.text(t('vaultwarden.cert.warning')), findsOneWidget);
    expect(find.text(fingerprint), findsOneWidget);
    await tapButton(tester, t('vaultwarden.cert.trust'));
    await tapButton(tester, t('vaultwarden.continue'));
    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));
    await tapButton(tester, t('vaultwarden.turnOn'));

    expect(kit.settings!.vaultwarden!.pin, fingerprint);
  });

  testWidgets('offers no certificate to trust after a failure that was not over one', (tester) async {
    // The probe finds a certificate the phone doesn't trust, but the requests failed otherwise
    final (kit, _) = await _open(tester, untrusted: 'AB:CD:EF', failure: const SocketException('Connection reset by peer'));
    await _signIn(tester);

    expect(find.text(t('vaultwarden.cert.title')), findsNothing);
    expect(find.text(t('vaultwarden.problem.network')), findsOneWidget);
    expect(kit.settings?.vaultwarden, isNull);
  });

  testWidgets('says what the first sync will do, and writes nothing until turned on', (tester) async {
    late VaultwardenTarget existing;
    final (kit, server) = await _open(
      tester,
      prepare: (server) async {
        // Another phone keeps two accounts and a list of backup codes in a sealed home
        final setup = VwAccountSetup(VwApi(server.newClient()), derive: const CheapKeyDerivation());
        await setup.connect('https://vault.example.com', server.email);
        final done = await setup.signIn(server.password, deviceId: 'other') as VwSignInDone;
        final connection = setup.connection(done.credentials);
        existing = await setup.createHome(connection, mode: VaultwardenMode.sealed, passphrase: 'the right phrase', derive: fastKdf);
        await VaultwardenScopeSync(connection: connection, reader: VwReader(server.userKey), target: existing).sync(
          const Lists(
            accounts: [
              OtpAccount(id: 'a1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1),
              OtpAccount(id: 'a2', issuer: 'GitLab', label: 'octocat', secret: 'KRSXG5CTMVRXEZLU', addedAt: 1),
            ],
            backupServices: [
              BackupService(
                id: 's1',
                serviceName: 'GitHub',
                codes: [BackupCode(code: 'aaaa-1111')],
                addedAt: 1,
              ),
            ],
          ),
          const ScopeState(known: []),
          now: server.revision + 500,
        );
      },
    );
    await kit.vault.addAccounts([const OtpAccount(id: 'a3', issuer: 'Proton', label: 'me', secret: 'MFRGGZDFMZTWQ2LK', addedAt: 1)]);
    await _signIn(tester);
    await tapButton(tester, t('vaultwarden.continue'));
    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'the right phrase');
    await tester.pump();
    final before = (server.ciphers.length, server.revision);
    await tapButton(tester, t('vaultwarden.continue'));

    expect(find.text(t('vaultwarden.summary.title')), findsOneWidget);
    final accounts = t('vaultwarden.summary.accounts', {'count': 1});
    expect(find.text(t('vaultwarden.summary.to', {'what': accounts})), findsOneWidget);
    final from = t('vaultwarden.summary.and', {
      'first': t('vaultwarden.summary.accounts', {'count': 2}),
      'second': t('vaultwarden.summary.services', {'count': 1}),
    });
    expect(find.text(t('vaultwarden.summary.from', {'what': from})), findsOneWidget);
    expect(find.text(t('vaultwarden.summary.nothing')), findsNothing);
    expect((server.ciphers.length, server.revision), before, reason: 'nothing is written before Turn on');
    expect(kit.settings?.vaultwarden, isNull);

    // Back to the home, and on again
    await tapButton(tester, t('vaultwarden.back'));
    expect(find.text(t('vaultwarden.home.title')), findsOneWidget);
    await tapButton(tester, t('vaultwarden.continue'));
    await tapButton(tester, t('vaultwarden.turnOn'));
    expect(kit.settings!.vaultwarden!.home, existing.home);
  });

  testWidgets('says when the first sync has nothing to send or take', (tester) async {
    await _open(tester);
    await _signIn(tester);
    await tapButton(tester, t('vaultwarden.continue'));
    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
    await tester.pump();
    await tapButton(tester, t('vaultwarden.continue'));

    expect(find.text(t('vaultwarden.summary.nothing')), findsOneWidget);
    expect(find.text(t('vaultwarden.summary.hint')), findsOneWidget);
  });

  group('when on', () {
    Future<(SyncSheetKit, FakeVaultwarden, VaultwardenTarget)> on(WidgetTester tester, {List<OtpAccount> accounts = const []}) async {
      late VaultwardenTarget target;
      final (kit, server) = await _open(tester, prepare: (server) async => target = await makeHome(server, VaultwardenMode.sealed));
      await kit.vault.addAccounts(accounts);
      await _backendFor(kit, server).saveCredentials(server.credentials());
      await kit.save(SyncSettings(vaultwarden: target));
      await tester.pumpAndSettle();
      return (kit, server, target);
    }

    // openspec: add-passwords, task 7.4
    testWidgets('says how many logins it leaves on this phone', (tester) async {
      final (kit, _, _) = await on(tester);
      expect(find.textContaining(t('vaultwarden.logins.stay', {'count': 1}).split(':').first), findsNothing, reason: 'no login yet');

      for (final (i, name) in ['Larkspur Mail', 'Bank'].indexed) {
        await kit.vault.addLogin(Login(id: 'l$i', name: name, password: 'p$i', addedAt: 0));
      }
      await tester.pumpAndSettle();

      expect(find.text(t('vaultwarden.logins.stay', {'count': 2})), findsOneWidget);
    });

    // the add-cards-identities-and-websites plan, task 3.6
    testWidgets('says how many cards and identities it leaves on this phone', (tester) async {
      final (kit, _, _) = await on(tester);
      expect(find.text(t('vaultwarden.cards.stay', {'count': 2})), findsNothing, reason: 'no card yet');
      expect(find.text(t('vaultwarden.identities.stay', {'count': 1})), findsNothing, reason: 'no identity yet');

      for (final (i, name) in ['Everyday Visa', 'Gift card'].indexed) {
        await kit.vault.addCard(PaymentCard(id: 'c$i', name: name, cardholder: 'Ada', addedAt: 0));
      }
      await kit.vault.addIdentity(const Identity(id: 'i1', name: 'Me', email: 'ada@example.org', addedAt: 0));
      await tester.pumpAndSettle();

      expect(find.text(t('vaultwarden.cards.stay', {'count': 2})), findsOneWidget);
      expect(find.text(t('vaultwarden.identities.stay', {'count': 1})), findsOneWidget);
    });

    testWidgets('asks before many removals, and passes the answer on', (tester) async {
      final (kit, _, _) = await on(tester);
      kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.removals, count: 7));
      await tester.pumpAndSettle();

      expect(find.text(t('vaultwarden.removals.body', {'count': 7})), findsOneWidget);
      await tapButton(tester, t('vaultwarden.removals.keep'));
      expect(kit.sync.removalChoice, RemovalChoice.keep);
    });

    testWidgets('signs in again when the session ended', (tester) async {
      final (kit, _, _) = await on(tester);
      kit.vaultStore.removeEncryptedValue(keyVaultwardenSession);
      kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.signedOut));
      await tester.pumpAndSettle();

      await tapButton(tester, t('vaultwarden.signInAgain'));
      await tester.enterText(field(t('vaultwarden.field.password')), 'master password');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.signIn'));

      expect((await _stored(kit))?.userId, FakeVaultwarden.userId);
      expect(find.text(t('vaultwarden.signInAgain')), findsOneWidget, reason: 'back on the sheet, until the next sync');
    });

    testWidgets('turns off and keeps everything in Vaultwarden', (tester) async {
      final (kit, server, _) = await on(tester);
      final before = server.ciphers.length;

      await tapButton(tester, t('sync.off'));
      await tapButton(tester, t('vaultwarden.off.keep'));

      expect(kit.settings!.vaultwarden, isNull);
      expect(await _stored(kit), isNull);
      expect(server.ciphers.length, before);
      expect(server.ciphers.values.where((c) => c['deletedDate'] != null), isEmpty);
    });

    testWidgets('turns off and takes Kemlock out of Vaultwarden', (tester) async {
      final (kit, server, _) = await on(tester);

      await tapButton(tester, t('sync.off'));
      await tapButton(tester, t('vaultwarden.off.remove'));

      expect(kit.settings!.vaultwarden, isNull);
      expect(await _names(server), isNot(contains(homeNoteName)));
    });

    testWidgets('changes to plain storage after the acknowledgement', (tester) async {
      final (kit, server, target) = await on(tester);

      await tapButton(tester, t('vaultwarden.change'));
      expect(button(tester, t('vaultwarden.change.confirm')).onPressed, isNull);
      await tester.tap(find.text(t('vaultwarden.storage.plainAgree')));
      await tester.pumpAndSettle();
      await tapButton(tester, t('vaultwarden.change.confirm'));

      expect(kit.settings!.vaultwarden!.mode, VaultwardenMode.plain);
      final read = await VwReader(server.userKey).read([for (final cipher in server.ciphers.values) VwCipher(cipher)]);
      expect(read.homes.single.home.mode, VaultwardenMode.plain);
      expect(read.homes.single.home.id, target.home);
    });
  });

  group('keys, notes and passkeys', () {
    const account = OtpAccount(id: 'a1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
    const key = VaultKey(
      id: 'k1',
      name: 'laptop',
      kind: KeyKind.signing,
      algorithm: '1.2.3.4',
      privateKey: 'MAA=',
      origin: KeyOrigin.imported,
      addedAt: 1,
    );
    const note = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 1);

    testWidgets('the first sync counts each kind it sends', (tester) async {
      final (kit, _) = await _open(tester);
      await kit.vault.addAccounts([account]);
      await kit.vault.addKey(key);
      await kit.vault.addNote(note);
      await _signIn(tester);
      await tapButton(tester, t('vaultwarden.continue'));
      await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.continue'));

      final what = t('vaultwarden.summary.list', {
        'items': '${t('vaultwarden.summary.accounts', {'count': 1})}, ${t('vaultwarden.summary.keys', {'count': 1})}',
        'last': t('vaultwarden.summary.notes', {'count': 1}),
      });
      expect(find.text(t('vaultwarden.summary.to', {'what': what})), findsOneWidget);
      expect(
        find.textContaining(t('vaultwarden.consent.waiting', {'what': ''}).split(':').first),
        findsNothing,
        reason: 'sealed asks nothing',
      );
    });

    for (final agree in [true, false]) {
      testWidgets('plain setup says who reads keys and notes, and ${agree ? 'keeps the agreement' : 'writes none without it'}', (
        tester,
      ) async {
        final (kit, server) = await _open(tester);
        await kit.vault.addAccounts([account]);
        await kit.vault.addKey(key);
        await kit.vault.addNote(note);
        await _signIn(tester);
        await tester.tap(find.text(t('vaultwarden.storage.plain')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(t('vaultwarden.storage.plainAgree')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t('vaultwarden.storage.plainAgree')));
        await tester.pumpAndSettle();
        await tapButton(tester, t('vaultwarden.continue'));
        await tapButton(tester, t('vaultwarden.continue'));

        final waiting = t('vaultwarden.consent.waiting', {
          'what': t('vaultwarden.summary.and', {
            'first': t('vaultwarden.summary.keys', {'count': 1}),
            'second': t('vaultwarden.summary.notes', {'count': 1}),
          }),
        });
        expect(find.textContaining(waiting), findsOneWidget);
        expect(find.textContaining(t('vaultwarden.consent.body', {'email': 'me@example.com'})), findsOneWidget);
        expect(
          find.text(
            t('vaultwarden.summary.to', {
              'what': t('vaultwarden.summary.accounts', {'count': 1}),
            }),
          ),
          findsOneWidget,
        );
        if (agree) {
          await tester.ensureVisible(find.text(t('vaultwarden.consent.setup')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(t('vaultwarden.consent.setup')));
          await tester.pumpAndSettle();
        }
        await tapButton(tester, t('vaultwarden.turnOn'));

        expect(kit.settings!.vaultwarden!.plainKinds, agree ? {'key', 'note'} : isEmpty);
        expect(server.ciphers.length, 1, reason: 'only the home: nothing is written before sync runs');
      });
    }

    group('when on', () {
      Future<SyncSheetKit> on(WidgetTester tester, Map<String, Object?> state, {VaultwardenMode mode = VaultwardenMode.plain}) async {
        late VaultwardenTarget target;
        final (kit, server) = await _open(tester, prepare: (server) async => target = await makeHome(server, mode));
        await kit.vault.addNote(note);
        await _backendFor(kit, server).saveCredentials(server.credentials());
        await kit.save(SyncSettings(vaultwarden: target));
        await kit.sync.saveScopeStates({vaultwardenScope: ScopeState(known: const [], lastSyncAt: 1, extra: state)}, kit.session);
        kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(lastSyncAt: 1));
        await tester.pumpAndSettle();
        return kit;
      }

      testWidgets('says what waits to be written plain, and agreeing keeps it and syncs', (tester) async {
        final kit = await on(tester, {
          'paused': {'key': 2, 'passkey': 1},
        });
        var requested = 0;
        kit.sync.onSyncRequest(() => requested++);

        final waiting = t('vaultwarden.consent.waiting', {
          'what': t('vaultwarden.summary.and', {
            'first': t('vaultwarden.summary.keys', {'count': 2}),
            'second': t('vaultwarden.summary.passkeys', {'count': 1}),
          }),
        });
        expect(find.textContaining(waiting), findsOneWidget);
        await tapButton(tester, t('vaultwarden.consent.agree'));

        expect(kit.settings!.vaultwarden!.plainKinds, {'key', 'passkey'});
        expect(requested, greaterThan(0));
        expect(find.textContaining(waiting), findsNothing);
      });

      testWidgets('names what is too long, and says files are not kept there', (tester) async {
        await on(tester, {
          'tooLong': ['n1'],
          'noFiles': 'none',
        });

        expect(find.text(t('vaultwarden.tooLong', {'names': 'Passport'})), findsOneWidget);
        expect(find.text(t('vaultwarden.noFiles.none')), findsOneWidget);
      });

      testWidgets('says when files are kept on another host', (tester) async {
        await on(tester, {'noFiles': 'elsewhere'}, mode: VaultwardenMode.sealed);

        expect(find.text(t('vaultwarden.noFiles.elsewhere')), findsOneWidget);
        expect(find.text(t('vaultwarden.consent.agree')), findsNothing);
      });
    });
  });
  // openspec: add-offline-mode, "Sync is paused" and "Setting up a server waits"
  group('while offline mode is on', () {
    testWidgets('setup says so and offers no step that would contact the server', (tester) async {
      final (kit, server) = await _open(tester);
      await tester.tap(find.text(t('sync.where.vaultwarden')));
      await tester.pumpAndSettle();
      await tester.enterText(field(t('vaultwarden.field.server')), 'https://vault.example.com');
      await kit.setOffline(tester, true);

      expect(offlineAlert(t('sync.offline.setup')), findsOneWidget);
      expect(button(tester, t('vaultwarden.signIn')).onPressed, isNull);
      expect(field(t('vaultwarden.field.server')), findsNothing);
      expect(server.requests, isEmpty);

      await tapButton(tester, t('offline.settings'));
      expect(find.byType(SyncSheet), findsNothing);
    });

    testWidgets('a vault that syncs says sync is paused, keeps the last sync on show and cannot sync now', (tester) async {
      late VaultwardenTarget target;
      final (kit, server) = await _open(tester, prepare: (server) async => target = await makeHome(server, VaultwardenMode.sealed));
      await _backendFor(kit, server).saveCredentials(server.credentials());
      await kit.save(SyncSettings(vaultwarden: target));
      kit.sync.setScopeStatus(vaultwardenScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.setOffline(tester, true);
      server.requests.clear();

      expect(offlineAlert(t('sync.offline')), findsOneWidget);
      final when = syncTime(tester.element(find.byType(SyncSheet)), testNow.millisecondsSinceEpoch);
      expect(find.text(t('sync.status.synced', {'when': when})), findsOneWidget);
      expect(button(tester, t('sync.now')).onPressed, isNull);
      expect(button(tester, t('sync.off')).onPressed, isNull, reason: 'turning it off offers to take Kemlock out of the server');
      expect(button(tester, t('vaultwarden.change')).onPressed, isNull);
      expect(kit.container.read(syncProvider).status[vaultwardenScope]?.problem, isNull);
      expect(server.requests, isEmpty);
    });

    testWidgets('a sync that stopped offers nothing to decide until offline mode is off', (tester) async {
      late VaultwardenTarget target;
      final (kit, server) = await _open(tester, prepare: (server) async => target = await makeHome(server, VaultwardenMode.sealed));
      await _backendFor(kit, server).saveCredentials(server.credentials());
      await kit.save(SyncSettings(vaultwarden: target));
      kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.signedOut));
      await kit.setOffline(tester, true);

      expect(find.text(t('vaultwarden.signInAgain')), findsNothing);

      await kit.setOffline(tester, false);
      expect(find.text(t('vaultwarden.signInAgain')), findsOneWidget);
    });
  });

  group('with a security key as the second step', () {
    testWidgets('a key-only account signs in with the key and reaches the storage step', (tester) async {
      final key = _Key();
      final (kit, server) = await key.open(tester);
      await _signIn(tester);

      // The key step, not the warning, and no code field
      expect(find.text(t('vaultwarden.step.unsupported')), findsNothing);
      expect(find.text(t('vaultwarden.key.noReach')), findsNothing);
      expect(field(t('vaultwarden.step.code')), findsNothing);
      expect(find.text(t('vaultwarden.key.hold.android')), findsOneWidget);
      expect(find.text(t('vaultwarden.step.remember')), findsOneWidget);
      expect(find.text(t('vaultwarden.continue')), findsNothing);

      key.present();
      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(server.webauthnRefusal, isNull);
      expect(_steps(server).single['twoFactorProvider'], '7');
      expect(kit.settings?.vaultwarden, isNull, reason: 'not on until a home is chosen');
      expect(key.phone.openLinks, isEmpty);
      expect(key.phone.isWatching, isFalse);
    });

    testWidgets('tells an iPhone user where to hold the key, and reads it under the NFC sheet', (tester) async {
      final key = _Key(phone: FakeSecurityKeys.iphone);
      await key.open(tester);
      await _signIn(tester);

      expect(find.text(t('vaultwarden.key.hold.ios')), findsOneWidget);
      key.present();
      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(key.phone.calls, contains('beginNfc ${t('vaultwarden.key.hold.ios')}'));
      expect(key.phone.nfcSheetUp, isFalse);
    });

    testWidgets('an account with an authenticator app and a key opens on the code, and either signs in', (tester) async {
      final key = _Key();
      await key.open(tester, also: {VwTwoFactor.authenticator});
      await _signIn(tester);

      // The code first, as before
      expect(field(t('vaultwarden.step.code')), findsOneWidget);
      expect(find.text(t('vaultwarden.step.securityKey')), findsOneWidget);
      await tester.enterText(field(t('vaultwarden.step.code')), '123456');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.continue'));
      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
    });

    testWidgets('an account with an authenticator app and a key signs in with the key when it is chosen', (tester) async {
      final key = _Key();
      final (_, server) = await key.open(tester, also: {VwTwoFactor.authenticator});
      await _signIn(tester);

      await tester.tap(find.text(t('vaultwarden.step.securityKey')));
      await tester.pumpAndSettle();
      expect(field(t('vaultwarden.step.code')), findsNothing);
      key.present();
      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(_steps(server).single['twoFactorProvider'], '7');
    });

    testWidgets('cancelling while the app waits for the key sends nothing', (tester) async {
      final key = _Key();
      final (_, server) = await key.open(tester);
      await _signIn(tester);

      await tester.tap(buttonWithText(t('vaultwarden.key.use')));
      await tester.pump();
      await tester.pump();
      expect(find.text(t('vaultwarden.key.status.waiting')), findsOneWidget);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNull);

      await tester.tap(find.byKey(vwKeyCancelKey));
      await tester.pumpAndSettle();

      expect(_steps(server), isEmpty);
      expect(find.text(t('vaultwarden.step.title')), findsOneWidget);
      expect(find.text(t('vaultwarden.key.status.waiting')), findsNothing);
      expect(find.byType(AppAlert), findsNothing, reason: 'a cancellation is not an error');
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);
      expect(key.phone.isWatching, isFalse);
    });

    testWidgets('closing the iPhone NFC sheet sends nothing', (tester) async {
      final key = _Key(phone: FakeSecurityKeys.iphone);
      final (_, server) = await key.open(tester);
      await _signIn(tester);

      key.phone.cancelNextNfcSheet = true;
      await tapButton(tester, t('vaultwarden.key.use'));

      expect(_steps(server), isEmpty);
      expect(find.byType(AppAlert), findsNothing);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);
    });

    testWidgets('says a key that is not registered is not, and takes another', (tester) async {
      final key = _Key();
      final (_, server) = await key.open(tester, also: {VwTwoFactor.authenticator});
      await _signIn(tester);
      await tester.tap(find.text(t('vaultwarden.step.securityKey')));
      await tester.pumpAndSettle();
      final stranger = FakeKey(ctap: FakeFidoKey()..maxCredentialCountInList = 8).device(kinds: {SecurityKeyLinkKind.nfc});
      key.phone.arrive(stranger);

      await tapButton(tester, t('vaultwarden.key.use'));

      // The fake server's challenge carries the U2F-era address, as the real one's does
      expect(find.text(t('vaultwarden.key.registeredOldWay')), findsOneWidget);
      expect(_steps(server), isEmpty, reason: 'nothing is sent to the server');
      expect(find.text(t('vaultwarden.step.authenticator')), findsOneWidget, reason: 'the methods are still offered');
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);

      // The right key next, with a challenge fetched for it
      key.phone.remove(stranger);
      key.present();
      await tapButton(tester, t('vaultwarden.key.use'));
      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(server.webauthnChallengesGiven, 2);
    });

    testWidgets('explains a server set up under another address, and offers to use it', (tester) async {
      final key = _Key(domain: 'https://vault.example.org');
      final (_, server) = await key.open(tester);
      await _signIn(tester);
      key.present();

      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.key.otherAddress', {'host': 'vault.example.org'})), findsOneWidget);
      expect(key.fido.requests, isEmpty, reason: 'the key is never asked');
      expect(_steps(server), isEmpty);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);

      await tapButton(tester, t('vaultwarden.key.useAddress'));

      expect(find.text(t('vaultwarden.signIn')), findsOneWidget);
      expect(tester.widget<TextField>(field(t('vaultwarden.field.server'))).controller!.text, 'https://vault.example.org');
      expect(find.byType(AppAlert), findsNothing);
    });

    testWidgets('says a U2F-only key cannot be used', (tester) async {
      final key = _Key();
      final (_, server) = await key.open(tester);
      await _signIn(tester);
      key.phone.arrive(FakeKey(productName: 'Old Key').device(kinds: {SecurityKeyLinkKind.nfc}));

      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.key.notFido2')), findsOneWidget);
      expect(_steps(server), isEmpty);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);
    });

    testWidgets('says an iPhone reaches a key for sign-in over NFC only', (tester) async {
      final key = _Key(phone: FakeSecurityKeys.iphone);
      await key.open(tester);
      await _signIn(tester);
      key.present(kinds: {SecurityKeyLinkKind.smartcard});

      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.key.iphoneNfcOnly')), findsOneWidget);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);
    });

    testWidgets('says the server refused the answer, and a new try fetches a new challenge without the password', (tester) async {
      // The server is set up under a port the address typed does not have
      final key = _Key(domain: 'https://vault.example.com:8443');
      final (_, server) = await key.open(tester);
      await _signIn(tester);
      key.present();

      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.key.refused', {'host': 'vault.example.com'})), findsOneWidget);
      expect(find.text(t('vaultwarden.key.useAddress')), findsNothing, reason: 'the name is the one typed: only the port differs');
      expect(server.webauthnRefusal, 'another origin');
      expect(find.text(t('vaultwarden.step.title')), findsOneWidget);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);

      // The server is put right; the same screen tries again
      server.domain = 'https://vault.example.com';
      final before = server.requests.length;
      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      final sent = server.requests.sublist(before).where((request) => request.url.path == '/identity/connect/token').toList();
      expect([for (final request in sent) Uri.splitQueryString(request.body)['twoFactorProvider']], [null, '7']);
      expect(server.requests.sublist(before).where((request) => request.url.path.contains('prelogin')), isEmpty);
      expect(server.webauthnChallengesGiven, 2);
    });

    testWidgets('says the key was taken away', (tester) async {
      final key = _Key();
      final (_, server) = await key.open(tester);
      await _signIn(tester);
      key.present();
      key.phone.removeWhen = (frame) => frame.length > 60 && frame[0] == 0x80 && frame[1] == 0x10;

      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('securityKeys.error.removed')), findsOneWidget);
      expect(_steps(server), isEmpty);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);
    });

    testWidgets('asks a slow person\'s key with a challenge fetched just before', (tester) async {
      var now = DateTime.utc(2026, 11, 16, 9);
      final key = _Key();
      final (_, server) = await key.open(tester, clock: () => now);
      await _signIn(tester);
      final first = server.webauthnChallenge;

      now = now.add(const Duration(minutes: 2));
      key.present();
      await tapButton(tester, t('vaultwarden.key.use'));

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(server.webauthnChallengesGiven, 2);
      final clientData = utf8.decode(
        unb64url(
          ((jsonDecode(_steps(server).single['twoFactorToken']!) as Map<String, Object?>)['response']!
                  as Map<String, Object?>)['clientDataJson']!
              as String,
        ),
      );
      expect(clientData, isNot(contains(first!)));
      expect(clientData, contains('"origin":"https://vault.example.com"'));
    });

    testWidgets('asks for the PIN of a key that demands it, and signs in after the right one', (tester) async {
      final key = _Key(pin: '123456', alwaysUv: true);
      final (_, server) = await key.open(tester);
      await _signIn(tester);
      key.present();

      await _tapWhileBusy(tester, t('vaultwarden.key.use'));

      expect(find.text(t('securityKeys.pin.prompt.title')), findsOneWidget);
      expect(find.text(t('vaultwarden.key.pin')), findsOneWidget);
      expect(_steps(server), isEmpty);
      await tester.enterText(field(t('securityKeys.pin.field')), '123456');
      await tester.pump();
      await _tapWhileBusy(tester, t('securityKeys.pin.continue'));
      await tester.pumpAndSettle();

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(server.webauthnRefusal, isNull);
      expect(key.fido.retries, 8);
    });

    testWidgets('says a wrong PIN with the tries left, and sends nothing to the server', (tester) async {
      final key = _Key(pin: '123456', alwaysUv: true);
      final (_, server) = await key.open(tester);
      await _signIn(tester);
      key.present();

      await _tapWhileBusy(tester, t('vaultwarden.key.use'));
      await tester.enterText(field(t('securityKeys.pin.field')), '000000');
      await tester.pump();
      await _tapWhileBusy(tester, t('securityKeys.pin.continue'));

      expect(find.textContaining(t('securityKeys.pin.wrong')), findsOneWidget);
      expect(find.textContaining(t('securityKeys.pin.triesLeft', {'count': 7})), findsOneWidget);
      expect(_steps(server), isEmpty);
      expect(key.assertions, 1, reason: 'only the first request, which carried no PIN');

      // Backing out of the prompt leaves the two-step screen as it was
      Navigator.of(tester.element(find.text(t('securityKeys.pin.prompt.title')))).pop();
      await tester.pumpAndSettle();
      expect(_steps(server), isEmpty);
      expect(find.text(t('vaultwarden.step.title')), findsOneWidget);
      expect(button(tester, t('vaultwarden.key.use')).onPressed, isNotNull);
    });

    testWidgets('says the phone can reach no key, and offers the API key', (tester) async {
      // No phone is given: the build has no way to a key, as a phone with no NFC and no USB hosting
      final (_, server) = await _open(tester, prepare: (server) async => server.registerKey(List.filled(32, 0x51), newP256KeyPair().point));
      await _signIn(tester);

      expect(find.text(t('vaultwarden.key.noReach')), findsOneWidget);
      expect(find.text(t('vaultwarden.step.unsupported')), findsNothing);
      expect(find.text(t('vaultwarden.key.use')), findsNothing);
      expect(field(t('vaultwarden.step.code')), findsNothing);
      expect(server.webauthnChallengesGiven, 1);
      await tapButton(tester, t('vaultwarden.back'));
      await tapButton(tester, t('vaultwarden.apiKey.use'));
      expect(field(t('vaultwarden.field.clientId')), findsOneWidget);
    });

    testWidgets('says the same on an iPad, which has a port and no NFC', (tester) async {
      final key = _Key(phone: FakeSecurityKeys.ipad);
      await key.open(tester);
      await _signIn(tester);

      expect(find.text(t('vaultwarden.key.noReach')), findsOneWidget);
      expect(find.text(t('vaultwarden.key.use')), findsNothing);
    });

    testWidgets('says the server is not set up for security keys when it gave no challenge', (tester) async {
      final key = _Key();
      await key.open(tester, prepare: (server) => server.webauthnChallenges = false);
      await _signIn(tester);

      expect(find.text(t('vaultwarden.key.noChallenge')), findsOneWidget);
      expect(find.text(t('vaultwarden.step.unsupported')), findsNothing);
      expect(find.text(t('vaultwarden.key.use')), findsNothing);
    });

    testWidgets('says the same of a server that has no address of its own', (tester) async {
      final key = _Key(domain: null);
      await key.open(tester);
      await _signIn(tester);

      expect(find.text(t('vaultwarden.key.noChallenge')), findsOneWidget);
      expect(find.text(t('vaultwarden.key.use')), findsNothing);
    });

    testWidgets('keeps the other methods when the key cannot be used, and says why', (tester) async {
      final key = _Key(phone: FakeSecurityKeys.ipad);
      await key.open(tester, also: {VwTwoFactor.authenticator});
      await _signIn(tester);

      expect(field(t('vaultwarden.step.code')), findsOneWidget);
      expect(find.text(t('vaultwarden.step.securityKey')), findsNothing);
      expect(find.text(t('vaultwarden.key.noReach')), findsOneWidget);
      await tester.enterText(field(t('vaultwarden.step.code')), '123456');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.continue'));
      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
    });

    /// Turns sync on with the key, then has the session end.
    Future<(SyncSheetKit, FakeVaultwarden)> turnedOn(WidgetTester tester, _Key key, {required bool remember}) async {
      final (kit, server) = await key.open(tester);
      await _signIn(tester);
      if (!remember) {
        await tester.tap(find.text(t('vaultwarden.step.remember')));
        await tester.pumpAndSettle();
      }
      key.present();
      await tapButton(tester, t('vaultwarden.key.use'));
      await tapButton(tester, t('vaultwarden.continue'));
      await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.continue'));
      await tapButton(tester, t('vaultwarden.turnOn'));
      expect(kit.settings!.vaultwarden, isNotNull);
      kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.signedOut));
      await tester.pumpAndSettle();
      return (kit, server);
    }

    Future<void> signInAgain(WidgetTester tester) async {
      await tapButton(tester, t('vaultwarden.signInAgain'));
      await tester.enterText(field(t('vaultwarden.field.password')), 'master password');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.signIn'));
    }

    testWidgets('remembers the device after a key, so the next sign-in asks for none', (tester) async {
      final key = _Key();
      final (kit, server) = await turnedOn(tester, key, remember: true);
      expect((await _stored(kit))!.rememberToken, isNotNull);
      final assertions = key.assertions;

      await signInAgain(tester);

      expect(find.text(t('vaultwarden.step.title')), findsNothing);
      expect(find.text(t('vaultwarden.signInAgain')), findsOneWidget, reason: 'back on the sheet, until the next sync');
      expect(Uri.splitQueryString(server.requests.last.body)['twoFactorProvider'], '5');
      expect(key.assertions, assertions, reason: 'the key was not asked again');
    });

    testWidgets('asks for the key again when the device was not to be remembered', (tester) async {
      final key = _Key();
      final (kit, _) = await turnedOn(tester, key, remember: false);
      expect((await _stored(kit))!.rememberToken, isNull);

      await signInAgain(tester);

      expect(find.text(t('vaultwarden.step.title')), findsOneWidget);
      expect(find.text(t('vaultwarden.key.use')), findsOneWidget);
    });

    testWidgets('signs in again with the key when the session ended, and changes nothing in the vault', (tester) async {
      final key = _Key();
      final (kit, server) = await turnedOn(tester, key, remember: false);
      await kit.vault.addAccounts([const OtpAccount(id: 'a1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1)]);
      await tester.pumpAndSettle();
      List<List<Object>> lists() {
        final lists = kit.vaultState.lists;
        return [lists.accounts, lists.backupServices, lists.keys, lists.notes, lists.passkeys];
      }

      final before = lists();
      final target = kit.settings!.vaultwarden;
      kit.vaultStore.removeEncryptedValue(keyVaultwardenSession);
      var syncsAsked = 0;
      final stop = kit.sync.onSyncRequest(() => syncsAsked++);
      addTearDown(stop);

      await tapButton(tester, t('vaultwarden.signInAgain'));
      // The server's address is the target's, and cannot be changed here
      expect(tester.widget<TextField>(field(t('vaultwarden.field.server'))).enabled, isFalse);
      await tester.enterText(field(t('vaultwarden.field.password')), 'master password');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.signIn'));
      expect(find.text(t('vaultwarden.key.use')), findsOneWidget);
      await tapButton(tester, t('vaultwarden.key.use'));

      final stored = await _stored(kit);
      expect(stored?.userId, FakeVaultwarden.userId);
      expect(stored!.accessToken, isNotEmpty);
      expect(server.webauthnRefusal, isNull);
      expect(syncsAsked, 1);
      expect(find.text(t('vaultwarden.signInAgain')), findsOneWidget, reason: 'back on the sheet, until the next sync');
      expect(lists(), before);
      expect(before.first, hasLength(1));
      expect(kit.settings!.vaultwarden, target);
    });

    testWidgets('stores after a sign-in by key only what a sign-in by code stores', (tester) async {
      Future<(Set<String>, Set<String>, String)> signedIn(WidgetTester tester, {required bool byKey}) async {
        final key = _Key();
        final (kit, server) = await key.open(tester, also: byKey ? const {} : {VwTwoFactor.authenticator});
        await _signIn(tester);
        if (byKey) {
          key.present();
          await tapButton(tester, t('vaultwarden.key.use'));
        } else {
          await tester.enterText(field(t('vaultwarden.step.code')), '123456');
          await tester.pump();
          await tapButton(tester, t('vaultwarden.continue'));
        }
        await tapButton(tester, t('vaultwarden.continue'));
        await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
        await tester.pump();
        await tapButton(tester, t('vaultwarden.continue'));
        await tapButton(tester, t('vaultwarden.turnOn'));
        final credentials = (await _stored(kit))!.toJson();
        // Everything the phone keeps: the store as it is, and each encrypted value opened
        final opened = StringBuffer(jsonEncode({for (final name in kit.kv.storedKeys()) name: kit.kv.getItem(name)}));
        for (final name in [keyVaultwardenSession, keyVaultwardenCache]) {
          opened.write(jsonEncode(await kit.vaultStore.loadEncryptedValue(name, kit.session)));
        }
        opened.write(jsonEncode(kit.settings!.toJson()));
        if (byKey) {
          final token = _steps(server).single['twoFactorToken']!;
          final response = (jsonDecode(token) as Map<String, Object?>)['response']! as Map<String, Object?>;
          for (final secret in [
            token,
            response['signature']! as String,
            response['authenticatorData']! as String,
            response['clientDataJson']! as String,
            b64url(key.credential.id),
            'clientDataJson',
            'webauthn',
            for (var n = 1; n <= server.webauthnChallengesGiven; n++) b64url(sha256.convert(utf8.encode('fake challenge $n')).bytes),
          ]) {
            expect(opened.toString(), isNot(contains(secret)), reason: secret);
          }
        }
        await tester.pumpWidget(const SizedBox());
        return (credentials.keys.toSet(), kit.kv.storedKeys().map(_shape).toSet(), opened.toString());
      }

      final (codeCredentials, codeStore, _) = await signedIn(tester, byKey: false);
      final (keyCredentials, keyStore, _) = await signedIn(tester, byKey: true);

      expect(keyCredentials, codeCredentials);
      expect(keyStore, codeStore);
    });
  });

  group('with a YubiKey one-time password', () {
    const otp = 'ccccccbchvthlivuitriujjifivbvtrjkjfirllluurj';
    Uint8List message(String name) => unhex(File('test/fixtures/security_keys/ndef/$name.hex').readAsStringSync());

    /// Opens the sheet on an account whose second step is a YubiKey code,
    /// on [phone], and signs in up to the two-step screen.
    Future<FakeVaultwarden> atStep(WidgetTester tester, {FakeSecurityKeys? phone}) async {
      final (_, server) = await _open(
        tester,
        phone: phone,
        prepare: (server) async => server
          ..twoFactor = {VwTwoFactor.yubikey}
          ..twoFactorCode = otp,
      );
      await _signIn(tester);
      expect(field(t('vaultwarden.step.code')), findsOneWidget);
      return server;
    }

    void hold(FakeSecurityKeys phone, String fixture) =>
        phone.arrive(FakeKey(productName: 'YubiKey', applets: [FakeNdefApplet(message(fixture))]).device(kinds: {SecurityKeyLinkKind.nfc}));

    testWidgets('fills the code field from the key held to the phone, and Continue signs in', (tester) async {
      final phone = FakeSecurityKeys();
      final server = await atStep(tester, phone: phone);
      hold(phone, 'yubico-link');

      await tapButton(tester, t('vaultwarden.step.yubikeyNfc'));

      expect(tester.widget<TextField>(field(t('vaultwarden.step.code'))).controller!.text, otp);
      expect(find.byType(AppAlert), findsNothing);
      expect(phone.openLinks, isEmpty, reason: 'the key is let go once read');
      await tapButton(tester, t('vaultwarden.continue'));
      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(_steps(server).single, containsPair('twoFactorToken', otp));
      expect(_steps(server).single['twoFactorProvider'], '${VwTwoFactor.yubikey}');
    });

    testWidgets('reads the key under the NFC sheet on an iPhone', (tester) async {
      final phone = FakeSecurityKeys(phone: FakeSecurityKeys.iphone);
      await atStep(tester, phone: phone);
      hold(phone, 'yubico-link');

      await tapButton(tester, t('vaultwarden.step.yubikeyNfc'));

      expect(tester.widget<TextField>(field(t('vaultwarden.step.code'))).controller!.text, otp);
      expect(phone.calls, contains('beginNfc ${t('vaultwarden.key.hold.ios')}'));
      expect(phone.nfcSheetUp, isFalse);
    });

    testWidgets('says a key that gives no code gave none, and leaves the field', (tester) async {
      final phone = FakeSecurityKeys();
      final server = await atStep(tester, phone: phone);
      await tester.enterText(field(t('vaultwarden.step.code')), 'cccc');
      await tester.pump();
      hold(phone, 'text-record');

      await tapButton(tester, t('vaultwarden.step.yubikeyNfc'));

      expect(find.text(t('vaultwarden.step.yubikeyNoCode')), findsOneWidget);
      expect(tester.widget<TextField>(field(t('vaultwarden.step.code'))).controller!.text, 'cccc');
      expect(_steps(server), isEmpty);
      expect(button(tester, t('vaultwarden.step.yubikeyNfc')).onPressed, isNotNull);
    });

    testWidgets('can be cancelled while it waits for the key', (tester) async {
      final phone = FakeSecurityKeys();
      await atStep(tester, phone: phone);

      await tester.tap(buttonWithText(t('vaultwarden.step.yubikeyNfc')));
      await tester.pump();
      await tester.pump();
      expect(find.text(t('vaultwarden.key.status.waiting')), findsOneWidget);
      await tester.tap(find.byKey(vwKeyCancelKey));
      await tester.pumpAndSettle();

      expect(find.text(t('vaultwarden.key.status.waiting')), findsNothing);
      expect(find.byType(AppAlert), findsNothing, reason: 'a cancellation is not an error');
      expect(tester.widget<TextField>(field(t('vaultwarden.step.code'))).controller!.text, isEmpty);
      expect(phone.isWatching, isFalse);
    });

    testWidgets('is not offered on a phone without NFC, and the code can still be typed', (tester) async {
      // An iPad has a port and no NFC; the default phone reaches nothing
      for (final phone in [FakeSecurityKeys(phone: FakeSecurityKeys.ipad), null]) {
        final server = await atStep(tester, phone: phone);
        expect(find.text(t('vaultwarden.step.yubikeyNfc')), findsNothing);

        await tester.enterText(field(t('vaultwarden.step.code')), otp);
        await tester.pump();
        await tapButton(tester, t('vaultwarden.continue'));
        expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
        expect(_steps(server).single, containsPair('twoFactorToken', otp));
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('leaves typing the code as it was on a phone with NFC', (tester) async {
      final server = await atStep(tester, phone: FakeSecurityKeys());
      expect(find.text(t('vaultwarden.step.yubikeyNfc')), findsOneWidget);
      expect(find.text(t('vaultwarden.step.yubikeyHelper')), findsOneWidget);

      await tester.enterText(field(t('vaultwarden.step.code')), otp);
      await tester.pump();
      await tapButton(tester, t('vaultwarden.continue'));

      expect(find.text(t('vaultwarden.storage.title')), findsOneWidget);
      expect(_steps(server).single, containsPair('twoFactorToken', otp));
    });
  });
}

/// The second steps the client sent with a sign-in, as the token request's form.
List<Map<String, String>> _steps(FakeVaultwarden server) => [
  for (final request in server.requests)
    if (request.url.path == '/identity/connect/token')
      if (Uri.splitQueryString(request.body) case final form when form.containsKey('twoFactorToken') && form['twoFactorProvider'] != '5')
        form,
];

/// Taps the button labelled [label] and lets what follows happen, while
/// the sheet's progress bar keeps moving and so never settles.
Future<void> _tapWhileBusy(WidgetTester tester, String label) async {
  await tester.tap(buttonWithText(label));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A storage key with what differs from vault to vault (ids) taken out.
String _shape(String key) => key.replaceAll(RegExp(r'[0-9a-f]{8}-[0-9a-f-]{27}|[0-9a-f]{16,}'), '#');

/// A fake phone, a security key and its credential registered with the
/// fake server, for the sheet's security key step.
class _Key {
  _Key({
    SecurityKeyCapabilities phone = FakeSecurityKeys.android,
    this.domain = 'https://vault.example.com',
    String? pin,
    bool alwaysUv = false,
  }) : phone = FakeSecurityKeys(phone: phone),
       fido = FakeFidoKey(pin: pin)
         ..alwaysUv = alwaysUv
         ..maxCredentialCountInList = 8 {
    credential = fido.addSignInCredential(domain == null ? 'localhost' : Uri.parse(domain!).host);
  }

  final FakeSecurityKeys phone;
  final FakeFidoKey fido;

  /// The server's own address; null for a server that has none set.
  final String? domain;
  late final FakeSignInCredential credential;

  /// Opens the sync sheet on a server that knows the key, with [also] as
  /// the account's other methods.
  Future<(SyncSheetKit, FakeVaultwarden)> open(
    WidgetTester tester, {
    Set<int> also = const {},
    void Function(FakeVaultwarden server)? prepare,
    DateTime Function()? clock,
  }) => _open(
    tester,
    phone: phone,
    clock: clock,
    prepare: (server) async {
      server
        ..domain = domain
        ..twoFactor = {...also}
        ..registerKey(credential.id, credential.keyPair.point);
      prepare?.call(server);
    },
  );

  /// The key is held to the phone, or plugged in over [kinds].
  void present({Set<SecurityKeyLinkKind> kinds = const {SecurityKeyLinkKind.nfc}}) =>
      phone.arrive(FakeKey(productName: 'Example Key', ctap: fido).device(kinds: kinds));

  /// How many assertion requests the key got.
  int get assertions => fido.requests.where((request) => request == '2').length;
}

VaultwardenBackend _backendFor(SyncSheetKit kit, FakeVaultwarden server) =>
    VaultwardenBackend(vault: kit.vaultStore, session: kit.session, clientFor: (_) => server.newClient());

/// A client that fails every request as a refused certificate would, when
/// [problem] is set.
class _Refusing extends http.BaseClient {
  _Refusing(this.inner, this.problem);

  final http.Client inner;
  final String? problem;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (problem != null) throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
    return inner.send(request);
  }
}
