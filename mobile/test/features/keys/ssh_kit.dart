import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pkcs8.dart';
import 'package:kemlock/crypto/keys/sshsig.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/sign_sheet.dart';
import 'package:kemlock/features/keys/verify_sheet.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'keys_kit.dart';

// The unprotected SSH keys of test/fixtures/keys/openssh (`ed25519`,
// `ecdsa256`, `ecdsa384`, `rsa3072`), and the signatures ssh-keygen and git
// made with them in its `sshsig` folder (NOTES.md).

/// What `ssh-keygen -l` printed for each key (`fingerprints.txt`).
const sshFixtureFingerprints = {
  'ed25519': 'SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4',
  'ecdsa256': 'SHA256:1LkESzryE4MYynhd3exDCkyGDEpD12LpdfrG6nxFqWg',
  'ecdsa384': 'SHA256:wMVbj/Jt6yy6Qt3JEuQ6XmpwC/kJSMIpk4DJwDPx5Gw',
  'ecdsa521': 'SHA256:2Zkkw/B6LrkdE2VFIbEVtPKk9IejguYDxi0yg2+xtS4',
  'rsa3072': 'SHA256:mbgQkBCI/n6+2Z/EVBwEvUdGixwoFo5k7g+teZng2bM',
};

/// The fixture key [name] as the vault keeps an imported SSH key, listed
/// as [title] (its file name unless given) under the id `ssh-<name>`.
Future<VaultKey> sshFixtureKey(String name, {String? title, bool pinned = false, int addedAt = 0}) async {
  final parsed = await crypto.readPrivateKey(File('test/fixtures/keys/openssh/$name').readAsBytesSync());
  return vaultKeyOf(
    parsed,
    id: 'ssh-$name',
    name: title ?? name,
    origin: KeyOrigin.imported,
  ).copyWith(addedAt: addedAt, pinned: pinned ? true : null);
}

/// A file of test/fixtures/keys/openssh/sshsig: a message, a `.sig` or a
/// git object.
File sshsigFile(String name) => File('test/fixtures/keys/openssh/sshsig/$name');

/// The `.pub` line of the fixture key [name].
String sshFixturePublicLine(String name) => File('test/fixtures/keys/openssh/$name.pub').readAsStringSync().trim();

/// [KeysApp] with SSH signatures made and checked on this isolate, and what
/// the app copies to the plain clipboard kept in [clipboard].
class SshApp extends KeysApp {
  SshApp(super.tester);

  final clipboard = <String>[];

  @override
  List<Override> get overrides => [
    ...super.overrides,
    sshSignerProvider.overrideWithValue((pkcs8, namespace, message) async => sshsigSign(await readPkcs8(pkcs8), namespace, message)),
    sshCheckerProvider.overrideWithValue(sshCheck),
  ];

  /// Starts the app on the Vault tab with [keys] in its vault.
  Future<void> startWith(List<VaultKey> keys) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add('${(call.arguments as Map)['text']}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await start();
    for (final key in keys) {
      expect(await app.controller.addKey(key), isTrue);
    }
    // The add's toast would sit over a sheet until it times out
    await tester.pump(const Duration(seconds: 10));
    await settle();
  }

  /// Opens the sheet of the key listed as [name], then its "Sign a file or text".
  Future<void> openSign(String name) async {
    await tap(find.text(name));
    await tap(find.text(t('keys.sign.action')));
  }

  /// Opens "Verify an SSH signature" from the end of the Keys filter.
  Future<void> openVerify() async {
    await choose<VaultFilter>('vault.filter.keys');
    await tap(find.text(t('keys.verify.entry')));
  }

  /// Chooses the segment labelled by the message [id].
  Future<void> choose<T>(String id) => tap(find.descendant(of: find.byType(SegmentedControl<T>), matching: find.text(t(id))));
}
