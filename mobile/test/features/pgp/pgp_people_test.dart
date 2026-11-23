// The vault's own PGP keys as the PGP sheets name them: by the user ID the
// key marks as its main one, which a change to the key can set (openspec:
// add-pgp-key-editing, joined with add-pgp-messages).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/pgp/pgp_people.dart';
import 'package:kemlock/features/pgp/pgp_widgets.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/test_app.dart';
import 'pgp_kit.dart';

void main() {
  testWidgets('a key of the vault whose main user ID is not its first is named by the main one', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: ['rsa']);
    final made = (await tester.runAsync(() async {
      final parsed = await crypto.readPrivateKey(fixtureBytes(fixtureKeys['kemlock-ed']!.$1));
      return crypto.makeKey(
        crypto.PgpChangeRequest(
          parsed.private,
          const crypto.AddPgpUserId(name: 'Ada at work', email: 'ada@work.example', makePrimary: true),
          now: testNow,
        ),
      );
    }))!;
    final info = crypto.readPgpKeyInfo(made.public!);
    expect((info.userIds.first, info.mainUserId), ('Ada Lovelace <ada@example.org>', 'Ada at work <ada@work.example>'));
    final key = vaultKeyOf(made, id: 'pgp-main', name: 'Mine', origin: KeyOrigin.imported);
    await tester.runAsync(() => pgp.app.container.read(vaultControllerProvider.notifier).addKey(key));
    await tester.pump();

    final people = pgp.app.container.read(pgpOwnPeopleProvider);
    expect(
      [for (final person in people) (person.name, person.address)],
      [('Fixture RSA', 'rsa@example.org'), ('Ada at work', 'ada@work.example')],
    );

    // The name a prompt for the key's passphrase gives it
    final titles = <String>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: pgp.app.container,
        child: Consumer(
          builder: (context, ref, _) {
            titles
              ..clear()
              ..addAll([for (final key in ref.read(vaultControllerProvider).keys) vaultKeyTitle(ref, key)]);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(titles, ['Fixture RSA', 'Ada at work']);
  });
}
