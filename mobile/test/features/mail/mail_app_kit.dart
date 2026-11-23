import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/features/mail/mail_key_cache.dart';
import 'package:kemlock/features/mail/mail_service.dart';
import 'package:kemlock/features/pgp/pgp_controller.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/mail_requests.dart';

import '../../fakes/fake_mail_requests.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../pgp/pgp_kit.dart';
import 'mail_kit.dart';

const thunderbird = MailCaller(package: 'net.thunderbird.android', cert: 'aa11', label: 'Thunderbird');

/// The mail fixtures' day.
final mailNow = DateTime.utc(2026, 11, 17, 9);

/// The whole app with the mail provider served through a fake service and
/// request screen, PGP work on the test's isolate, and a vault on the
/// phone whose password is `pw`.
class MailScreensApp {
  MailScreensApp(this.tester) : app = TestApp(now: () => mailNow);

  final WidgetTester tester;
  final TestApp app;
  final requests = FakeMailRequests();
  var _ids = 0;

  /// Starts the app on the lock screen, with the vault made and, when
  /// [unlock], opened, and [overrides] added to the app's.
  Future<void> start({bool unlock = true, Future<void> Function()? beforeStart, List<Override> overrides = const []}) async {
    await app.createVault('pw');
    await beforeStart?.call();
    await startApp(
      tester,
      app,
      overrides: [
        requests.asOverride,
        pgpJobStarterProvider.overrideWithValue(inlineJob),
        mailKeyOpenerProvider.overrideWithValue(pgp.openPgpSecretKey),
        ...overrides,
      ],
    );
    app.container.read(mailServiceProvider);
    if (unlock) await app.unlock(tester, 'pw');
  }

  /// Puts a fixture key of `fixtureKeys` in the open vault, as `pgp-<name>`.
  Future<VaultKey> addKey(String name) async {
    final (path, title) = fixtureKeys[name]!;
    final key = (await tester.runAsync(() async {
      final parsed = await crypto.readPrivateKey(fixtureBytes(path));
      final key = vaultKeyOf(parsed, id: 'pgp-$name', name: title, origin: KeyOrigin.imported);
      await app.controller.addKey(key);
      return key;
    }))!;
    await tester.pumpAndSettle();
    return key;
  }

  /// Puts the public key at [path] (under test/fixtures) among the open
  /// vault's contacts: not checked, or with [checkedFor] its fingerprint
  /// compared while the key named those addresses only.
  Future<void> addContact(
    String id,
    String path, {
    required String name,
    ({String fingerprint, List<String> addresses})? checkedFor,
  }) async {
    await tester.runAsync(() async {
      final key = await pgp.readPgpPublicKey(fixtureBytes(path));
      final contact = Contact(id: id, name: name, publicKey: b64(key.transferableKey), source: ContactSource.file, addedAt: 0);
      await app.controller.addContact(
        checkedFor == null ? contact : contact.checked(checkedFor.fingerprint, 1, addresses: checkedFor.addresses),
      );
    });
    await tester.pumpAndSettle();
  }

  /// Approves [caller] in the open vault, for [keys].
  Future<void> approve({MailCaller caller = thunderbird, List<String> keys = const []}) async {
    await tester.runAsync(
      () => app.container
          .read(mailAppsProvider.notifier)
          .put(MailApp(package: caller.package, cert: caller.cert, name: caller.name, allowedAt: 0, keys: keys)),
    );
  }

  MailApps get apps => app.container.read(mailAppsProvider.notifier);

  /// A request as a mail app sends it.
  MailCall call(String action, {Map<String, Object?> extras = const {}, MailCaller caller = thunderbird, List<int>? input}) => MailCall(
    requestId: 'r${++_ids}',
    action: action,
    extras: {'api_version': 12, ...extras},
    caller: caller,
    input: input == null ? null : Uint8List.fromList(input),
  );

  /// Sends [call], which must need the person, and brings its request
  /// screen to the front.
  Future<void> bringUp(MailCall call) async {
    final answer = (await tester.runAsync(() => requests.send(call)))!;
    expect(answer.resultCode, OpenPgp.resultUserInteraction, reason: '${answer.result}');
    requests.bringToFront(call.requestId, call.caller);
    await settle();
  }

  /// Lets real async work (the vault's sealing, the crypto) finish.
  Future<void> settle([int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
  }

  /// How the request screens were closed: request id and whether OK.
  List<(String, bool)> get finished => [for (final f in requests.finished) (f.requestId, f.ok)];
}
