// Writes test/fixtures/vaultwarden/account-<kdf>.json: an account made on a
// real Vaultwarden, its prelogin and sign-in answers and its vault as
// /api/sync gives it, holding items the official Bitwarden CLI made, and
// what each item holds in the clear. The crypto tests open these, so they
// check Kemlock against Bitwarden's own code without a server.
//
// Runs only when asked, against a server and the CLI as in
// bitwarden_cli_test.dart:
//
//   WRITE_VAULTWARDEN_FIXTURES=1 VAULTWARDEN_URL=… BW_CLI=… \
//     flutter test test/vaultwarden_server/make_fixtures_test.dart
//
// The fixtures were made once; don't write them again, as the tests pin
// what they hold.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';

import 'server_kit.dart';

String? get _skip => Platform.environment['WRITE_VAULTWARDEN_FIXTURES'] == '1'
    ? skipServer ?? (Platform.environment['BW_CLI'] == null ? 'Set BW_CLI' : null)
    : 'Set WRITE_VAULTWARDEN_FIXTURES=1 to write the fixtures';

/// The items the CLI makes, as `bw create item` takes them.
const _items = [
  {
    'type': 1,
    'name': 'GitHub',
    'notes': 'Recovery codes are in the safe.',
    'favorite': true,
    'fields': [
      {'name': 'Text field', 'value': 'visible', 'type': 0},
      {'name': 'Hidden field', 'value': 'hidden value', 'type': 1},
    ],
    'login': {
      'username': 'me@example.com',
      'password': 'hunter2',
      'totp': 'otpauth://totp/GitHub:me%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA256&digits=8&period=30',
      'uris': [
        {'uri': 'https://github.com', 'match': null},
      ],
    },
    'reprompt': 0,
  },
  {
    'type': 1,
    'name': 'Steam',
    'notes': null,
    'favorite': false,
    'login': {'username': 'gamer', 'password': null, 'totp': 'steam://GEZDGNBVGY3TQOJQ', 'uris': <Object?>[]},
    'reprompt': 0,
  },
  {
    'type': 1,
    'name': 'Bare secret',
    'notes': 'Ünïcödé ✓ 🔐',
    'favorite': false,
    'login': {'username': '', 'password': 'pw', 'totp': 'KRSXG5CTMVRXEZLUKN2XAZLSKNSWG4TFOQ', 'uris': <Object?>[]},
    'reprompt': 1,
  },
  {
    'type': 2,
    'name': 'A note',
    'notes': 'Just a note.',
    'favorite': false,
    'secureNote': {'type': 0},
    'reprompt': 0,
  },
];

void main() {
  for (final (name, kdf) in [
    ('pbkdf2', const BwKdf(type: BwKdfType.pbkdf2, iterations: 600000)),
    ('argon2id', const BwKdf(type: BwKdfType.argon2id, iterations: 3, memory: 64, parallelism: 4)),
  ]) {
    test(
      'writes the $name account',
      () async {
        final client = serverClient();
        final api = VwApi(client);
        final account = await registerAccount(client, kdf: kdf);
        final cli = await Directory.systemTemp.createTemp('kemlock-bw-');
        Future<String> bw(List<String> args, {String? session, String? stdin}) async {
          final process = await Process.start(
            Platform.environment['BW_CLI']!,
            [
              ...args,
              if (session != null) ...['--session', session],
            ],
            environment: {'BITWARDENCLI_APPDATA_DIR': cli.path, 'BW_NOINTERACTION': 'true'},
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
          final folder = jsonDecode(
            await bw([
              'create',
              'folder',
              await bw(['encode'], stdin: jsonEncode({'name': 'Kemlock'})),
            ], session: session),
          );
          final made = <Map<String, Object?>>[];
          for (final item in _items) {
            final encoded = await bw(['encode'], stdin: jsonEncode({...item, 'folderId': (folder as Map<String, Object?>)['id']}));
            made.add(jsonDecode(await bw(['create', 'item', encoded], session: session)) as Map<String, Object?>);
          }

          final prelogin = await client.post(
            serverUrl!.replace(path: '${serverUrl!.path}/identity/accounts/prelogin'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': account.email}),
          );
          final masterKey = await bwMasterKey(account.password, account.email, kdf);
          final token = await client.post(
            serverUrl!.replace(path: '${serverUrl!.path}/identity/connect/token'),
            body: {
              'grant_type': 'password',
              'username': account.email,
              'password': await bwMasterPasswordHash(masterKey, account.password),
              'scope': 'api offline_access',
              'client_id': 'mobile',
              'deviceType': '0',
              'deviceIdentifier': testDevice().id,
              'deviceName': 'Kemlock fixtures',
            },
          );
          final signedIn = jsonDecode(token.body) as Map<String, Object?>;
          final vault = await api.sync(serverUrl!, signedIn['access_token']! as String);

          const tokenKeys = {
            'Key',
            'PrivateKey',
            'Kdf',
            'KdfIterations',
            'KdfMemory',
            'KdfParallelism',
            'UserDecryptionOptions',
            'AccountKeys',
          };
          final fixture = {
            'about': 'Made on Vaultwarden 1.37.5 with the Bitwarden CLI 2026.6.0 by test/vaultwarden_server/make_fixtures_test.dart. Never regenerate.',
            'email': account.email,
            'password': account.password,
            'prelogin': jsonDecode(prelogin.body),
            'token': {
              for (final MapEntry(:key, :value) in signedIn.entries)
                if (tokenKeys.contains(key)) key: value,
            },
            'sync': {'profile': vault['profile'], 'folders': vault['folders'], 'ciphers': vault['ciphers']},
            'expected': {
              'folder': 'Kemlock',
              'items': [
                for (final (i, item) in _items.indexed) {...item, 'id': made[i]['id']},
              ],
            },
          };
          final out = File('test/fixtures/vaultwarden/account-$name.json');
          await out.parent.create(recursive: true);
          await out.writeAsString('${const JsonEncoder.withIndent('  ').convert(fixture)}\n');
        } finally {
          client.close();
          await cli.delete(recursive: true);
        }
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}
