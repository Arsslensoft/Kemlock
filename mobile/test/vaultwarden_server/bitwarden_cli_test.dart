// Items Kemlock writes open in the official Bitwarden CLI, and items the CLI
// writes open in Kemlock, so the crypto is checked against Bitwarden's own
// code and not only against itself. Runs when VAULTWARDEN_URL is set (see
// server_kit.dart) and BW_CLI is the path of a `bw` binary
// (`npm install @bitwarden/cli`); NODE_EXTRA_CA_CERTS should name the
// server's certificate when it's self-signed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/accounts/otpauth.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';

import 'server_kit.dart';

String? get _bw => Platform.environment['BW_CLI'];

String? get _skip => skipServer ?? (_bw == null || _bw!.isEmpty ? 'Set BW_CLI to the path of the Bitwarden CLI' : null);

/// The CLI, with its data in a folder of its own for this test.
class _Cli {
  _Cli(this.dir);

  final Directory dir;
  String? session;

  Future<String> run(List<String> args, {String? stdin}) async {
    final process = await Process.start(
      _bw!,
      [
        ...args,
        if (session != null) ...['--session', session!],
      ],
      environment: {'BITWARDENCLI_APPDATA_DIR': dir.path, 'BW_NOINTERACTION': 'true'},
    );
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    if (code != 0) throw StateError('bw ${args.first} failed ($code): $err $out');
    return out.trim();
  }
}

void main() {
  late http.Client client;
  late VwApi api;
  late _Cli cli;

  setUp(() async {
    client = serverClient();
    api = VwApi(client);
    cli = _Cli(await Directory.systemTemp.createTemp('kemlock-bw-'));
  });
  tearDown(() async {
    client.close();
    await cli.dir.delete(recursive: true);
  });

  test(
    'the CLI opens what Kemlock wrote, and Kemlock what the CLI wrote',
    () async {
      final account = await registerAccount(client);
      final masterKey = await bwMasterKey(account.password, account.email, account.kdf);
      final login = await api.signIn(
        serverUrl!,
        email: account.email,
        passwordHash: await bwMasterPasswordHash(masterKey, account.password),
        device: testDevice(),
      ) as VwSignedIn;
      final token = login.tokens.access;
      final key = await bwOpenUserKey(login.key!, masterKey);
      const uri = 'otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA256&digits=8&period=30';
      final ours = await api.createCipher(serverUrl!, token, {
        'type': 1,
        'name': await bwEncryptString('GitHub', key),
        'notes': await bwEncryptString('ünïcode note', key),
        'encryptedFor': login.userId,
        'fields': [
          {'type': 1, 'name': await bwEncryptString('Kemlock', key), 'value': await bwEncryptString('{"v":1}', key), 'linkedId': null},
        ],
        'login': {'username': await bwEncryptString('me', key), 'totp': await bwEncryptString(uri, key)},
      });

      await cli.run(['config', 'server', serverUrl.toString()]);
      cli.session = await cli.run(['login', account.email, account.password, '--raw']);

      final item = jsonDecode(await cli.run(['get', 'item', ours['id']! as String])) as Map<String, Object?>;
      expect(item['name'], 'GitHub');
      expect(item['notes'], 'ünïcode note');
      expect((item['login']! as Map<String, Object?>)['totp'], uri);
      expect((item['fields']! as List<Object?>).single, containsPair('value', '{"v":1}'));

      // The same code from both, unless the 30-second step turned in between
      final account2 = parseOtpUri(uri)!;
      final before = codeAt(account2, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      final theirs = await cli.run(['get', 'totp', ours['id']! as String]);
      final after = codeAt(account2, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      expect(theirs, anyOf(before, after));

      // An item the CLI makes, and an edit it makes to ours
      final template = jsonEncode({
        'type': 1,
        'name': 'Made by bw',
        'notes': null,
        'favorite': false,
        'fields': [
          {'name': 'Other', 'value': 'field', 'type': 0},
        ],
        'login': {'username': 'cli-user', 'password': 'pw', 'totp': 'steam://JBSWY3DPEHPK3PXP', 'uris': <Object?>[]},
        'reprompt': 0,
      });
      final encoded = await cli.run(['encode'], stdin: template);
      final made = jsonDecode(await cli.run(['create', 'item', encoded])) as Map<String, Object?>;
      final edited = {
        ...item,
        'login': {...item['login']! as Map<String, Object?>, 'totp': 'JBSWY3DPEHPK3PXP'},
      };
      await cli.run([
        'edit',
        'item',
        ours['id']! as String,
        await cli.run(['encode'], stdin: jsonEncode(edited)),
      ]);

      final synced = await api.sync(serverUrl!, token);
      final ciphers = (synced['ciphers']! as List<Object?>).cast<Map<String, Object?>>();
      final theirsCipher = ciphers.singleWhere((c) => c['id'] == made['id']);
      final itemKey = switch (theirsCipher['key']) {
        final String cipherKey => await bwOpenCipherKey(cipherKey, key),
        _ => key,
      };
      expect(await bwDecryptString(theirsCipher['name']! as String, itemKey), 'Made by bw');
      final theirLogin = theirsCipher['login']! as Map<String, Object?>;
      expect(await bwDecryptString(theirLogin['totp']! as String, itemKey), 'steam://JBSWY3DPEHPK3PXP');
      expect(await bwDecryptString(theirLogin['username']! as String, itemKey), 'cli-user');

      final oursAfter = ciphers.singleWhere((c) => c['id'] == ours['id']);
      final oursKey = switch (oursAfter['key']) {
        final String cipherKey => await bwOpenCipherKey(cipherKey, key),
        _ => key,
      };
      expect(await bwDecryptString((oursAfter['login']! as Map<String, Object?>)['totp']! as String, oursKey), 'JBSWY3DPEHPK3PXP');
      final field = (oursAfter['fields']! as List<Object?>).single! as Map<String, Object?>;
      expect(await bwDecryptString(field['name']! as String, oursKey), 'Kemlock');
      expect(await bwDecryptString(field['value']! as String, oursKey), '{"v":1}');
      expect(field['type'], 1);
      // ignore: avoid_print
      print('cipher keys: CLI-made ${theirsCipher['key'] != null}, CLI-edited ${oursAfter['key'] != null}');
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
