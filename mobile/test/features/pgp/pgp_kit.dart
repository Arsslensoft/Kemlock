import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/pgp/pgp_controller.dart';
import 'package:kemlock/features/pgp/pgp_files.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/features/pgp/pgp_people.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_clipboard.dart';
import '../../fakes/fake_files.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

/// A fixture file under test/fixtures.
File fixtureFile(String path) => File('test/fixtures/$path');

Uint8List fixtureBytes(String path) => fixtureFile(path).readAsBytesSync();

String fixtureText(String path) => fixtureFile(path).readAsStringSync();

/// The passphrase of the protected fixture keys and of GnuPG's
/// passphrase-encrypted fixtures.
const fixturePassphrase = 'fixture passphrase';

/// The fixture keys a test vault is given, by a short name: the secret
/// key file, and what the vault calls the key.
const fixtureKeys = <String, (String, String)>{
  'ed': ('keys/gnupg/ed25519.secret.asc', 'Fixture Ed25519'),
  'rsa': ('keys/gnupg/rsa3072.secret.asc', 'Fixture RSA'),
  'ed-protected': ('keys/gnupg/ed25519-protected.secret.asc', 'Fixture Ed25519 Protected'),
  'rsa-protected': ('keys/gnupg/rsa3072-protected.secret.asc', 'Fixture RSA Protected'),
  'kemlock-ed': ('keys/kemlock/pgp-ed25519.unprotected.asc', 'Ada Lovelace'),
  'v6': ('keys/rfc9580/v6-secret.asc', 'RFC 9580 sample'),
  'expired': ('keys/gnupg/expiry/expired.secret.asc', 'Fixture Expired'),
  'revoked': ('keys/gnupg/expiry/revoked.secret.asc', 'Fixture Revoked'),
  'nistp256': ('pgp/gnupg/nistp256.secret.asc', 'Fixture NIST P-256'),
  'stub': ('pgp/gnupg/ed25519.stub.secret.gpg', 'Fixture stub'),
  // openspec: add-post-quantum-pgp
  'pq-standard': ('keys/kemlock/pgp-pq-standard.unprotected.asc', 'Ada, post-quantum'),
  'pq-gnupg': ('keys/kemlock/pgp-pq-gnupg.unprotected.asc', 'Ada, for GnuPG'),
  'sq': ('keys/sequoia/pqc/standard.secret.asc', 'Fixture Sequoia'),
  'sq-protected': ('keys/sequoia/pqc/standard-protected.secret.asc', 'Fixture Sequoia'),
  'kyber-protected': ('keys/gnupg/pqc/ky768-cv25519-protected.secret.asc', 'Fixture Kyber Protected'),
  'mldsa87': ('keys/rfc9980/a4-secret.asc', 'RFC 9980 A.4'),
};

/// A job that does its work on the test's own isolate, as it is asked
/// for. The test lets real time pass ([PgpApp.settle]) for it to finish.
class ImmediateJob implements PgpJob {
  ImmediateJob(this.request, this._directory) {
    result = _run();
  }

  final PgpRequest request;
  final Directory? _directory;
  final _progress = ValueNotifier<double>(0);
  var cancelled = false;

  @override
  late final Future<PgpOutcome> result;

  @override
  ValueListenable<double> get progress => _progress;

  @override
  void cancel() => cancelled = true;

  Future<PgpOutcome> _run() async {
    final outcome = await runPgpRequest(request, onProgress: (p) => _progress.value = p, isCancelled: () => cancelled);
    final result = cancelled ? const PgpCancelledOutcome() : outcome;
    final directory = _directory;
    if (directory != null && (result is PgpFailedOutcome || result is PgpCancelledOutcome) && directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
    return result;
  }
}

/// A job that waits for the test to say how it ends.
class HeldJob implements PgpJob {
  HeldJob(this.request, this._directory);

  final PgpRequest request;
  final Directory? _directory;
  final _done = Completer<PgpOutcome>();
  final progressValue = ValueNotifier<double>(0);
  var cancelled = false;

  @override
  Future<PgpOutcome> get result => _done.future;

  @override
  ValueListenable<double> get progress => progressValue;

  @override
  void cancel() {
    cancelled = true;
    finish(const PgpCancelledOutcome());
  }

  void finish(PgpOutcome outcome) {
    if (_done.isCompleted) return;
    final directory = _directory;
    if (directory != null && (outcome is PgpFailedOutcome || outcome is PgpCancelledOutcome) && directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
    _done.complete(outcome);
  }
}

/// The app with a vault open on the Vault tab, PGP work done on the test's
/// isolate, a fake file service and share sheet, and a real directory for
/// the temporary files.
class PgpApp {
  PgpApp(this.tester, {DateTime Function()? now}) : app = TestApp(now: now);

  final WidgetTester tester;
  final TestApp app;
  final files = FakeFiles();

  /// Every job started, in order.
  final requests = <PgpRequest>[];

  /// What reached the phone's clipboard.
  final copies = <String>[];

  /// When set, jobs wait in [held] for the test to finish them.
  var hold = false;
  final held = <HeldJob>[];

  late final Directory tempRoot;

  List<Override> get overrides => [
    files.asOverride,
    pgpTempRootProvider.overrideWithValue(() async => tempRoot),
    pgpJobStarterProvider.overrideWithValue((request, {directory}) {
      requests.add(request);
      if (!hold) return ImmediateJob(request, directory);
      final job = HeldJob(request, directory);
      held.add(job);
      return job;
    }),
    pgpPublicKeyReaderProvider.overrideWithValue(pgp.readPgpPublicKey),
    pgpKeyTroubleProvider.overrideWithValue(pgp.pgpKeyTrouble),
  ];

  /// Starts the app, makes a vault holding the fixture [keys] (short names
  /// of [fixtureKeys]) and goes to the Vault tab.
  Future<void> start({List<String> keys = const []}) async {
    tempRoot = Directory.systemTemp.createTempSync('pgp-ui-test');
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    answerSensitiveCopies(copies.add);
    await startApp(tester, app, overrides: overrides);
    await createVault(tester);
    for (final key in keys) {
      await addKey(key);
    }
    await tapOn(tester, tab('nav.vault'));
  }

  /// Puts a fixture key in the vault, under the id `pgp-<name>`.
  Future<VaultKey> addKey(String name) async {
    final (path, title) = fixtureKeys[name]!;
    final parsed = (await tester.runAsync(() => crypto.readPrivateKey(fixtureBytes(path))))!;
    final key = vaultKeyOf(parsed, id: 'pgp-$name', name: title, origin: KeyOrigin.imported);
    await tester.runAsync(() => app.container.read(vaultControllerProvider.notifier).addKey(key));
    // The toast that says so would lie over the bottom of a sheet. Its timer
    // was started from real time, where no pump reaches it: it is sent away
    await tester.pump();
    hideToast();
    await tester.pumpAndSettle();
    return key;
  }

  /// Puts [contact] among the other people's keys the vault keeps, its
  /// check as it is.
  Future<void> addContact(Contact contact) async {
    await tester.runAsync(() => app.container.read(vaultControllerProvider.notifier).addContact(contact));
    await tester.pump();
    hideToast();
    await tester.pumpAndSettle();
  }

  /// Takes away the toast on screen, if there is one.
  void hideToast() => (tester.state(find.byType(ToastHost)) as ToastController).hide();

  /// Lets real async work (the crypto, the files) finish.
  Future<void> settle([int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tap(Finder finder) async {
    await tapOn(tester, finder);
    await settle();
  }

  /// Opens one of the four sheets from the Vault tab's Keys filter.
  Future<void> open(String action) async {
    if (find.text(t('pgp.action.$action')).evaluate().isEmpty) await tapOn(tester, find.text(t('vault.filter.keys')));
    await tap(find.text(t('pgp.action.$action')));
  }

  /// Closes the sheet on top by tapping the scrim above it.
  Future<void> closeSheet() async {
    await tester.tapAt(const Offset(20, 20));
    await settle();
  }

  Future<void> enter(String label, String text) async {
    await tester.enterText(find.widgetWithText(TextField, label), text);
    await tester.pump();
  }

  /// Types into the passphrase prompt and continues.
  Future<void> answerPassphrase(String passphrase) async {
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), passphrase);
    await tester.pump();
    await tap(find.descendant(of: find.byType(Dialog), matching: find.text(t('pgp.passphrase.continue'))));
  }

  /// The names of the directories the jobs left under the temporary root.
  List<String> get tempEntries => tempRoot.existsSync() ? [for (final e in tempRoot.listSync(recursive: true)) e.path] : const [];

  PgpJobController get jobs => app.container.read(pgpJobControllerProvider.notifier);
}

/// Decrypts [message] on the test's isolate with the fixture [keys] given
/// by short name.
Future<pgp.PgpDecrypted> decryptWith(
  WidgetTester tester,
  Uint8List message, {
  List<String> keys = const [],
  String? passphrase,
  List<String> verifiers = const [],
}) async {
  Future<Uint8List> secret(String name) async => (await crypto.readPrivateKey(fixtureBytes(fixtureKeys[name]!.$1))).private;
  // An error thrown inside runAsync is reported as the test's own; it is
  // carried out and thrown here instead, for the caller to expect
  pgp.PgpException? error;
  final result = await tester.runAsync(() async {
    try {
      return await pgp.decrypt(
        data: pgp.PgpData.bytes(message),
        keys: [for (final key in keys) pgp.PgpSecretKey(await secret(key), passphrase: fixturePassphrase)],
        passphrase: passphrase,
        verifiers: [for (final key in verifiers) await secret(key)],
        now: testNow,
      );
    } on pgp.PgpException catch (e) {
      error = e;
      return null;
    }
  });
  if (error != null) throw error!;
  return result!;
}

/// What is found inside the sheet of type [T]: the Vault tab under a
/// sheet is still there, with its own key names.
Finder inSheet<T extends Widget>(Finder finder) => find.descendant(of: find.byType(T), matching: finder);
