import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/ssh_fingerprint.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../accounts/codes_fakes.dart';
import 'expiry_kit.dart';

/// Comment to fingerprint, from what `ssh-keygen -l` printed for the keys
/// of test/fixtures/keys/openssh.
final Map<String, String> _printed = {
  for (final line in const LineSplitter().convert(File('test/fixtures/keys/openssh/fingerprints.txt').readAsStringSync()))
    if (line.endsWith('(ED25519)') || line.endsWith('(ECDSA)') || line.endsWith('(RSA)'))
      line.substring(line.indexOf(' ', line.indexOf('SHA256:')) + 1, line.lastIndexOf(' (')): line.split(' ')[1],
};

/// The fixture [file] as the vault keeps an imported key, under its own name as id.
Future<VaultKey> _key(String file, {String? kind}) async {
  final parsed = await crypto.readPrivateKey(File('test/fixtures/keys/$file').readAsBytesSync());
  final key = vaultKeyOf(parsed, id: file, name: file, origin: KeyOrigin.imported);
  return kind == null ? key : VaultKey.fromJson({...key.toJson(), 'kind': kind});
}

VaultState _vault(List<VaultKey> keys) => VaultState(
  phase: VaultPhase.unlocked,
  keys: keys,
  vault: const VaultInfo(id: 'main'),
);

void main() {
  late List<Uint8List> hashed;

  ProviderContainer containerWith(FakeVaultController vault) {
    hashed = [];
    final container = ProviderContainer(
      overrides: [
        fakeVault(vault),
        sshFingerprintReaderProvider.overrideWithValue((public) {
          hashed.add(public);
          return crypto.sshFingerprintOfSpki(public);
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('an SSH key in the vault', () {
    test('has the fingerprint ssh-keygen -l printed', () async {
      final keys = [
        for (final name in ['ed25519', 'ecdsa256', 'ecdsa384', 'rsa3072']) await _key('openssh/$name'),
      ];
      final container = containerWith(FakeVaultController(_vault(keys)));

      expect(container.read(sshFingerprintProvider('openssh/ed25519')), _printed['fixture ed25519']);
      expect(container.read(sshFingerprintProvider('openssh/ecdsa256')), _printed['fixture ecdsa p256']);
      expect(container.read(sshFingerprintProvider('openssh/ecdsa384')), _printed['fixture ecdsa p384']);
      expect(container.read(sshFingerprintProvider('openssh/rsa3072')), _printed['fixture rsa 3072']);
      expect(_printed['fixture ed25519'], 'SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4');
    });

    test('is hashed once, however often it is asked for', () async {
      final ed25519 = await _key('openssh/ed25519');
      final rsa = await _key('openssh/rsa3072');
      final container = containerWith(FakeVaultController(_vault([ed25519, rsa])));

      final first = container.read(sshFingerprintProvider(ed25519.id));
      final second = container.read(sshFingerprintProvider(ed25519.id));

      expect(hashed, hasLength(1));
      expect(second, first);

      container.read(sshFingerprintProvider(rsa.id));
      container.read(sshFingerprintProvider(ed25519.id));
      expect(hashed, hasLength(2));
    });

    test('is not hashed again when the key is renamed or another key is added', () async {
      final ed25519 = await _key('openssh/ed25519');
      final fake = FakeVaultController(_vault([ed25519]));
      final container = containerWith(fake);
      container.listen(sshFingerprintProvider(ed25519.id), (_, _) {});
      container.read(vaultControllerProvider);

      fake.state = fake.state.copyWith(
        keys: [
          ed25519.copyWith(name: 'Renamed'),
          await _key('openssh/rsa3072'),
        ],
      );
      await pumpEventQueue();

      expect(container.read(sshFingerprintProvider(ed25519.id)), _printed['fixture ed25519']);
      expect(hashed, hasLength(1));
    });
  });

  group('no fingerprint for', () {
    test('a PGP key, a signing key and an exchange key, and nothing is hashed for them', () async {
      final pgp = await expiryFixtureKey('never');
      final signing = await _key('openssl/ed25519.pkcs8.pem');
      final exchange = await _key('openssl/x25519.pkcs8.pem');
      expect((pgp.kind, signing.kind, exchange.kind), (KeyKind.pgp, KeyKind.signing, KeyKind.exchange));
      final container = containerWith(FakeVaultController(_vault([pgp, signing, exchange])));

      expect(container.read(sshFingerprintProvider(pgp.id)), isNull);
      expect(container.read(sshFingerprintProvider(signing.id)), isNull);
      expect(container.read(sshFingerprintProvider(exchange.id)), isNull);
      expect(hashed, isEmpty);
    });

    test('a key that is not in the vault', () {
      final container = containerWith(FakeVaultController(_vault(const [])));

      expect(container.read(sshFingerprintProvider('gone')), isNull);
    });

    test('an SSH key whose public half cannot be read, or has no SSH form', () async {
      final exchange = await _key('openssl/x25519.pkcs8.pem', kind: KeyKind.ssh);
      final container = containerWith(
        FakeVaultController(
          _vault([
            sshKey(),
            VaultKey.fromJson({...sshKey(id: 'no-base64').toJson(), 'public': '***'}),
            exchange,
          ]),
        ),
      );

      expect(container.read(sshFingerprintProvider('ssh-1')), isNull);
      expect(container.read(sshFingerprintProvider('no-base64')), isNull);
      expect(container.read(sshFingerprintProvider(exchange.id)), isNull);
    });
  });

  group('the short form', () {
    test('is SHA256: with the first four and the last four characters', () {
      expect(shortSshFingerprint('SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4'), 'SHA256:41s5…UAW4');
      expect(shortSshFingerprint('SHA256:mbgQkBCI/n6+2Z/EVBwEvUdGixwoFo5k7g+teZng2bM'), 'SHA256:mbgQ…g2bM');
    });

    test('leaves alone what is not a whole fingerprint', () {
      expect(shortSshFingerprint('SHA256:abcdefgh'), 'SHA256:abcdefgh');
      expect(
        shortSshFingerprint('MD5:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99'),
        'MD5:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99',
      );
      expect(shortSshFingerprint(''), '');
    });
  });
}
