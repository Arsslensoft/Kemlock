import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../accounts/codes_fakes.dart';
import 'expiry_kit.dart';

/// The fixed clock: Monday 16 November 2026, 10:00 UTC.
final _now = DateTime.utc(2026, 11, 16, 10);

crypto.PgpKey _pgp({DateTime? expires, bool revoked = false}) => crypto.PgpKey(
  version: 4,
  fingerprint: Uint8List(20),
  algorithm: 'ed25519',
  created: DateTime.utc(2020),
  expires: expires,
  hasSecret: false,
  protected: false,
  revoked: revoked,
);

crypto.PgpKeyInfo _info({DateTime? expires, bool revoked = false, List<crypto.PgpKey> subkeys = const []}) =>
    crypto.PgpKeyInfo(_pgp(expires: expires, revoked: revoked), const ['Ada <ada@example.org>'], subkeys);

VaultState _vault(List<VaultKey> keys) => VaultState(
  phase: VaultPhase.unlocked,
  keys: keys,
  vault: const VaultInfo(id: 'main'),
);

void main() {
  group('a key standing', () {
    test('is in order for a key with no expiry, whatever the date', () {
      for (final now in [_now, DateTime.utc(1999), DateTime.utc(2200)]) {
        final standing = keyStanding(_info(), now);

        expect(standing, KeyStanding.ok);
        expect((standing.standing, standing.expires, standing.daysLeft), (Standing.ok, null, null));
      }
    });

    test('is in order 31 days before the expiry', () {
      final expires = _now.add(const Duration(days: 31));

      expect(keyStanding(_info(expires: expires), _now), KeyStanding(standing: Standing.ok, expires: expires, daysLeft: 31));
    });

    test('is expiring soon exactly 30 days before, and not a second earlier', () {
      final expires = _now.add(const Duration(days: 30));

      expect(keyStanding(_info(expires: expires), _now), KeyStanding(standing: Standing.expiringSoon, expires: expires, daysLeft: 30));
      expect(keyStanding(_info(expires: expires), _now.subtract(const Duration(seconds: 1))).standing, Standing.ok);
    });

    test('counts one day left', () {
      final expires = _now.add(const Duration(days: 1));

      expect(keyStanding(_info(expires: expires), _now), KeyStanding(standing: Standing.expiringSoon, expires: expires, daysLeft: 1));
    });

    test('counts no day left on the day it expires, until the moment it does', () {
      final expires = _now.add(const Duration(hours: 3));

      expect(keyStanding(_info(expires: expires), _now), KeyStanding(standing: Standing.expiringSoon, expires: expires, daysLeft: 0));
      expect(keyStanding(_info(expires: expires), expires.subtract(const Duration(seconds: 1))).standing, Standing.expiringSoon);
    });

    test('counts days on the calendar, not in spans of 24 hours', () {
      // 23:00 on the 16th to 01:00 on the 18th is 26 hours and two dates on
      final late = DateTime.utc(2026, 11, 16, 23);

      expect(keyStanding(_info(expires: DateTime.utc(2026, 11, 18, 1)), late).daysLeft, 2);
      expect(daysUntil(DateTime.utc(2026, 11, 17, 0, 30), late), 1);
    });

    test('is expired one second past the expiry, and at the expiry itself', () {
      final expires = _now.subtract(const Duration(seconds: 1));

      expect(keyStanding(_info(expires: expires), _now), KeyStanding(standing: Standing.expired, expires: expires));
      expect(keyStanding(_info(expires: _now), _now).standing, Standing.expired);
    });

    test('is revoked for a key that revoked itself', () {
      expect(keyStanding(_info(revoked: true), _now).standing, Standing.revoked);
    });

    test('is revoked for a revoked key that also expired, or is about to', () {
      final past = _now.subtract(const Duration(days: 400));

      expect(keyStanding(_info(revoked: true, expires: past), _now), KeyStanding(standing: Standing.revoked, expires: past));
      expect(keyStanding(_info(revoked: true, expires: _now.add(const Duration(days: 3))), _now).standing, Standing.revoked);
    });

    test('leaves a key in order whose subkey alone expired, and says so of the subkey', () {
      final past = _now.subtract(const Duration(days: 400));

      final standing = keyStanding(
        _info(
          subkeys: [
            _pgp(expires: past),
            _pgp(),
          ],
        ),
        _now,
      );

      expect(standing.standing, Standing.ok);
      expect(standing.subkeys, [KeyStanding(standing: Standing.expired, expires: past), KeyStanding.ok]);
      expect(standing.subkeyProblem, Standing.expired);
    });

    test('names a revoked subkey, and no subkey of a key that is itself over', () {
      final past = _now.subtract(const Duration(days: 400));

      expect(keyStanding(_info(subkeys: [_pgp(revoked: true)]), _now).subkeyProblem, Standing.revoked);
      expect(keyStanding(_info(subkeys: [_pgp()]), _now).subkeyProblem, isNull);
      expect(
        keyStanding(
          _info(
            expires: past,
            subkeys: [_pgp(expires: past)],
          ),
          _now,
        ).subkeyProblem,
        isNull,
      );
      expect(keyStanding(_info(revoked: true, subkeys: [_pgp(expires: past)]), _now).subkeyProblem, isNull);
    });

    test('is in order for a key that could not be read', () {
      expect(keyStanding(null, _now), KeyStanding.ok);
    });

    test('reads the keys GnuPG made', () async {
      Future<KeyStanding> of(String name, [DateTime? now]) async =>
          keyStanding(crypto.readPgpKeyInfo((await crypto.readPrivateKey(expiryFixtureText(name))).public!), now ?? _now);

      expect((await of('never')).standing, Standing.ok);
      expect(
        await of('expired'),
        isA<KeyStanding>().having((s) => s.standing, 'standing', Standing.expired).having((s) => s.expires, 'expires', pastExpiry),
      );
      expect((await of('future')).standing, Standing.ok);
      expect((await of('future')).expires, futureExpiry);
      expect((await of('future', futureExpiry.subtract(const Duration(days: 7)))).daysLeft, 7);
      expect((await of('revoked')).standing, Standing.revoked);
      expect((await of('revoked-expired')).standing, Standing.revoked);
      expect((await of('subkey-expired')).standing, Standing.ok);
      expect((await of('subkey-expired')).subkeyProblem, Standing.expired);
    });
  });

  group('what a stored key holds', () {
    late List<Uint8List> read;

    ProviderContainer containerWith(List<VaultKey> keys) {
      read = [];
      final container = ProviderContainer(
        overrides: [
          fakeVault(FakeVaultController(_vault(keys))),
          pgpKeyInfoReaderProvider.overrideWithValue((public) {
            read.add(public);
            return crypto.readPgpKeyInfo(public);
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('is read from the public half once, however often it is asked for', () async {
      final expired = await expiryFixtureKey('expired');
      final never = await expiryFixtureKey('never');
      final container = containerWith([expired, never]);

      final first = container.read(pgpKeyInfoProvider(expired.id));
      final second = container.read(pgpKeyInfoProvider(expired.id));

      expect(read, hasLength(1));
      expect(second, same(first));
      expect(first!.isSecret, isFalse, reason: 'the public half, not the secret one');
      expect(first.primary.expires, pastExpiry);

      container.read(pgpKeyInfoProvider(never.id));
      container.read(pgpKeyInfoProvider(expired.id));
      expect(read, hasLength(2));
    });

    test('is not read again when the key is renamed or another key is added', () async {
      final expired = await expiryFixtureKey('expired');
      final fake = FakeVaultController(_vault([expired]));
      read = [];
      final container = ProviderContainer(
        overrides: [
          fakeVault(fake),
          pgpKeyInfoReaderProvider.overrideWithValue((public) {
            read.add(public);
            return crypto.readPgpKeyInfo(public);
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(pgpKeyInfoProvider(expired.id), (_, _) {});
      container.read(vaultControllerProvider);

      fake.state = fake.state.copyWith(
        keys: [
          expired.copyWith(name: 'Renamed'),
          sshKey(),
        ],
      );
      await pumpEventQueue();

      expect(container.read(pgpKeyInfoProvider(expired.id)), isNotNull);
      expect(read, hasLength(1));
    });

    // openspec: add-pgp-key-editing, design decision 8
    test('is read again when the key itself changed, and gives the new standing at once', () async {
      final expired = await expiryFixtureKey('expired');
      final fake = FakeVaultController(_vault([expired]));
      read = [];
      final container = ProviderContainer(
        overrides: [
          fakeVault(fake),
          pgpKeyInfoReaderProvider.overrideWithValue((public) {
            read.add(public);
            return crypto.readPgpKeyInfo(public);
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(pgpKeyInfoProvider(expired.id), (_, _) {});
      expect(vaultKeyStanding(expired, _now, (id) => container.read(pgpKeyInfoProvider(id)))!.standing, Standing.expired);

      final extended = await crypto.makeKey(
        crypto.PgpChangeRequest(unb64(expired.privateKey), crypto.SetPgpExpiry(DateTime.utc(2030), alsoSubkeys: true), now: _now),
      );
      final changed = expired.withHalves(privateKey: b64(extended.private), publicKey: b64(extended.public!), protected: false);
      fake.state = fake.state.copyWith(keys: [changed]);
      await pumpEventQueue();

      final standing = vaultKeyStanding(changed, _now, (id) => container.read(pgpKeyInfoProvider(id)))!;
      expect((standing.standing, standing.expires), (Standing.ok, DateTime.utc(2030)));
      expect(read, hasLength(2));
    });

    test('gives a key of another kind no standing, and reads nothing for it', () {
      final ssh = sshKey();
      final container = containerWith([ssh]);

      expect(container.read(pgpKeyInfoProvider(ssh.id)), isNull);
      expect(vaultKeyStanding(ssh, _now, (id) => container.read(pgpKeyInfoProvider(id))), isNull);
      expect(read, isEmpty);
    });

    test('gives a PGP key its standing', () async {
      final revoked = await expiryFixtureKey('revoked');
      final container = containerWith([revoked]);

      expect(vaultKeyStanding(revoked, _now, (id) => container.read(pgpKeyInfoProvider(id)))!.standing, Standing.revoked);
    });

    test('leaves a PGP key in order whose stored data cannot be read', () {
      for (final public in ['AAAA', 'not base64 at all', null]) {
        final broken = VaultKey(
          id: 'broken',
          name: 'Broken',
          kind: KeyKind.pgp,
          algorithm: 'pgp',
          privateKey: 'AAAA',
          publicKey: public,
          origin: KeyOrigin.imported,
          addedAt: 0,
        );
        final container = containerWith([broken]);

        expect(container.read(pgpKeyInfoProvider(broken.id)), isNull, reason: '$public');
        expect(vaultKeyStanding(broken, _now, (id) => container.read(pgpKeyInfoProvider(id))), KeyStanding.ok, reason: '$public');
      }
    });

    test('holds nothing for a key that is not in the vault', () {
      expect(containerWith(const []).read(pgpKeyInfoProvider('gone')), isNull);
    });
  });
}
