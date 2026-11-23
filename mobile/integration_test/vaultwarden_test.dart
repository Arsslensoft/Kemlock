// Vaultwarden sync on a phone, or a simulator or emulator, against a real
// server: the app as it ships, with its own storage, isolates and TLS, and
// only the camera faked. It makes a vault with an account, sets
// sealed sync up through a self-signed certificate and setup's summary,
// changes to plain storage, links the account to the user's own login and
// shows its password, checking what the server holds after each step.
//
// It needs a new account on the server (sign up in its web vault), and
// erases this app's data on the phone first:
//
//   flutter drive -d <device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/vaultwarden_test.dart \
//     --dart-define=VAULTWARDEN_URL=https://<host>:8443 \
//     --dart-define=VAULTWARDEN_EMAIL=<email> \
//     --dart-define=VAULTWARDEN_PASSWORD=<master password>
//
// An Android emulator reaches the computer it runs on at 10.0.2.2. The
// screenshots go to build/screenshots/.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kemlock/app.dart';
import 'package:kemlock/core/ids.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/storage/preferences_backend.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_http.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/i18n/messages.dart';

import '../test/fakes/fake_scanner.dart';

const _server = String.fromEnvironment('VAULTWARDEN_URL');
const _email = String.fromEnvironment('VAULTWARDEN_EMAIL');
const _password = String.fromEnvironment('VAULTWARDEN_PASSWORD');

const _masterPassword = 'Correct-Horse-9';
const _secret = 'JBSWY3DPEHPK3PXP';
const _userPassword = 'hunter2-correct-horse';

late MessageCatalog _catalog;
String t(String id, [Map<String, Object?> args = const {}]) => _catalog.of(AppLocale.en).t(id, args);

/// One item of the account's vault, decrypted.
typedef _Item = ({String id, int type, String name, bool trashed, String? username, String? totp});

/// Whether [item] is a login, out of the trash, that holds the account's
/// code: the otpauth link plain storage writes.
bool _holdsCode(_Item item) => item.type == 1 && !item.trashed && (item.totp?.contains('secret=$_secret') ?? false);

/// The server as the user's other apps see it: signed in on its own,
/// trusting the certificate the app is asked to trust.
class _Server {
  _Server._(this.connection, this.key);

  final VwConnection connection;
  final BwKey key;

  static Future<_Server> signIn() async {
    final pin = await untrustedCertificate(vwServerUrl(_server));
    final setup = VwAccountSetup(VwApi(vwHttpClient(pin: pin)));
    await setup.connect(_server, _email);
    final done = await setup.signIn(_password, deviceId: newUuid()) as VwSignInDone;
    return _Server._(setup.connection(done.credentials), done.credentials.key);
  }

  Future<String?> _open(Object? value) async => value is String ? bwDecryptString(value, key) : null;

  Future<List<_Item>> items() async => [
    for (final cipher in await connection.ciphers())
      (
        id: cipher.id,
        type: cipher.json['type']! as int,
        name: (await _open(cipher.json['name']))!,
        trashed: cipher.inTrash,
        username: await _open((cipher.json['login'] as Map<String, Object?>?)?['username']),
        totp: await _open((cipher.json['login'] as Map<String, Object?>?)?['totp']),
      ),
  ];

  /// Adds the user's own GitHub login, as a Bitwarden app would: a
  /// username, a password and a website, and no code yet.
  Future<void> addUserLogin() async {
    final body = {
      'type': 1,
      'name': await bwEncryptString('GitHub', key),
      'favorite': false,
      'reprompt': 0,
      'encryptedFor': connection.credentials.userId,
      'login': {
        'username': await bwEncryptString('octocat', key),
        'password': await bwEncryptString(_userPassword, key),
        'uris': [
          {'uri': await bwEncryptString('https://github.com', key), 'match': null},
        ],
      },
    };
    await connection.call((token) => connection.api.createCipher(connection.server, token, body));
  }

  /// Waits until the vault's items pass [check].
  Future<List<_Item>> until(bool Function(List<_Item> items) check, {Duration timeout = const Duration(seconds: 60)}) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      final now = await items();
      if (check(now)) return now;
      if (DateTime.now().isAfter(end)) fail('The server never got there: $now');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Lets the screen catch up: pumps for [min], then on while a frame is
  /// due, up to [max]. pumpAndSettle would wait out a progress bar or the
  /// codes' countdown, which keep going on a phone.
  Future<void> settle(
    WidgetTester tester, {
    Duration min = const Duration(milliseconds: 800),
    Duration max = const Duration(seconds: 5),
  }) async {
    final start = DateTime.now();
    while (true) {
      await tester.pump(const Duration(milliseconds: 100));
      final waited = DateTime.now().difference(start);
      if (waited >= max || (waited >= min && !tester.binding.hasScheduledFrame)) return;
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await binding.takeScreenshot('${Platform.operatingSystem}_$name');
  }

  /// Pumps until [finder] finds something, for work that takes real time.
  Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 60)}) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('Waited $timeout for $finder');
      await tester.pump(const Duration(milliseconds: 200));
    }
    await settle(tester);
  }

  /// Taps [finder] once it's in view.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder.first);
    await settle(tester);
    await tester.tap(finder.first);
    await settle(tester);
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('sets vaultwarden sync up, sealed then plain, and shows a linked login', skip: _server.isEmpty, (tester) async {
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
    final server = await _Server.signIn();
    await server.addUserLogin();

    // The app as main() starts it, with this app's data erased
    final store = await KeyValueStore.open(CapacitorPreferences.forPlatform() ?? MemoryPreferences());
    for (final key in store.storedKeys()) {
      store.removeItem(key);
    }
    _catalog = await MessageCatalog.load();
    final container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(_catalog),
        FakeScanner().asOverride,
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KemlockApp()));
    await waitFor(tester, find.text(t('setup.title')));

    // A vault with one account
    await tester.enterText(field(t('setup.field.password')), _masterPassword);
    await tester.enterText(field(t('setup.field.confirm')), _masterPassword);
    await tap(tester, find.text(t('setup.button')));
    await waitFor(tester, find.text(t('app.empty.otp.title')));
    await tap(tester, find.text(t('app.empty.otp.action')));
    await tap(tester, find.text(t('addAccount.tab.manual')));
    await tester.enterText(field(t('addAccount.field.issuer')), 'GitHub');
    await tester.enterText(field(t('addAccount.field.secret')), _secret);
    await tap(tester, find.text(t('addAccount.add')));
    await waitFor(tester, find.byTooltip(t('accountCard.details', {'name': 'GitHub'})));

    // Sealed sync, through the self-signed certificate. The sheet opens as
    // Settings › Sync opens it: on a phone, the test's taps miss the tab bar
    unawaited(showSyncSheet(tester.element(find.byType(Scaffold).first)));
    await settle(tester);
    await tap(tester, find.text(t('sync.where.vaultwarden')));
    await tester.enterText(field(t('vaultwarden.field.server')), _server);
    await tester.enterText(field(t('vaultwarden.field.email')), _email);
    await tester.enterText(field(t('vaultwarden.field.password')), _password);
    await shot(tester, '1_sign_in');
    await tap(tester, find.text(t('vaultwarden.signIn')));
    await waitFor(tester, find.text(t('vaultwarden.cert.title')));
    await shot(tester, '2_certificate');
    await tap(tester, find.text(t('vaultwarden.cert.trust')));
    await waitFor(tester, find.text(t('vaultwarden.storage.title')));
    await shot(tester, '3_storage');
    await tap(tester, find.text(t('vaultwarden.continue')));
    await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
    await settle(tester);
    await tap(tester, find.text(t('vaultwarden.continue')));
    await waitFor(tester, find.text(t('vaultwarden.summary.title')));
    expect(
      find.text(
        t('vaultwarden.summary.to', {
          'what': t('vaultwarden.summary.accounts', {'count': 1}),
        }),
      ),
      findsOneWidget,
    );
    await shot(tester, '4_summary');
    expect((await server.items()).where((item) => !item.trashed).map((item) => item.name), ['GitHub'], reason: 'nothing written yet');

    await tap(tester, find.text(t('vaultwarden.turnOn')));
    await waitFor(tester, find.text(t('vaultwarden.change')));
    var items = await server.until((items) => items.any((item) => item.name == 'Kemlock sealed entry' && !item.trashed));
    final sealed = items.where((item) => !item.trashed).map((item) => item.name);
    expect(sealed, unorderedEquals(['GitHub', 'Kemlock', 'Kemlock sealed entry']));
    await waitFor(tester, find.textContaining(t('sync.status.synced', {'when': ''}).trim()));
    await shot(tester, '5_sealed_on');

    // Plain storage: the code becomes a login Bitwarden apps show
    await tap(tester, find.text(t('vaultwarden.change')));
    await tap(tester, find.text(t('vaultwarden.storage.plainAgree')));
    await tap(tester, find.text(t('vaultwarden.change.confirm')));
    items = await server.until((items) => items.any(_holdsCode));
    expect(items.where((item) => item.name == 'Kemlock sealed entry').every((item) => item.trashed), isTrue);
    await waitFor(
      tester,
      find.text(t('vaultwarden.on.body', {'host': vwHost(_server), 'email': _email, 'mode': t('vaultwarden.mode.plain')})),
    );
    await shot(tester, '6_plain_on');
    await tap(tester, find.text(t('export.close')));

    // Linked to the user's own login, whose password the account sheet shows
    await tap(tester, find.byTooltip(t('accountCard.details', {'name': 'GitHub'})));
    await tap(tester, find.text(t('vaultwarden.link')));
    await waitFor(tester, find.text('octocat · https://github.com'));
    await tap(tester, find.text('octocat · https://github.com'));
    items = await server.until((items) => items.any((item) => item.username == 'octocat' && _holdsCode(item)));
    await waitFor(tester, find.text(t('vaultwarden.login.title')));
    await tap(tester, find.byTooltip(t('vaultwarden.login.show')));
    expect(find.text(_userPassword), findsOneWidget);
    await shot(tester, '7_linked_login');
    items = await server.until((items) => items.where((item) => item.type == 1 && !item.trashed).length == 1);
    expect(items.singleWhere((item) => item.type == 1 && !item.trashed).username, 'octocat');
  });
}
