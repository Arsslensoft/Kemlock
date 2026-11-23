import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/keys/sign_sheet.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'ssh_kit.dart';

// The sign sheet with the ed25519 fixture key in the vault: what it writes
// must be the files ssh-keygen wrote for the same key, message and
// namespace (test/fixtures/keys/openssh/sshsig, NOTES.md).

String _fixture(String name) => sshsigFile(name).readAsStringSync();

PickedFile _picked(String name) => PickedFile(name: name, bytes: sshsigFile(name).readAsBytesSync());

void main() {
  final submit = find.byKey(const ValueKey('sign-submit'));
  final signature = find.byKey(const ValueKey('signature'));
  Finder inSheet(Finder what) => find.descendant(of: find.byType(SignSheet), matching: what);

  Future<SshApp> open(WidgetTester tester) async {
    final ssh = SshApp(tester);
    await ssh.startWith([await sshFixtureKey('ed25519', title: 'laptop')]);
    await ssh.openSign('laptop');
    return ssh;
  }

  bool enabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(submit).onPressed != null;

  String shown(WidgetTester tester) => tester.widget<SelectableText>(signature).data!;

  Future<void> typeText(SshApp ssh, String text) async {
    await ssh.choose<SignSource>('keys.sign.text');
    await ssh.tester.enterText(find.widgetWithText(TextField, t('keys.sign.text')), text);
    await ssh.tester.pump();
  }

  Future<void> pick(SshApp ssh, PickedFile file) async {
    ssh.files.nextPick = file;
    await ssh.tap(find.text(t('keys.sign.chooseFile')));
  }

  testWidgets('opens on a file, for a file, named after the key, and cannot sign yet', (tester) async {
    await open(tester);

    expect(find.text(t('keys.sign.title', {'name': 'laptop'})), findsOneWidget);
    expect(tester.widget<SegmentedControl<SignSource>>(find.byType(SegmentedControl<SignSource>)).value, SignSource.file);
    expect(tester.widget<RadioGroup<SignPurpose>>(find.byType(RadioGroup<SignPurpose>)).groupValue, SignPurpose.file);
    expect(find.text(t('keys.sign.chooseFile')), findsOneWidget);
    expect(enabled(tester), isFalse);
    expect(signature, findsNothing);
  });

  testWidgets('signing "hello" as text gives the signature ssh-keygen wrote for hello.txt', (tester) async {
    final ssh = await open(tester);
    final revision = ssh.app.state.revision;
    final keys = [for (final key in ssh.keys) key.toJson()];

    await typeText(ssh, 'hello');
    // The screen says the text is signed as typed
    expect(find.text(t('keys.sign.textHint')), findsOneWidget);
    expect(enabled(tester), isTrue);
    await ssh.tap(submit);

    expect(find.text(t('keys.sign.done')), findsOneWidget);
    expect(shown(tester), _fixture('ed25519-file-hello.txt.sig').trimRight());
    // Nothing was added to or changed in the vault
    expect(ssh.app.state.revision, revision);
    expect([for (final key in ssh.keys) key.toJson()], keys);
    // Nothing of the private half is on screen
    expect(find.textContaining('PRIVATE KEY-----'), findsNothing);
  });

  testWidgets('a line ending typed after the text is signed too', (tester) async {
    final ssh = await open(tester);

    await typeText(ssh, 'hello\n');
    await ssh.tap(submit);

    expect(shown(tester), isNot(_fixture('ed25519-file-hello.txt.sig').trimRight()));
    expect(shown(tester), startsWith('-----BEGIN SSH SIGNATURE-----'));
  });

  testWidgets('signing a picked binary file gives its signature, saved as <file>.sig', (tester) async {
    final ssh = await open(tester);

    await pick(ssh, _picked('bytes.bin'));
    expect(find.textContaining('bytes.bin'), findsOneWidget);
    await ssh.tap(submit);

    expect(shown(tester), _fixture('ed25519-file-bytes.bin.sig').trimRight());

    await ssh.tap(inSheet(find.text(t('notes.save'))));
    expect(ssh.files.saved.single.name, 'bytes.bin.sig');
    expect(ssh.files.saved.single.shared, isFalse);
    // The file is the one ssh-keygen writes, its final line ending included
    expect(ssh.files.lastSavedText, _fixture('ed25519-file-bytes.bin.sig'));

    await ssh.tap(inSheet(find.text(t('notes.copy.share'))));
    expect((ssh.files.saved.last.name, ssh.files.saved.last.shared), ('bytes.bin.sig', true));
    expect(ssh.files.lastSavedText, _fixture('ed25519-file-bytes.bin.sig'));
  });

  testWidgets('an empty file is signed as ssh-keygen signs it', (tester) async {
    final ssh = await open(tester);

    await pick(ssh, PickedFile(name: 'empty', bytes: Uint8List(0)));
    expect(enabled(tester), isTrue);
    await ssh.tap(submit);

    expect(shown(tester), _fixture('ed25519-file-empty.sig').trimRight());
  });

  testWidgets('"A git commit or tag" signs for git', (tester) async {
    final ssh = await open(tester);

    await typeText(ssh, 'hello');
    await ssh.tap(find.text(t('keys.sign.for.git')));
    await ssh.tap(submit);

    expect(shown(tester), _fixture('ed25519-git-hello.txt.sig').trimRight());
  });

  testWidgets('"Other" signs for the namespace typed, and not for an empty one or one with a space', (tester) async {
    final ssh = await open(tester);
    final namespace = find.widgetWithText(TextField, t('keys.sign.namespace'));

    await typeText(ssh, 'hello');
    expect(namespace, findsNothing);
    await ssh.tap(find.text(t('keys.sign.for.other')));
    expect(enabled(tester), isFalse);

    for (final refused in ['my files', ' ', 'a b@example.org']) {
      await tester.enterText(namespace, refused);
      await tester.pump();
      expect(enabled(tester), isFalse, reason: jsonEncode(refused));
    }

    await tester.enterText(namespace, 'kemlock-test@example.org');
    await tester.pump();
    expect(enabled(tester), isTrue);
    await ssh.tap(submit);

    expect(shown(tester), _fixture('ed25519-custom-hello.txt.sig').trimRight());
  });

  testWidgets('with no file chosen and no text typed, nothing can be signed', (tester) async {
    final ssh = await open(tester);
    expect(enabled(tester), isFalse);

    // A picker closed without a file
    await ssh.tap(find.text(t('keys.sign.chooseFile')));
    expect(enabled(tester), isFalse);

    await ssh.choose<SignSource>('keys.sign.text');
    expect(enabled(tester), isFalse);
    await tester.tap(submit, warnIfMissed: false);
    await ssh.settle();
    expect(signature, findsNothing);
  });

  testWidgets('a file over the limit is refused with a message that says the limit', (tester) async {
    final ssh = await open(tester);

    await pick(ssh, PickedFile(name: 'disk.img', bytes: Uint8List(maxSignedFileBytes + 1)));

    expect(find.byKey(const ValueKey('sign-too-large')), findsOneWidget);
    expect(find.textContaining('64'), findsOneWidget);
    expect(find.textContaining('disk.img'), findsNothing);
    expect(enabled(tester), isFalse);
    expect(signature, findsNothing);

    // A file of exactly the limit is taken
    await pick(ssh, PickedFile(name: 'just.img', bytes: Uint8List(maxSignedFileBytes)));
    expect(find.byKey(const ValueKey('sign-too-large')), findsNothing);
    expect(enabled(tester), isTrue);
  });

  testWidgets('signed text is saved as signature.sig, and copied whole to the plain clipboard', (tester) async {
    final ssh = await open(tester);
    await typeText(ssh, 'hello');
    await ssh.tap(submit);

    await ssh.tap(inSheet(find.text(t('notes.save'))));
    expect(ssh.files.saved.single.name, 'signature.sig');
    expect(ssh.files.lastSavedText, _fixture('ed25519-file-hello.txt.sig'));
    expect(find.text(t('notes.copy.saved', {'location': 'Downloads/signature.sig'})), findsOneWidget);

    await ssh.tap(inSheet(find.text(t('keys.public.copy'))));
    final copied = ssh.clipboard.single;
    expect(copied, startsWith('-----BEGIN SSH SIGNATURE-----\n'));
    expect(copied, endsWith('\n-----END SSH SIGNATURE-----'));
    expect(copied, _fixture('ed25519-file-hello.txt.sig').trimRight());
  });

  testWidgets('changing what is signed takes the old signature away', (tester) async {
    final ssh = await open(tester);
    await typeText(ssh, 'hello');
    await ssh.tap(submit);
    expect(signature, findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, t('keys.sign.text')), 'hello!');
    await tester.pump();
    expect(signature, findsNothing);

    await ssh.tap(submit);
    expect(signature, findsOneWidget);
    await ssh.tap(find.text(t('keys.sign.for.git')));
    expect(signature, findsNothing);
  });

  testWidgets('an RSA and an ECDSA key sign too', (tester) async {
    final ssh = SshApp(tester);
    await ssh.startWith([await sshFixtureKey('rsa3072', title: 'server'), await sshFixtureKey('ecdsa256', title: 'phone')]);

    await ssh.openSign('server');
    await pick(ssh, _picked('hello.txt'));
    await ssh.tap(submit);
    expect(shown(tester), _fixture('rsa3072-file-hello.txt.sig').trimRight());
  });
}
