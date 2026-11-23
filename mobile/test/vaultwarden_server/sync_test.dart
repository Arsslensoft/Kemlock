// Vaultwarden sync from end to end against a real server (see
// server_kit.dart): setup through VwAccountSetup with the account's real
// KDF, two phones syncing sealed and plain homes through the real engine,
// and, with BW_CLI set, the official Bitwarden CLI reading a plain login's
// code and editing it, and Kemlock taking the edit.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_formats.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_store.dart' show deriveVaultKey;

import 'server_kit.dart';

const _github = OtpAccount(id: 'a1', issuer: 'GitHub', label: 'me@example.com', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
const _bank = OtpAccount(id: 'a2', type: OtpType.hotp, issuer: 'Bank', label: '', secret: 'KRSXG5CTMVRXEZLU', counter: 3, addedAt: 1);
const _codes = BackupService(
  id: 's1',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'aaaa-1111')],
  addedAt: 1,
);

/// A phone: its own client, session, entries and state, syncing with [target].
class _Phone {
  _Phone(this.client, this.credentials, this.target);

  final http.Client client;
  VwCredentials credentials;
  final VaultwardenTarget target;
  late final reader = VwReader(credentials.key);
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);

  Future<void> sync() async {
    final connection = VwConnection(
      api: VwApi(client),
      server: serverUrl!,
      credentials: credentials,
      onCredentials: (next) async => credentials = next,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = await VaultwardenScopeSync(connection: connection, reader: reader, target: target).sync(lists, state, now: now);
    lists = applyScope(lists, null, result.doc);
    state = ScopeState(known: result.known, lastSyncAt: now, extra: result.state);
  }
}

Future<(VwAccountSetup, VwCredentials)> _signIn(http.Client client, TestAccount account) async {
  final setup = VwAccountSetup(VwApi(client));
  await setup.connect(serverUrl.toString(), account.email);
  final done = await setup.signIn(account.password, deviceId: testDevice().id) as VwSignInDone;
  return (setup, done.credentials);
}

void main() {
  late http.Client client;
  setUp(() => client = serverClient());
  tearDown(() => client.close());

  for (final mode in VaultwardenMode.values) {
    test(
      '${mode.name}: two phones sync through the real engine',
      () async {
        final account = await registerAccount(client, kdf: cheapArgon2id);
        final (setup, credentials) = await _signIn(client, account);
        final target = await setup.createHome(
          setup.connection(credentials),
          mode: mode,
          passphrase: mode == VaultwardenMode.sealed ? 'a long sealing phrase' : null,
          derive: deriveVaultKey,
        );
        final a = _Phone(client, credentials, target)..lists = const Lists(accounts: [_github, _bank], backupServices: [_codes]);
        await a.sync();

        // The second phone joins the home found in the vault, with the passphrase
        final (setup2, credentials2) = await _signIn(client, account);
        final info = await setup2.readVault(setup2.connection(credentials2));
        expect(info.homes.single.entries, 3);
        final joined = await setup2.joinHome(
          info.homes.single,
          passphrase: mode == VaultwardenMode.sealed ? 'a long sealing phrase' : null,
          derive: deriveVaultKey,
        );
        final b = _Phone(client, credentials2, joined);
        await b.sync();
        expect([for (final x in b.lists.accounts) x.id]..sort(), ['a1', 'a2']);
        expect(b.lists.backupServices.single.codes.single.code, 'aaaa-1111');

        // An edit on B, a deletion on A, an HOTP counter on both
        b.lists = Lists(
          accounts: [
            for (final x in b.lists.accounts)
              x.id == 'a1' ? x.copyWith(issuer: 'GitHub (work)', updatedAt: DateTime.now().millisecondsSinceEpoch) : x,
          ],
          backupServices: b.lists.backupServices,
        );
        await b.sync();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        a.lists = Lists(
          accounts: [
            for (final x in a.lists.accounts)
              if (x.id == 'a2') x.copyWith(counter: 9, updatedAt: DateTime.now().millisecondsSinceEpoch) else x,
          ],
        );
        await a.sync();
        await b.sync();
        await a.sync();

        for (final phone in [a, b]) {
          expect(phone.lists.accounts.firstWhere((x) => x.id == 'a1').issuer, 'GitHub (work)');
          expect(phone.lists.accounts.firstWhere((x) => x.id == 'a2').counter, 9);
          expect(phone.lists.backupServices, isEmpty);
        }
      },
      skip: skipServer,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'plain: the Bitwarden CLI makes the same code, and Kemlock takes its edit',
    () async {
      final account = await registerAccount(client);
      final (setup, credentials) = await _signIn(client, account);
      final target = await setup.createHome(setup.connection(credentials), mode: VaultwardenMode.plain);
      final phone = _Phone(client, credentials, target)..lists = const Lists(accounts: [_github]);
      await phone.sync();

      final ciphers = await setup.connection(credentials).ciphers();
      final reader = VwReader(credentials.key);
      final login = (await reader.read(ciphers, home: target.home)).entries.single.cipher.id;

      final dir = await Directory.systemTemp.createTemp('kemlock-bw-');
      Future<String> bw(List<String> args, {String? session, String? stdin}) async {
        final process = await Process.start(
          Platform.environment['BW_CLI']!,
          [
            ...args,
            if (session != null) ...['--session', session],
          ],
          environment: {'BITWARDENCLI_APPDATA_DIR': dir.path, 'BW_NOINTERACTION': 'true'},
        );
        if (stdin != null) process.stdin.write(stdin);
        await process.stdin.close();
        final out = await process.stdout.transform(utf8.decoder).join();
        await process.stderr.drain<void>();
        if (await process.exitCode != 0) throw StateError('bw ${args.first} failed: $out');
        return out.trim();
      }

      try {
        await bw(['config', 'server', serverUrl.toString()]);
        final session = await bw(['login', account.email, account.password, '--raw']);
        final before = codeAt(_github, DateTime.now().millisecondsSinceEpoch ~/ 1000);
        final theirs = await bw(['get', 'totp', login], session: session);
        final after = codeAt(_github, DateTime.now().millisecondsSinceEpoch ~/ 1000);
        expect(theirs, anyOf(before, after));

        // The CLI renames the login and changes its code
        final item = jsonDecode(await bw(['get', 'item', login], session: session)) as Map<String, Object?>;
        final edited = {
          ...item,
          'name': 'GitHub (renamed in Bitwarden)',
          'login': {...item['login']! as Map<String, Object?>, 'totp': 'KRSXG5CTMVRXEZLU'},
        };
        await bw([
          'edit',
          'item',
          login,
          await bw(['encode'], stdin: jsonEncode(edited)),
        ], session: session);

        await phone.sync();
        final synced = phone.lists.accounts.single;
        expect(
          (synced.id, synced.issuer, synced.secret, synced.label),
          ('a1', 'GitHub (renamed in Bitwarden)', 'KRSXG5CTMVRXEZLU', 'me@example.com'),
        );
        // The CLI kept Kemlock's field
        final field = await reader.read(await setup.connection(credentials).ciphers(), home: target.home);
        expect(field.entries.single.id, 'a1');
        expect(fieldName, 'Kemlock');
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: skipServer ?? (Platform.environment['BW_CLI'] == null ? 'Set BW_CLI' : null),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
