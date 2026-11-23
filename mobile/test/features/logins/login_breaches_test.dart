import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/breaches/pwned_passwords.dart';
import 'package:kemlock/features/logins/login_health.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_registry.dart' show keyOffline;

import '../export/transfer_harness.dart' show RecordingVault;

const _breachedPassword = 'summer2024';
const _strong = 'kT9#vq2L-wPz8!mR4x';

Login _login(String id, String password) => Login(id: id, name: 'Login $id', password: password, addedAt: 0);

// openspec: add-passwords, task 8.2
void main() {
  late List<Uri> asked;
  late KeyValueStore store;

  /// A container over a vault of [logins], whose Pwned Passwords knows [_breachedPassword] alone.
  ProviderContainer phone(List<Login> logins, {bool leakCheck = true, bool offline = false}) {
    asked = [];
    store = KeyValueStore.memory({
      'backmycodes_prefs': jsonEncode({'leakCheck': leakCheck}),
      if (offline) keyOffline: jsonEncode({'on': true}),
    });
    final breachedSuffix = sha1.convert(utf8.encode(_breachedPassword)).toString().toUpperCase().substring(5);
    final client = MockClient((request) async {
      asked.add(request.url);
      expect(request.headers['Add-Padding'], 'true');
      return http.Response('$breachedSuffix:42\r\n0000000000000000000000000000000000A:0', 200);
    });
    final container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        RecordingVault(logins: logins).asOverride,
        pwnedPasswordsProvider.overrideWithValue(PwnedPasswords(client, userAgent: () async => 'Kemlock tests')),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('asks once for each distinct password while the switch is on, and marks those found', () async {
    final container = phone([_login('a', _breachedPassword), _login('b', _breachedPassword), _login('c', _strong)]);

    final breached = await container.read(loginBreachesProvider.future);

    expect(breached, {'a', 'b'});
    expect(asked, hasLength(2), reason: 'one request per distinct password');
    for (final uri in asked) {
      expect(uri.toString(), startsWith('https://api.pwnedpasswords.com/range/'));
      expect(uri.pathSegments.last, hasLength(5), reason: 'five characters of the SHA-1, never the password');
    }
    // Asked again in the session, nothing more is sent
    container.invalidate(loginBreachesProvider);
    expect(await container.read(loginBreachesProvider.future), {'a', 'b'});
    expect(asked, hasLength(2));
    expect(container.read(loginHealthProvider).count(LoginWarning.breached), 2);
  });

  test('sends nothing while the switch is off', () async {
    final container = phone([_login('a', _breachedPassword)], leakCheck: false);

    expect(await container.read(loginBreachesProvider.future), isEmpty);
    expect(asked, isEmpty);
  });

  test('sends nothing in offline mode', () async {
    final container = phone([_login('a', _breachedPassword)], offline: true);

    expect(await container.read(loginBreachesProvider.future), isEmpty);
    expect(asked, isEmpty);
  });
}
