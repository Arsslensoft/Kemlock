// The approving phone's sheet (add-kemlock-server-sync, task 9.2): the five
// words it computes from the request's one-time key, Approve sealing the root
// key to that key after the owner check, Deny sending none, and the warning
// when the words can't be trusted.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/sealed_box.dart';
import 'package:kemlock/features/generator/word_list.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_phrase.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/kemlock_approval.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/vault/owner_check.dart';

import '../../../helpers/test_app.dart';
import '../sync_screen_kit.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';

final _words = parseWordList(File('assets/data/eff_large_wordlist.txt').readAsStringSync());

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: FakeKemlockServer.deviceId,
);

class _Values implements KmVaultValues {
  final values = <String, Object?>{};

  @override
  Future<Object?> load(String key) async => values[key] == null ? null : jsonDecode(jsonEncode(values[key]));

  @override
  Future<void> save(String key, Object? value) async => values[key] = jsonDecode(jsonEncode(value));

  @override
  void remove(String key) => values.remove(key);
}

class _Holder extends KemlockHostHolder {
  _Holder(this.host);

  final KmHost host;

  @override
  KmHost? build() => host;
}

late KmTestAccount _test;

Uint8List _key(int value) => Uint8List.fromList(List.filled(1600, value));

/// A phone whose account has a request from another device with the one-time key [publicKey], its sheet's page open.
Future<({SyncSheetKit kit, FakeKemlockAccountServer server, List<String> asked})> _open(
  WidgetTester tester, {
  required Uint8List publicKey,
  String? serverPhrase,
  bool owner = true,
  bool hideKey = false,
}) async {
  final server = FakeKemlockAccountServer(userId: _test.userId)
    ..approvalWords = _words
    ..hidePublicKey = hideKey;
  final id = 'b0000000-0000-4000-8000-000000000001';
  server.approvals[id] = FakeApproval(
    id: id,
    publicKey: publicKey,
    jkt: 'other-device',
    deviceName: 'Firefox on Linux',
    createdAt: DateTime.now(),
    phrase: serverPhrase ?? approvalPhrase(publicKey, _words),
  );
  final key = SoftwareDeviceKey.generate();
  final tokens = server.issueTokens(FakeKemlockServer.thumbprint(key.publicJwk));
  final values = _Values();
  await values.save(
    keyKemlockSession,
    KmSession(
      userId: _test.userId,
      deviceId: FakeKemlockServer.deviceId,
      tokens: KmTokens(
        access: tokens['accessToken']! as String,
        refresh: tokens['refreshToken']! as String,
        accessExpiresAt: 1 << 50,
        refreshExpiresAt: 1 << 50,
      ),
      deviceKey: const {'protection': 'software'},
    ).toJson(),
  );
  await values.save(
    keyKemlockAccount,
    KmAccount(
      accountId: _test.userId,
      keyVersion: 1,
      rootKey: _test.root,
      kx1PrivateKey: _test.kx1.privateKey,
      sig1PrivateKey: _test.sig1.privateKey,
      kx1PublicKey: _test.kx1.publicKey,
      sig1PublicKey: _test.sig1.publicKey,
      opaqueEnrolled: true,
    ).toJson(),
  );
  final host = KmHost(values: values, clientFor: (pin) => server.client, proofsFor: (session) async => KmDpop(key));
  final asked = <String>[];
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    (context) => showKemlockApproval(context, kit.container.read(kemlockApprovalsProvider).first),
    overrides: [
      kemlockHostProvider.overrideWith(() => _Holder(host)),
      wordListProvider.overrideWith((ref) => _words),
      ownerCheckProvider.overrideWithValue((context, ref, reason) async {
        asked.add(reason);
        return owner;
      }),
    ],
  );
  await kit.save(const SyncSettings(kemlock: _target));
  await kit.container.read(kemlockApprovalsProvider.notifier).refresh();
  await kit.open(tester);
  return (kit: kit, server: server, asked: asked);
}

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create('00000000-0000-4000-8000-000000000001');
  });

  testWidgets('shows who asks, from where, and the five words computed here from the request\'s key', (tester) async {
    await _open(tester, publicKey: _key(1));

    expect(find.text(t('kemlock.approval.title', {'device': 'Firefox on Linux'})), findsOneWidget);
    expect(find.text(t('kemlock.approval.words', {'words': 'slurp series primary ruined afraid'})), findsOneWidget);
    expect(find.text(t('kemlock.approval.differ')), findsOneWidget);
    expect(button(tester, t('kemlock.approval.approve')).onPressed, isNotNull);
  });

  testWidgets('Approve asks the owner, then sends only the root key sealed to the request\'s key', (tester) async {
    final opened = await _open(tester, publicKey: _key(1));

    await tapButton(tester, t('kemlock.approval.approve'));

    expect(opened.asked, [t('kemlock.approval.reason')]);
    final answer = opened.server.answers.single;
    expect(answer['decision'], 'approve');
    expect(answer.keys.toSet(), {'decision', 'sealedKey'});
    expect(find.text(t('kemlock.approval.title', {'device': 'Firefox on Linux'})), findsNothing, reason: 'the sheet closed');
    expect(opened.kit.container.read(kemlockApprovalsProvider), isEmpty);
    expect(sealedBoxMinimumLengthOf(answer['sealedKey']! as String), greaterThan(0));
  });

  testWidgets('Approve does nothing when the owner doesn\'t show it is them', (tester) async {
    final opened = await _open(tester, publicKey: _key(1), owner: false);

    await tapButton(tester, t('kemlock.approval.approve'));

    expect(opened.server.answers, isEmpty);
    expect(find.text(t('kemlock.approval.problem.ownerCheck')), findsOneWidget);
  });

  testWidgets('Deny sends a refusal that carries no key', (tester) async {
    final opened = await _open(tester, publicKey: _key(1));

    await tapButton(tester, t('kemlock.approval.deny'));

    expect(opened.server.answers.single, {'decision': 'deny'});
    expect(opened.asked, isEmpty, reason: 'a refusal needs no owner check');
  });

  testWidgets('words from the server that differ from the computed ones say to deny, and Approve is off', (tester) async {
    await _open(tester, publicKey: _key(1), serverPhrase: 'alpha bravo charlie delta echo');

    expect(find.text(t('kemlock.approval.problem.phraseMismatch')), findsOneWidget);
    expect(button(tester, t('kemlock.approval.approve')).onPressed, isNull);
    expect(button(tester, t('kemlock.approval.deny')).onPressed, isNotNull);
    expect(find.textContaining('alpha bravo'), findsNothing, reason: 'the server\'s words are never shown');
  });

  testWidgets('a server that sends no key can\'t be approved from here yet, and can be denied', (tester) async {
    await _open(tester, publicKey: _key(1), hideKey: true);

    expect(find.text(t('kemlock.approval.problem.noKey')), findsOneWidget);
    expect(button(tester, t('kemlock.approval.approve')).onPressed, isNull);
    expect(button(tester, t('kemlock.approval.deny')).onPressed, isNotNull);
  });
}

/// The length of the sealed box [text] decodes to, to see something real was sent.
int sealedBoxMinimumLengthOf(String text) => base64Url.decode(base64Url.normalize(text)).length - sealedBoxMinimumLength;
