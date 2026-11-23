// Approving another device, and failing over, against a real Kemlock Server (see server_kit.dart). Skipped unless
// KEMLOCK_URL is set.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/ids.dart';
import 'package:kemlock/features/generator/word_list.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_approvals.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_failover.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_signin.dart';
import 'package:kemlock/features/sync/sync_merge.dart';

import 'server_kit.dart';

final _words = parseWordList(File('assets/data/eff_large_wordlist.txt').readAsStringSync());

void main() {
  test('a new phone asks, the open phone approves with the same words, and the new phone opens the account', () async {
    final open = await signInPhone();
    final target = open.target;

    // The new phone: its own device key, and an approval request with its one-time key
    final key = SoftwareDeviceKey.generate();
    final client = clientFor(serverPin);
    addTearDown(client.close);
    final signIn = KmSignIn(
      api: KmApi(client, proofs: KmDpop(key)),
      server: serverUrl!,
      device: KmDeviceInfo(name: 'Kemlock tests (new phone)', kind: 'kemlock-android', id: newUuid()),
      opaque: OpaqueKmOpaque(),
      deviceKey: const {'protection': 'software'},
    );
    await signIn.ways(email);
    final flow = KmApprovalFlow(signIn, words: _words, accountId: open.signedIn.session.userId);
    final phrase = await flow.start(email);
    final outcome = flow.wait();

    // The open phone lists it with the phrase it computes itself, and approves
    await open.host().withAccount(target, (connection, account) async {
      final approvals = KmApprovals(
        auth: KmAuthApi(connection.api),
        connection: connection,
        words: _words,
        account: account,
        ownerCheck: (_) async => true,
      );
      final pending = (await approvals.pending()).firstWhere((request) => request.request.id == flow.requestId);
      expect(pending.phrase, phrase, reason: 'both phones compute the same words from the one-time key');
      await approvals.approve(pending, reason: 'a test');
    });

    final result = await outcome.timeout(const Duration(minutes: 2));
    expect(result, isA<KmApproved>());
    expect((result as KmApproved).signedIn.account, isNotNull, reason: 'the sealed key opened the account');
  }, skip: skipServer);

  test('a request that is denied ends the wait with a refusal', () async {
    final open = await signInPhone();
    final key = SoftwareDeviceKey.generate();
    final client = clientFor(serverPin);
    addTearDown(client.close);
    final signIn = KmSignIn(
      api: KmApi(client, proofs: KmDpop(key)),
      server: serverUrl!,
      device: KmDeviceInfo(name: 'Kemlock tests (denied)', kind: 'kemlock-android', id: newUuid()),
      opaque: OpaqueKmOpaque(),
      deviceKey: const {'protection': 'software'},
    );
    await signIn.ways(email);
    final flow = KmApprovalFlow(signIn, words: _words, accountId: open.signedIn.session.userId);
    await flow.start(email);
    final outcome = flow.wait();

    await open.host().withAccount(open.target, (connection, account) async {
      final approvals = KmApprovals(
        auth: KmAuthApi(connection.api),
        connection: connection,
        words: _words,
        account: account,
        ownerCheck: (_) async => true,
      );
      final pending = (await approvals.pending()).firstWhere((request) => request.request.id == flow.requestId);
      await approvals.deny(pending);
    });

    expect(await outcome.timeout(const Duration(minutes: 2)), isA<KmApprovalDenied>());
  }, skip: skipServer);

  test('fails over when the home is down: the phone signs in on the replica with its device key and syncs there', () async {
    final phone = await signInPhone();
    final mine = testAccount('failover');
    phone.lists = Lists(accounts: [...phone.lists.accounts, mine]);
    await phone.sync();

    // The home is the server as the phone was set up with it, reached through a pin the stopped client below
    // recognises; the replica is the replica of KEMLOCK_REPLICA_URL, or the same server by its other route
    const downPin = 'DE:AD:BE:EF';
    final replica = replicaUrl;
    final target = KemlockTarget(
      accountId: phone.target.accountId,
      email: email,
      servers: [
        KemlockServer(url: serverUrl.toString(), pin: downPin),
        KemlockServer(url: replica.toString(), role: KemlockServer.replica, pin: replicaPin),
      ],
      deviceId: phone.target.deviceId,
    );
    final away = <KmAway?>[];
    final host = phone.host(clients: (pin) => pin == downPin ? DownClient() : clientFor(pin), onAway: away.add);

    final result = await phone.sync(to: target, through: host);

    expect(away.last, isNotNull, reason: 'the phone says it is away from its home');
    expect(away.last!.using.url, replica.toString());
    expect(result.doc.accounts.where((account) => account.id == mine.id), hasLength(1), reason: 'the run went on, on the replica');

    // Clean up through the real home again
    phone.lists = Lists(
      accounts: [
        for (final account in phone.lists.accounts)
          if (account.id != mine.id) account,
      ],
    );
    await phone.sync();
  }, skip: skipServer);

  test('a home that answers again takes the phone back after five healthy minutes', () async {
    // A real five minutes is a long test, so this one belongs to the fake clock of km_failover_test.dart; here the
    // server is only asked that its config still answers, which is what the check reads.
    final phone = await signInPhone();
    final api = KmApi(clientFor(serverPin), proofs: phone.proofs);

    final config = await api.config(serverUrl!);

    expect(config.serverId, isNotEmpty);
  }, skip: skipServer);
}
