import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/openssh.dart';
import 'package:kemlock/crypto/keys/pem.dart';
import 'package:kemlock/crypto/keys/sshsig.dart';
import 'package:kemlock/features/keys/sign_sheet.dart';
import 'package:kemlock/features/keys/verify_sheet.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'ssh_kit.dart';

// The verify sheet over what ssh-keygen and git signed with the fixture
// keys (test/fixtures/keys/openssh/sshsig, NOTES.md).

String _fixture(String name) => sshsigFile(name).readAsStringSync();

PickedFile _picked(String name) => PickedFile(name: name, bytes: sshsigFile(name).readAsBytesSync());

void main() {
  final submit = find.byKey(const ValueKey('verify-submit'));
  final result = find.byKey(const ValueKey('verify-result'));
  final signerPrint = find.byKey(const ValueKey('signer-fingerprint'));
  final ed25519Print = sshFixtureFingerprints['ed25519']!;

  /// The verify sheet, opened from the Keys filter of a vault holding [keys] and a note.
  Future<SshApp> open(WidgetTester tester, {List<VaultKey> keys = const []}) async {
    final ssh = SshApp(tester);
    await ssh.startWith(keys);
    await ssh.app.controller.addNote(const SecureNote(id: 'n1', title: 'A note', text: '', addedAt: 0));
    await tester.pump(const Duration(seconds: 10));
    await ssh.settle();
    await ssh.openVerify();
    return ssh;
  }

  bool enabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(submit).onPressed != null;

  Future<void> type(SshApp ssh, String labelId, String text) async {
    final field = find.widgetWithText(TextField, t(labelId));
    await ssh.tester.ensureVisible(field);
    await ssh.tester.enterText(field, text);
    await ssh.tester.pump();
  }

  /// Gives the signature [sig] and the file [message], and verifies.
  Future<void> check(SshApp ssh, String sig, PickedFile message, {String? signer, String? purpose}) async {
    await type(ssh, 'keys.verify.signature', sig);
    ssh.files.nextPick = message;
    await ssh.tap(find.byKey(const ValueKey('verify-file')));
    if (purpose != null) await ssh.tap(find.text(t(purpose)));
    if (signer != null) await type(ssh, 'keys.verify.signer', signer);
    await ssh.tap(submit);
  }

  /// Gives the raw git object [text], and verifies.
  Future<void> checkGit(SshApp ssh, String text) async {
    await ssh.choose<VerifyMode>('keys.verify.mode.git');
    await type(ssh, 'keys.verify.mode.git', text);
    await ssh.tap(submit);
  }

  void expectResult(WidgetTester tester, AlertSeverity severity, String id, [Map<String, Object?> args = const {}]) {
    expect(result, findsOneWidget);
    expect(find.descendant(of: result, matching: find.text(t(id, args))), findsOneWidget);
    expect(tester.widget<AppAlert>(result).severity, severity);
  }

  group('a good signature', () {
    testWidgets('made by a key of the vault says it is your key, by name', (tester) async {
      final ssh = await open(
        tester,
        keys: [
          await sshFixtureKey('ed25519', title: 'laptop'),
          await sshFixtureKey('rsa3072', title: 'server'),
        ],
      );
      final revision = ssh.app.state.revision;
      expect(enabled(tester), isFalse);

      await check(ssh, _fixture('ed25519-file-hello.txt.sig'), _picked('hello.txt'));

      expectResult(tester, AlertSeverity.success, 'keys.verify.good.own', {'name': 'laptop'});
      expect(tester.widget<SelectableText>(signerPrint).data, ed25519Print);
      expect(tester.widget<Text>(find.byKey(const ValueKey('signer-type'))).data, 'ssh-ed25519');
      expect(ssh.app.state.revision, revision);
    });

    testWidgets('made by a key that is not in the vault is a warning that shows the fingerprint to compare', (tester) async {
      final ssh = await open(tester);

      await check(ssh, _fixture('ed25519-file-hello.txt.sig'), _picked('hello.txt'));

      expectResult(tester, AlertSeverity.warning, 'keys.verify.good.unknown');
      expect(tester.widget<SelectableText>(signerPrint).data, ed25519Print);
    });

    testWidgets('by another key than the vault holds is still unknown', (tester) async {
      final ssh = await open(tester, keys: [await sshFixtureKey('rsa3072', title: 'server')]);

      await check(ssh, _fixture('ecdsa384-file-bytes.bin.sig'), _picked('bytes.bin'));

      expectResult(tester, AlertSeverity.warning, 'keys.verify.good.unknown');
      expect(tester.widget<SelectableText>(signerPrint).data, sshFixtureFingerprints['ecdsa384']);
      expect(tester.widget<Text>(find.byKey(const ValueKey('signer-type'))).data, 'ecdsa-sha2-nistp384');
    });

    testWidgets('with the signer’s public key pasted is a success that says it matches', (tester) async {
      final ssh = await open(tester);

      await check(ssh, _fixture('ed25519-file-hello.txt.sig'), _picked('hello.txt'), signer: sshFixturePublicLine('ed25519'));

      expectResult(tester, AlertSeverity.success, 'keys.verify.good.given');
      expect(tester.widget<SelectableText>(signerPrint).data, ed25519Print);
    });

    testWidgets('with another key pasted is an error that names the key that signed', (tester) async {
      final ssh = await open(tester, keys: [await sshFixtureKey('ed25519', title: 'laptop')]);

      await check(ssh, _fixture('ed25519-file-hello.txt.sig'), _picked('hello.txt'), signer: sshFixturePublicLine('rsa3072'));

      expectResult(tester, AlertSeverity.error, 'keys.verify.otherKey');
      expect(tester.widget<SelectableText>(signerPrint).data, ed25519Print);
      expect(find.text(t('keys.verify.good.own', {'name': 'laptop'})), findsNothing);
    });

    testWidgets('made with SHA-256, with RSA and with ECDSA is good too, over typed text', (tester) async {
      final ssh = await open(tester);

      for (final sig in ['ed25519-sha256-hello.txt.sig', 'rsa3072-file-hello.txt.sig', 'ecdsa256-file-hello.txt.sig']) {
        await type(ssh, 'keys.verify.signature', _fixture(sig));
        await ssh.choose<SignSource>('keys.sign.text');
        await type(ssh, 'keys.sign.text', 'hello');
        await ssh.tap(submit);

        expectResult(tester, AlertSeverity.warning, 'keys.verify.good.unknown');
      }
    });

    testWidgets('opened from a .sig file, for a custom namespace', (tester) async {
      final ssh = await open(tester);

      ssh.files.nextPick = _picked('ed25519-custom-bytes.bin.sig');
      await ssh.tap(find.text(t('keys.verify.openSig')));
      expect(find.textContaining('U1NIU0lH'), findsOneWidget);
      ssh.files.nextPick = _picked('bytes.bin');
      await ssh.tap(find.byKey(const ValueKey('verify-file')));
      await ssh.tap(find.text(t('keys.sign.for.other')));
      expect(enabled(tester), isFalse);
      await type(ssh, 'keys.sign.namespace', 'kemlock-test@example.org');
      await ssh.tap(submit);

      expectResult(tester, AlertSeverity.warning, 'keys.verify.good.unknown');
    });
  });

  group('says why a signature is not good:', () {
    testWidgets('a file that differs by one byte', (tester) async {
      final ssh = await open(tester, keys: [await sshFixtureKey('ed25519', title: 'laptop')]);
      final changed = sshsigFile('bytes.bin').readAsBytesSync()..[100] ^= 1;

      await check(ssh, _fixture('ed25519-file-bytes.bin.sig'), PickedFile(name: 'bytes.bin', bytes: changed));

      expectResult(tester, AlertSeverity.error, 'keys.verify.bad');
      // A bad signature names no signer
      expect(signerPrint, findsNothing);
    });

    testWidgets('made for another namespace, naming both', (tester) async {
      final ssh = await open(tester);

      await check(ssh, _fixture('ed25519-git-hello.txt.sig'), _picked('hello.txt'));
      expectResult(tester, AlertSeverity.error, 'keys.verify.namespace', {'made': 'git', 'wanted': 'file'});
      expect(signerPrint, findsNothing);

      // Checked for what it was made for, it is good
      await ssh.tap(find.text(t('keys.sign.for.git')));
      expect(result, findsNothing);
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.warning, 'keys.verify.good.unknown');
    });

    testWidgets('a key type Kemlock does not check, named', (tester) async {
      final ssh = await open(tester);

      await check(ssh, _fixture('ecdsa521-file-hello.txt.sig'), _picked('hello.txt'));

      expectResult(tester, AlertSeverity.error, 'keys.verify.unsupported', {'type': 'ecdsa-sha2-nistp521'});
    });

    testWidgets('an RSA signature with SHA-1', (tester) async {
      final ssh = await open(tester);
      final rsa = readSshsig(_fixture('rsa3072-file-hello.txt.sig'));
      final blob = SshWriter()
        ..raw(ascii.encode('SSHSIG'))
        ..uint32(1)
        ..string(rsa.publicKeyBlob)
        ..text('file')
        ..string(const [])
        ..text('sha512')
        ..string(
          (SshWriter()
                ..text('ssh-rsa')
                ..string(rsa.signature))
              .bytes,
        );

      await check(ssh, writePem('SSH SIGNATURE', blob.bytes, lineLength: 70), _picked('hello.txt'));

      expectResult(tester, AlertSeverity.error, 'keys.verify.weak');
    });

    testWidgets('a PGP block and plain text are not SSH signatures', (tester) async {
      final ssh = await open(tester);

      await check(ssh, '-----BEGIN PGP SIGNATURE-----\n\niHUEABYKAB0WIQQ=\n=abcd\n-----END PGP SIGNATURE-----\n', _picked('hello.txt'));
      expectResult(tester, AlertSeverity.error, 'keys.verify.notSsh');

      await type(ssh, 'keys.verify.signature', 'hello');
      expect(result, findsNothing);
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.error, 'keys.verify.notSsh');
    });

    testWidgets('a block cut short, or with bytes after its end, is damaged', (tester) async {
      final ssh = await open(tester);
      final whole = _fixture('ed25519-file-hello.txt.sig');

      await check(ssh, whole.substring(0, 150), _picked('hello.txt'));
      expectResult(tester, AlertSeverity.error, 'keys.verify.damaged');

      final blob = readPemBlocks(whole).single.decode();
      await type(ssh, 'keys.verify.signature', writePem('SSH SIGNATURE', [...blob, 0, 0, 0], lineLength: 70));
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.error, 'keys.verify.damaged');
    });

    testWidgets('a public key line that cannot be read, before anything is checked', (tester) async {
      final ssh = await open(tester);

      await check(ssh, _fixture('ed25519-file-hello.txt.sig'), _picked('hello.txt'), signer: 'ssh-ed25519 not-a-key');

      expectResult(tester, AlertSeverity.error, 'keys.verify.badKey');
      expect(find.text(t('keys.verify.good.unknown')), findsNothing);
      expect(signerPrint, findsNothing);

      // Also for a signature that would be bad: the key is read first
      await type(ssh, 'keys.verify.signature', 'hello');
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.error, 'keys.verify.badKey');
    });

    testWidgets('a file over the limit is refused with the limit', (tester) async {
      final ssh = await open(tester);

      ssh.files.nextPick = PickedFile(name: 'disk.img', bytes: Uint8List(maxSignedFileBytes + 1));
      await ssh.tap(find.byKey(const ValueKey('verify-file')));

      expect(find.byKey(const ValueKey('verify-too-large')), findsOneWidget);
      expect(find.textContaining('disk.img'), findsNothing);
      await type(ssh, 'keys.verify.signature', _fixture('ed25519-file-hello.txt.sig'));
      expect(enabled(tester), isFalse);
    });
  });

  group('a git commit or tag', () {
    testWidgets('signed by git with a key of the vault is good, pasted or opened as a file', (tester) async {
      final ssh = await open(tester, keys: [await sshFixtureKey('ed25519', title: 'laptop')]);

      await checkGit(ssh, _fixture('git-commit.txt'));
      expectResult(tester, AlertSeverity.success, 'keys.verify.good.own', {'name': 'laptop'});
      expect(tester.widget<SelectableText>(signerPrint).data, ed25519Print);

      await type(ssh, 'keys.verify.mode.git', _fixture('git-tag.txt'));
      expect(result, findsNothing);
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.success, 'keys.verify.good.own', {'name': 'laptop'});

      ssh.files.nextPick = _picked('git-commit.txt');
      await ssh.tap(find.byKey(const ValueKey('verify-git-file')));
      expect(result, findsNothing);
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.success, 'keys.verify.good.own', {'name': 'laptop'});
    });

    testWidgets('pasted without its final line ending still verifies, and names an unknown signer', (tester) async {
      final ssh = await open(tester);

      await checkGit(ssh, _fixture('git-commit.txt').trimRight());

      expectResult(tester, AlertSeverity.warning, 'keys.verify.good.unknown');
    });

    testWidgets('with a letter of its message changed is bad', (tester) async {
      final ssh = await open(tester);

      await checkGit(ssh, _fixture('git-commit.txt').replaceFirst('greeting', 'greetinG'));

      expectResult(tester, AlertSeverity.error, 'keys.verify.bad');
    });

    testWidgets('that is unsigned, signed with PGP, or not a git object says so', (tester) async {
      final ssh = await open(tester);
      final lines = _fixture('git-commit.txt').split('\n');
      final unsigned = lines.where((l) => !l.startsWith('gpgsig ') && !l.startsWith(' ')).join('\n');
      final pgp = [
        ...lines.take(3),
        'gpgsig -----BEGIN PGP SIGNATURE-----',
        ' ',
        ' iHUEABYKAB0WIQQ=',
        ' =abcd',
        ' -----END PGP SIGNATURE-----',
        ...lines.skipWhile((l) => l.isNotEmpty),
      ].join('\n');

      await checkGit(ssh, unsigned);
      expectResult(tester, AlertSeverity.error, 'keys.verify.git.unsigned');

      await type(ssh, 'keys.verify.mode.git', pgp);
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.error, 'keys.verify.git.pgp');

      await type(ssh, 'keys.verify.mode.git', 'commit 5aeee2dc8bf106c91741bbe9530674262f36fe90\nAuthor: Fixture\n');
      await ssh.tap(submit);
      expectResult(tester, AlertSeverity.error, 'keys.verify.git.notGit');
    });
  });
}
