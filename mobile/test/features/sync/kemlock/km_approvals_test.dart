import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/sealed_box.dart';
import 'package:kemlock/features/generator/word_list.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_approvals.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_phrase.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/kemlock/km_signin.dart';

import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';

final _words = parseWordList(File('assets/data/eff_large_wordlist.txt').readAsStringSync());
const _device = KmDeviceInfo(name: 'Firefox on Linux', kind: 'kemlock-web');

late KmTestAccount _test;

KmAccount _account() => KmAccount(
  accountId: _test.userId,
  keyVersion: 1,
  rootKey: _test.root,
  kx1PrivateKey: _test.kx1.privateKey,
  sig1PrivateKey: _test.sig1.privateKey,
  kx1PublicKey: _test.kx1.publicKey,
  sig1PublicKey: _test.sig1.publicKey,
  opaqueEnrolled: true,
);

/// A fake clock the wait advances itself, so 15 minutes pass at once.
class _Clock {
  var now = DateTime.utc(2026, 11, 22, 9);

  DateTime call() => now;
}

FakeKemlockAccountServer _server(_Clock clock) => FakeKemlockAccountServer(userId: _test.userId)
  ..approvalWords = _words
  ..approvalNow = clock.call;

/// The one-time public key of a new device, standing for the key it made.
Uint8List _key(int value) => Uint8List.fromList(List.filled(1600, value));

/// An open phone: a session bound to its own key, over the fake server.
({KmApprovals approvals, KmConnection connection}) _openPhone(FakeKemlockAccountServer server, _Clock clock, {bool owner = true}) {
  final key = SoftwareDeviceKey.generate();
  final tokens = server.issueTokens(FakeKemlockServer.thumbprint(key.publicJwk));
  final api = KmApi(server.client, proofs: KmDpop(key));
  final connection = KmConnection(
    api: api,
    server: FakeKemlockServer.url,
    session: KmSession(
      userId: _test.userId,
      deviceId: FakeKemlockServer.deviceId,
      tokens: KmTokens(
        access: tokens['accessToken']! as String,
        refresh: tokens['refreshToken']! as String,
        accessExpiresAt: 1 << 50,
        refreshExpiresAt: 1 << 50,
      ),
    ),
    save: (_) async {},
  );
  final approvals = KmApprovals(
    auth: KmAuthApi(api),
    connection: connection,
    words: _words,
    account: _account(),
    ownerCheck: (reason) async => owner,
    clock: clock.call,
  );
  return (approvals: approvals, connection: connection);
}

/// A request made by another device with the one-time public key [publicKey].
FakeApproval _request(FakeKemlockAccountServer server, Uint8List publicKey, {DateTime? at, String? phrase}) {
  final id = 'b0000000-0000-4000-8000-${(server.approvals.length + 1).toString().padLeft(12, '0')}';
  return server.approvals[id] = FakeApproval(
    id: id,
    publicKey: publicKey,
    jkt: 'other-device',
    deviceName: 'Firefox on Linux',
    createdAt: at ?? server.approvalNow(),
    phrase: phrase ?? approvalPhrase(publicKey, _words),
  );
}

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create('00000000-0000-4000-8000-000000000001');
  });

  group('the open phone', () {
    test('lists a request with the phrase it computed itself, and the server\'s words agreeing', () async {
      final clock = _Clock();
      final server = _server(clock);
      _request(server, _key(1));
      final list = await _openPhone(server, clock).approvals.pending();
      expect(list, hasLength(1));
      expect(list.single.phrase, 'slurp series primary ruined afraid', reason: 'the words of the all-1s key, from hand-derived vectors');
      expect(list.single.serverPhraseAgrees, isTrue);
      expect(list.single.canApprove, isTrue);
      expect(list.single.request.deviceName, 'Firefox on Linux');
    });

    test('drops requests older than 15 minutes, and shows the newest first', () async {
      final clock = _Clock();
      final server = _server(clock);
      _request(server, _key(1), at: clock.now.subtract(const Duration(minutes: 16)));
      _request(server, _key(2), at: clock.now.subtract(const Duration(minutes: 5)));
      _request(server, _key(3), at: clock.now.subtract(const Duration(minutes: 1)));
      final list = await _openPhone(server, clock).approvals.pending();
      expect(list.map((p) => p.age.inMinutes), [1, 5]);
    });

    test('a server whose words differ from the computed ones can\'t be approved, and nothing is sent', () async {
      final clock = _Clock();
      final server = _server(clock);
      final request = _request(server, _key(1), phrase: 'alpha bravo charlie delta echo');
      final phone = _openPhone(server, clock);
      final pending = (await phone.approvals.pending()).single;
      expect(pending.serverPhraseAgrees, isFalse);
      expect(pending.phrase, isNot('alpha bravo charlie delta echo'), reason: 'the server\'s words are never the ones shown');
      await expectLater(
        phone.approvals.approve(pending, reason: 'approve'),
        throwsA(isA<KmApprovalError>().having((e) => e.issue, 'issue', KmApprovalIssue.phraseMismatch)),
      );
      expect(server.answers, isEmpty);
      expect(request.status, 'pending');
    });

    test('a server that hands out no public key can\'t be approved from yet', () async {
      final clock = _Clock();
      final server = _server(clock)..hidePublicKey = true;
      _request(server, _key(1));
      final phone = _openPhone(server, clock);
      final pending = (await phone.approvals.pending()).single;
      expect(pending.phrase, isNull);
      await expectLater(
        phone.approvals.approve(pending, reason: 'approve'),
        throwsA(isA<KmApprovalError>().having((e) => e.issue, 'issue', KmApprovalIssue.noKey)),
      );
    });

    test('Approve asks the owner first, and without it seals nothing and sends nothing', () async {
      final clock = _Clock();
      final server = _server(clock);
      _request(server, _key(1));
      final phone = _openPhone(server, clock, owner: false);
      await expectLater(
        phone.approvals.approve((await phone.approvals.pending()).single, reason: 'approve'),
        throwsA(isA<KmApprovalError>().having((e) => e.issue, 'issue', KmApprovalIssue.ownerCheck)),
      );
      expect(server.answers, isEmpty);
    });

    test('Approve sends a blob only the request\'s key opens, holding the root key', () async {
      final clock = _Clock();
      final server = _server(clock);
      // A real one-time key pair, so the blob can be opened as the new device would
      final pair = await Kx1.generate();
      final request = _request(server, pair.publicKey);
      final phone = _openPhone(server, clock);
      await phone.approvals.approve((await phone.approvals.pending()).single, reason: 'approve');
      expect(server.answers.single['decision'], 'approve');
      expect(request.status, 'approved');
      final aad = approvalAad(_test.userId, request.id);
      final opened = await openBox(request.sealedKey!, pair.privateKey, context: SealContext.deviceApproval, aad: aad);
      expect(opened, _test.root);
      expect(aad, [...uuidBytes(_test.userId), ...uuidBytes(request.id)], reason: 'account id then request id, 32 bytes');
      // Another key, another context, no binding, or another request's binding opens nothing
      final other = await Kx1.generate();
      await expectLater(
        openBox(request.sealedKey!, other.privateKey, context: SealContext.deviceApproval, aad: aad),
        throwsA(isA<CorruptedException>()),
      );
      await expectLater(
        openBox(request.sealedKey!, pair.privateKey, context: SealContext.spaceKey, aad: aad),
        throwsA(isA<CorruptedException>()),
      );
      await expectLater(
        openBox(request.sealedKey!, pair.privateKey, context: SealContext.deviceApproval),
        throwsA(isA<CorruptedException>()),
      );
      await expectLater(
        openBox(
          request.sealedKey!,
          pair.privateKey,
          context: SealContext.deviceApproval,
          aad: approvalAad(_test.userId, '00000000-0000-4000-8000-0000000000ff'),
        ),
        throwsA(isA<CorruptedException>()),
      );
    });

    test('Deny sends no key', () async {
      final clock = _Clock();
      final server = _server(clock);
      final request = _request(server, _key(1));
      final phone = _openPhone(server, clock);
      await phone.approvals.deny((await phone.approvals.pending()).single);
      expect(server.answers.single, {'decision': 'deny'});
      expect(request.status, 'denied');
      expect(request.sealedKey, isNull);
    });
  });

  group('the new phone', () {
    ({KmApprovalFlow flow, FakeKemlockAccountServer server, _Clock clock, Future<void> Function(Duration) delay}) rig({
      Duration? approveAt,
      String? phraseOverride,
      bool deny = false,
      Duration interval = approvalPollInterval,
    }) {
      final clock = _Clock();
      final server = _server(clock)..phraseOverride = phraseOverride;
      server.material = _test.material();
      final key = SoftwareDeviceKey.generate();
      final signIn = KmSignIn(
        api: KmApi(server.client, proofs: KmDpop(key)),
        server: FakeKemlockServer.url,
        device: _device,
        opaque: FakeKmOpaque(),
        argon2: cheapArgon2,
      );
      final start = clock.now;
      Future<void> delay(Duration d) async {
        clock.now = clock.now.add(d);
        // An open phone answers once its time has come
        if (approveAt != null && clock.now.difference(start) >= approveAt) {
          final request = server.approvals.values.single;
          if (request.status == 'pending') {
            if (deny) {
              request.status = 'denied';
            } else {
              request
                ..status = 'approved'
                ..sealedKey = await sealBox(
                  request.publicKey,
                  _test.root,
                  context: SealContext.deviceApproval,
                  aad: approvalAad(_test.userId, request.id),
                );
            }
          }
        }
      }

      return (
        flow: KmApprovalFlow(signIn, words: _words, clock: clock.call, delay: delay, interval: interval, accountId: _test.userId),
        server: server,
        clock: clock,
        delay: delay,
      );
    }

    test('shows its own phrase, computed from its own key, and the server\'s words agree', () async {
      final (:flow, :server, clock: _, delay: _) = rig();
      final phrase = await flow.start('me@example.com');
      final request = server.approvals.values.single;
      expect(phrase, approvalPhrase(request.publicKey, _words));
      expect(flow.phrase, phrase);
      expect(request.deviceName, 'Firefox on Linux');
    });

    test('a server whose words differ stops the request before anyone is asked', () async {
      final (:flow, server: _, clock: _, delay: _) = rig(phraseOverride: 'alpha bravo charlie delta echo');
      await expectLater(
        flow.start('me@example.com'),
        throwsA(isA<KmApprovalError>().having((e) => e.issue, 'issue', KmApprovalIssue.phraseMismatch)),
      );
      expect(flow.phrase, isNull);
    });

    test('an answer at 40 seconds opens the account, with polls every 2 seconds', () async {
      final (:flow, :server, :clock, delay: _) = rig(approveAt: const Duration(seconds: 40));
      final started = clock.now;
      await flow.start('me@example.com');
      final outcome = await flow.wait();
      final approved = outcome as KmApproved;
      expect(approved.signedIn.account!.rootKey, _test.root);
      expect(approved.signedIn.session.userId, server.userId);
      expect(clock.now.difference(started), const Duration(seconds: 40));
      expect(server.polls, 21, reason: 'a poll at 0 s and then every 2 s up to the answer at 40 s');
    });

    test('no answer in 15 minutes ends with the other ways offered, and no sign-in is attempted', () async {
      // Polled every 30 s here, to keep the fake HTTP exchanges few; the 2 s interval is checked above
      final (:flow, :server, :clock, delay: _) = rig(interval: const Duration(seconds: 30));
      final started = clock.now;
      await flow.start('me@example.com');
      expect(await flow.wait(), isA<KmApprovalTimedOut>());
      expect(clock.now.difference(started), approvalLifetime);
      expect(server.requests.where((r) => r.url.path.endsWith('/auth/device/challenge')), isEmpty);
    });

    test('a denial ends the wait', () async {
      final (:flow, server: _, clock: _, delay: _) = rig(approveAt: const Duration(seconds: 10), deny: true);
      await flow.start('me@example.com');
      expect(await flow.wait(), isA<KmApprovalDenied>());
    });

    test('Cancel ends the wait at its next turn', () async {
      final (:flow, :server, clock: _, delay: _) = rig();
      await flow.start('me@example.com');
      flow.cancel();
      expect(await flow.wait(), isA<KmApprovalTimedOut>());
      expect(server.polls, 0);
    });

    test('an approval sealed to another key doesn\'t open, and the phone is not signed in', () async {
      final (:flow, :server, clock: _, delay: _) = rig();
      // The open phone sealed to a key that isn't the one this phone made
      await flow.start('me@example.com');
      final request = server.approvals.values.single;
      final wrong = await Kx1.generate();
      request
        ..status = 'approved'
        ..sealedKey = await sealBox(
          wrong.publicKey,
          _test.root,
          context: SealContext.deviceApproval,
          aad: approvalAad(_test.userId, request.id),
        );
      await expectLater(flow.wait(), throwsA(isA<KmSignInError>().having((e) => e.issue, 'issue', KmSignInIssue.unreadable)));
    });
  });
}
