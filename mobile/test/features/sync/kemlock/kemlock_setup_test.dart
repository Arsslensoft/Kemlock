// The setup sheet of Kemlock Server sync (add-kemlock-server-sync, task 5.2):
// the ways in as the server lists them, the password through OPAQUE against the
// fake server, the second step, what a refused address or downgrade says, and
// that nothing is sent while offline mode is on.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_platform_passkey.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/kemlock_flow.dart';
import 'package:kemlock/features/sync/kemlock_host_factory.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/platform/device_keys.dart';
import 'package:kemlock/platform/platform_passkeys.dart';
import 'package:kemlock/platform/push.dart';

import '../../../fakes/fake_device_keys.dart';
import '../../../fakes/fake_security_keys.dart';
import '../../../helpers/test_app.dart';
import '../../spaces/chain_kit.dart';
import '../sync_screen_kit.dart';
import 'fake_kemlock_accounts.dart';

const _password = 'correct horse battery staple';
const _email = 'me@example.com';
const _address = 'https://kem.example.com';

late KmTestAccount _account;

/// A phone with no push service. The store build's push asks a platform channel for its token, and a widget
/// test never gets that answer, so the sheet would wait on it for ever with its progress bar spinning.
class _NoPush implements PushTokens {
  @override
  bool get available => false;

  @override
  Future<String?> token() async => null;

  @override
  Stream<PushNudge> get onMessage => const Stream.empty();
}

/// A phone whose push channel never answers for its token.
class _SilentPush implements PushTokens {
  @override
  bool get available => true;

  @override
  Future<String?> token() => Completer<String?>().future;

  @override
  Stream<PushNudge> get onMessage => const Stream.empty();
}

Future<FakeKemlockAccountServer> _opaqueServer() async {
  final server = FakeKemlockAccountServer(userId: _account.userId);
  await server.registerOpaque(_password, _account);
  return server;
}

/// The sync sheet of a vault with sync off, over [server], on the Kemlock Server choice.
Future<SyncSheetKit> _open(
  WidgetTester tester,
  FakeKemlockAccountServer server, {
  FakeSecurityKeys? phone,
  bool hardware = false,
  PushTokens? push,
  List<Override> overrides = const [],
  Future<void> Function(SyncSheetKit kit)? before,
}) async {
  final kit = SyncSheetKit(phone: phone);
  await kit.pump(
    tester,
    showSyncSheet,
    // The fake server checks each proof's time against the real clock
    clock: DateTime.now,
    overrides: [
      pushTokensProvider.overrideWithValue(push ?? _NoPush()),
      ...overrides,
      kemlockClientFactoryProvider.overrideWithValue((pin) => server.client),
      deviceKeysProvider.overrideWithValue(FakeDeviceKeys(hasHardware: hardware)),
      kemlockSetupPartsProvider.overrideWithValue(
        KmSetupParts(opaque: FakeKmOpaque(), deviceName: 'Kemlock on Pixel 9', deviceKind: 'kemlock-android', argon2: cheapArgon2),
      ),
    ],
  );
  await before?.call(kit);
  await kit.open(tester);
  await tester.tap(find.text(t('sync.where.kemlock')));
  await tester.pumpAndSettle();
  return kit;
}

/// Types the address and email and goes on to the ways in.
Future<void> _connect(WidgetTester tester, {String address = _address}) async {
  await tester.enterText(field(t('kemlock.field.server')), address);
  await tester.enterText(field(t('kemlock.field.email')), _email);
  await tester.pump();
  await tapButton(tester, t('kemlock.continue'));
}

void main() {
  setUpAll(() async {
    _account = await KmTestAccount.create('00000000-0000-4000-8000-000000000001');
  });

  testWidgets('signs in with the master password, seals the session and turns sync on', (tester) async {
    final server = await _opaqueServer();
    final kit = await _open(tester, server);

    await _connect(tester);
    expect(find.text(t('kemlock.ways.title')), findsOneWidget);
    await tester.enterText(field(t('kemlock.field.password')), _password);
    await tester.pump();
    await tapButton(tester, t('kemlock.signIn'));

    final target = kit.settings?.kemlock;
    expect(target, isNotNull);
    expect(target!.email, _email);
    expect(target.accountId, _account.userId);
    expect(target.home.url, _address);
    final session = await kit.vaultStore.loadEncryptedValue(keyKemlockSession, kit.session);
    expect(session, isA<Map<String, Object?>>());
    final account = await kit.vaultStore.loadEncryptedValue(keyKemlockAccount, kit.session);
    expect((account! as Map<String, Object?>)['opaqueEnrolled'], isTrue);
    expect(find.text(t('kemlock.on.body', {'host': 'kem.example.com', 'email': _email})), findsOneWidget);
    for (final request in server.requests) {
      expect(request.body, isNot(contains(_password)));
    }
  });

  testWidgets('a push channel that never gives its token holds nothing up', (tester) async {
    await _open(tester, await _opaqueServer(), push: _SilentPush());

    await _connect(tester);
    expect(find.text(t('kemlock.ways.title')), findsOneWidget);
  });

  testWidgets('a wrong password says "wrong email or password" and turns nothing on', (tester) async {
    final kit = await _open(tester, await _opaqueServer());

    await _connect(tester);
    await tester.enterText(field(t('kemlock.field.password')), 'not the password');
    await tester.pump();
    await tapButton(tester, t('kemlock.signIn'));

    expect(find.text(t('kemlock.signin.wrongPassword')), findsOneWidget);
    expect(kit.settings?.kemlock, isNull);
  });

  testWidgets('a phone that saw the account enrolled says it may be the wrong password or the wrong server, and names the address', (
    tester,
  ) async {
    final server = await _opaqueServer();
    server.opaqueRecord = null;
    final kit = await _open(tester, server, before: (kit) async => kmRememberOpaque(VaultKmValues(kit.vaultStore, kit.session)));

    await _connect(tester);
    await tester.enterText(field(t('kemlock.field.password')), _password);
    await tester.pump();
    await tapButton(tester, t('kemlock.signIn'));

    expect(find.text(t('kemlock.signin.downgrade', {'host': 'kem.example.com'})), findsOneWidget);
    expect(server.bitwardenHashes, isEmpty);
    expect(kit.settings?.kemlock, isNull);
  });

  testWidgets('a second step is a code, and the sign-in finishes with it', (tester) async {
    final server = await _opaqueServer();
    server.secondStep = ['totp'];
    final kit = await _open(tester, server);

    await _connect(tester);
    await tester.enterText(field(t('kemlock.field.password')), _password);
    await tester.pump();
    await tapButton(tester, t('kemlock.signIn'));
    expect(find.text(t('kemlock.step.title')), findsOneWidget);

    await tester.enterText(field(t('kemlock.step.code')), server.totpCode);
    await tester.pump();
    await tapButton(tester, t('kemlock.continue'));

    expect(kit.settings?.kemlock, isNotNull);
  });

  testWidgets('SSO comes first with the provider\'s name, and the password is still below it', (tester) async {
    final server = await _opaqueServer();
    server.methods = {
      'methods': ['sso', 'password'],
      'sso': {'providerName': 'Example Co'},
    };
    await _open(tester, server);

    await _connect(tester);

    final sso = find.text(t('kemlock.ways.sso', {'provider': 'Example Co'}));
    expect(sso, findsOneWidget);
    expect(field(t('kemlock.field.password')), findsOneWidget);
    expect(tester.getTopLeft(sso).dy, lessThan(tester.getTopLeft(field(t('kemlock.field.password'))).dy));
  });

  /// What the phone holds of one verified space where Sam is Owner, Ana an Admin and Theo a Member, with Require SSO on:
  /// [who]'s own place in it, read for the account that signed in with [email].
  SpacePolicies requiringSso(Person who, {String email = _email}) {
    final sam = Person(1);
    final ana = Person(2);
    final theo = Person(3);
    final chain = ChainBuilder(uuid(0x5a))
      ..create(sam, collection: uuid(0xe0))
      ..invite(sam, ana, role: SpaceRole.admin)
      ..confirm(sam, ana)
      ..invite(sam, theo)
      ..confirm(sam, theo)
      ..policies(sam, {'requireSso': true});
    return const SpacePolicies().remembering(uuid(0x5a), who.id, chain.state, email: email);
  }

  /// A server that lists SSO for the email, with the policies the phone holds, on the ways in.
  Future<void> openWith(WidgetTester tester, SpacePolicies held, {bool serverFlag = false}) async {
    final server = await _opaqueServer();
    server.methods = {
      'methods': ['sso', 'password', 'passkey'],
      'sso': {'providerName': 'Example Co'},
      if (serverFlag) 'ssoRequired': true,
    };
    await _open(
      tester,
      server,
      phone: FakeSecurityKeys(),
      overrides: [
        platformPasskeysProvider.overrideWithValue(_Passkeys(supported: false)),
        spacePoliciesProvider.overrideWith(() => _HeldPolicies(held)),
      ],
    );
    await _connect(tester);
  }

  testWidgets('where a space the account is a Member of requires SSO, the chain makes it the only way in, with the reason', (tester) async {
    await openWith(tester, requiringSso(Person(3)));

    expect(find.text(t('kemlock.ways.sso', {'provider': 'Example Co'})), findsOneWidget);
    expect(find.text(t('kemlock.ways.ssoRequired')), findsOneWidget);
    expect(field(t('kemlock.field.password')), findsNothing);
    expect(find.text(t('kemlock.ways.key')), findsNothing);
  });

  testWidgets('a space held for another account’s email forces nothing on a person who signs in with theirs', (tester) async {
    await openWith(tester, requiringSso(Person(3), email: 'someone.else@example.com'));

    expect(find.text(t('kemlock.ways.ssoRequired')), findsNothing);
    expect(field(t('kemlock.field.password')), findsOneWidget);
    expect(find.text(t('kemlock.ways.key')), findsOneWidget);
  });

  for (final (role, who) in [('Owner', Person(1)), ('Admin', Person(2))]) {
    testWidgets('the $role of that space keeps every way in', (tester) async {
      await openWith(tester, requiringSso(who));

      expect(find.text(t('kemlock.ways.ssoRequired')), findsNothing);
      expect(field(t('kemlock.field.password')), findsOneWidget);
      expect(find.text(t('kemlock.ways.key')), findsOneWidget);
    });
  }

  testWidgets('a server that says SSO is required, with no chain saying it, is not believed before the sign-in', (tester) async {
    await openWith(tester, const SpacePolicies(), serverFlag: true);

    expect(find.text(t('kemlock.ways.ssoRequired')), findsNothing);
    expect(field(t('kemlock.field.password')), findsOneWidget);
    expect(find.text(t('kemlock.ways.key')), findsOneWidget);
  });

  testWidgets("a password the server accepts but a space's Require SSO refuses says so, and offers SSO only", (tester) async {
    final server = await _opaqueServer();
    server.methods = {
      'methods': ['sso', 'password', 'passkey'],
      'sso': {'providerName': 'Example Co'},
    };
    server.ssoRequiredSpace = '5c9d0e1f-1111-4222-8333-444455556666';
    final kit = await _open(tester, server, phone: FakeSecurityKeys());

    await _connect(tester);
    expect(field(t('kemlock.field.password')), findsOneWidget);
    await tester.enterText(field(t('kemlock.field.password')), _password);
    await tester.pump();
    await tapButton(tester, t('kemlock.signIn'));

    expect(find.text(t('kemlock.signin.ssoRequired')), findsOneWidget);
    expect(find.text(t('kemlock.signin.wrongPassword')), findsNothing);
    expect(find.text(t('kemlock.ways.sso', {'provider': 'Example Co'})), findsOneWidget);
    expect(field(t('kemlock.field.password')), findsNothing);
    expect(find.text(t('kemlock.ways.key')), findsNothing);
    expect(kit.settings?.kemlock, isNull);
  });

  testWidgets('a security key is offered on every server when the phone reaches keys', (tester) async {
    final server = await _opaqueServer();
    server.methods = {
      'methods': ['passkey', 'password'],
    };
    await _open(
      tester,
      server,
      phone: FakeSecurityKeys(),
      overrides: [platformPasskeysProvider.overrideWithValue(_Passkeys(supported: false))],
    );
    await _connect(tester);
    expect(find.text(t('kemlock.ways.key')), findsOneWidget);
  });

  testWidgets('no security key is offered to a phone that reaches none', (tester) async {
    final server = await _opaqueServer();
    server.methods = {
      'methods': ['passkey', 'password'],
    };
    await _open(tester, server, overrides: [platformPasskeysProvider.overrideWithValue(_Passkeys(supported: false))]);
    await _connect(tester);
    expect(find.text(t('kemlock.ways.key')), findsNothing);
    expect(field(t('kemlock.field.password')), findsOneWidget);
  });

  testWidgets('a phone with no hardware key says its tokens are bound to a software one', (tester) async {
    await _open(tester, await _opaqueServer());
    await _connect(tester);
    expect(find.text(t('kemlock.deviceKey.software')), findsOneWidget);
  });

  testWidgets('a phone with a hardware key says nothing of the kind', (tester) async {
    await _open(tester, await _opaqueServer(), hardware: true);
    await _connect(tester);
    expect(find.text(t('kemlock.deviceKey.software')), findsNothing);
  });

  testWidgets('"Trust this phone" is on by default, and explains what it keeps', (tester) async {
    await _open(tester, await _opaqueServer());
    await _connect(tester);
    expect(find.text(t('kemlock.ways.trust')), findsOneWidget);
    expect(find.text(t('kemlock.ways.trustHint')), findsOneWidget);
    expect(find.text(t('kemlock.push.hint')), findsOneWidget);
  });

  testWidgets('plain http is refused and nothing is sent', (tester) async {
    final server = await _opaqueServer();
    await _open(tester, server);

    await _connect(tester, address: 'http://kem.example.com');

    expect(find.text(t('sync.problem.insecure')), findsOneWidget);
    expect(server.requests, isEmpty);
  });

  testWidgets('an address that is not a Kemlock Server is said so, and the email is never sent', (tester) async {
    final server = await _opaqueServer();
    server.respond = (request) async => http.Response('{"hello":"world"}', 200, headers: {'content-type': 'application/json'});
    await _open(tester, server);

    await _connect(tester);

    expect(find.text(t('sync.problem.kemlockAddress')), findsOneWidget);
    expect(server.requests.map((r) => r.url.path), ['/kem/v1/config']);
  });

  testWidgets('offline mode pauses setup: nothing is offered to connect, nothing is sent', (tester) async {
    final server = await _opaqueServer();
    final kit = await _open(tester, server);

    await kit.setOffline(tester, true);

    expect(offlineAlert(t('sync.offline.setup')), findsOneWidget);
    expect(button(tester, t('kemlock.continue')).onPressed, isNull);
    expect(server.requests, isEmpty);
  });

  group('the phone\'s own passkey', () {
    final named = [
      {
        'relation': ['delegate_permission/common.get_login_creds'],
        'target': {'namespace': 'android_app', 'package_name': 'com.kemlock.app'},
      },
    ];

    Future<FakeKemlockAccountServer> serverNaming(List<Object?>? links) async {
      final server = await _opaqueServer();
      server.methods = {
        'methods': ['passkey', 'password'],
      };
      server.respond = (request) async => request.url.path == '/.well-known/assetlinks.json'
          ? (links == null ? http.Response('', 404) : http.Response(jsonEncode(links), 200, headers: {'content-type': 'application/json'}))
          : server.handle(request);
      return server;
    }

    testWidgets('is offered when the phone supports it and the server names the app, as it is on every server', (tester) async {
      final server = await serverNaming(named);
      await _open(tester, server, overrides: [platformPasskeysProvider.overrideWithValue(_Passkeys(supported: true))]);

      await _connect(tester);

      expect(find.text(t('kemlock.ways.passkey')), findsOneWidget);
    });

    testWidgets('is not offered where the server does not name the app', (tester) async {
      final server = await serverNaming(null);
      await _open(tester, server, overrides: [platformPasskeysProvider.overrideWithValue(_Passkeys(supported: true))]);

      await _connect(tester);

      expect(find.text(t('kemlock.ways.passkey')), findsNothing);
      expect(field(t('kemlock.field.password')), findsOneWidget);
    });

    testWidgets('is not offered where the phone has none to give, as on iOS', (tester) async {
      final server = await serverNaming(named);
      await _open(tester, server, overrides: [platformPasskeysProvider.overrideWithValue(_Passkeys(supported: false))]);

      await _connect(tester);

      expect(find.text(t('kemlock.ways.passkey')), findsNothing);
    });

    testWidgets('a phone with no passkey for the account says so and stays signed out', (tester) async {
      final server = await serverNaming(named);
      final kit = await _open(
        tester,
        server,
        overrides: [
          platformPasskeysProvider.overrideWithValue(_Passkeys(supported: true, error: const KmPlatformPasskeyError('noCredential'))),
        ],
      );

      await _connect(tester);
      await tapButton(tester, t('kemlock.ways.passkey'));

      expect(find.text(t('kemlock.passkey.noCredential')), findsOneWidget);
      expect(kit.settings?.kemlock, isNull);
    });
  });
}

class _Passkeys implements KmPlatformPasskeys {
  _Passkeys({required this.supported, this.error});

  final bool supported;
  final KmPlatformPasskeyError? error;

  @override
  Future<KmPlatformPasskeyInfo> info() async => KmPlatformPasskeyInfo(supported: supported, package: 'com.kemlock.app');

  @override
  Future<String> get(String requestJson) async => throw error ?? const KmPlatformPasskeyError('failed');
}

/// The policies the phone holds of its verified spaces, set in place of the reports a run would make.
class _HeldPolicies extends SpacePoliciesNotifier {
  _HeldPolicies(this._held);

  final SpacePolicies _held;

  @override
  SpacePolicies build() => _held;
}
