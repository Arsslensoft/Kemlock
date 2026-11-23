// Telling PGP data from anything else another app shares, by content
// (openspec: add-share-extension, decision 7), with the fixtures of
// test/fixtures/share and a few GnuPG wrote for add-pgp-messages.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/share/shared_kind.dart';
import 'package:kemlock/platform/shared_items.dart';

Uint8List fixture(String path) => File('test/fixtures/$path').readAsBytesSync();

String fixtureText(String path) => File('test/fixtures/$path').readAsStringSync();

Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  group('from the content', () {
    test('an encrypted message, armored and binary', () {
      expect(sharedKind(fixture('share/encrypted.asc')), SharedKind.encrypted);
      expect(sharedKind(fixture('share/encrypted.gpg')), SharedKind.encrypted);
      // To a passphrase alone, and in GnuPG's OCB packet
      expect(sharedKind(fixture('pgp/gnupg/sym-default.gpg')), SharedKind.encrypted);
      expect(sharedKind(fixture('pgp/gnupg/to-ed25519.ocb.gpg')), SharedKind.encrypted);
    });

    test('a clear-signed text', () {
      expect(sharedKind(fixture('share/clearsigned.asc')), SharedKind.signed);
    });

    test('a signed message that is not clear-signed, armored and binary', () {
      expect(sharedKind(fixture('pgp/gnupg/inline-signed.asc')), SharedKind.signed);
      expect(sharedKind(fixture('pgp/gnupg/inline-signed.gpg')), SharedKind.signed);
      expect(sharedKind(fixture('pgp/gnupg/two-signers.gpg')), SharedKind.signed);
    });

    test('a detached signature, armored and binary', () {
      expect(sharedKind(fixture('share/detached.sig.asc')), SharedKind.detachedSignature);
      expect(sharedKind(fixture('share/detached.sig')), SharedKind.detachedSignature);
    });

    test('a text that mentions BEGIN PGP MESSAGE without being one is anything else', () {
      final mentions = fixtureText('share/mentions-pgp.txt');
      expect(mentions.split('\n\n')[1], contains('BEGIN PGP MESSAGE'));
      expect(sharedKind(text(mentions)), SharedKind.other);
      expect(sharedKind(fixture('share/message.txt')), SharedKind.other);
    });

    test('an empty text and a one-byte file are anything else', () {
      expect(sharedKind(Uint8List(0)), SharedKind.other);
      for (final byte in [0x61, 0x84, 0x85, 0x88, 0x89, 0x90, 0xc1, 0xc2, 0xff]) {
        expect(sharedKind(Uint8List.fromList([byte])), SharedKind.other, reason: '0x${byte.toRadixString(16)}');
      }
    });

    test('blank lines before an armor header are allowed', () {
      expect(sharedKind(text('\n\n${fixtureText('share/encrypted.asc')}')), SharedKind.encrypted);
      expect(sharedKind(text('\r\n  \r\n${fixtureText('share/clearsigned.asc')}')), SharedKind.signed);
      expect(sharedKind(text('\n${fixtureText('share/detached.sig.asc')}')), SharedKind.detachedSignature);
    });

    test('an armored message after the words of a mail is recognised, as the Decrypt sheet reads a pasted one', () {
      expect(sharedKind(text('Hi Ada,\n\nhere it is:\n\n${fixtureText('share/encrypted.asc')}\nGrace')), SharedKind.encrypted);
    });

    test('a photo is anything else, though a PNG starts with the header of a signature packet', () {
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // the PNG signature
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR
        ...List.filled(200, 0x42),
      ]);
      expect(sharedKind(png), SharedKind.other);
      // And longer than the first look reads
      expect(sharedKind(Uint8List.fromList([...png, ...List.filled(2 * sharedHeadLength, 0x17)])), SharedKind.other);
      // A JPEG, a PDF and a ZIP
      expect(sharedKind(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, ...List.filled(64, 0)])), SharedKind.other);
      expect(sharedKind(text('%PDF-1.7\n%âãÏÓ\n1 0 obj')), SharedKind.other);
      expect(sharedKind(Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, ...List.filled(64, 0)])), SharedKind.other);
    });

    test('a public key is anything else: taking it in is for later', () {
      expect(sharedKind(fixture('keys/gnupg/ed25519.public.asc')), SharedKind.other);
      expect(sharedKind(fixture('keys/gnupg/ed25519.public.gpg')), SharedKind.other);
    });
  });

  group('of a shared item', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('shared-kind');
      addTearDown(() => root.deleteSync(recursive: true));
    });

    SharedFile file(String name, List<int> bytes) {
      final file = File('${root.path}${Platform.pathSeparator}$name')..writeAsBytesSync(bytes);
      return SharedFile(path: file.path, name: name, size: bytes.length);
    }

    test('an encrypted file with an unhelpful name, by its content', () {
      expect(sharedKindOf(file('download.bin', fixture('share/encrypted.gpg'))), SharedKind.encrypted);
      expect(sharedKindOf(file('contract.pdf.sig', fixture('share/detached.sig'))), SharedKind.detachedSignature);
      expect(sharedKindOf(file('message.asc', fixture('share/message.txt'))), SharedKind.other);
      expect(sharedKindOf(file('one-byte', [0x89])), SharedKind.other);
    });

    test('a text', () {
      expect(sharedKindOf(SharedText(fixtureText('share/encrypted.asc'))), SharedKind.encrypted);
      expect(sharedKindOf(const SharedText('Meet me at nine.')), SharedKind.other);
    });

    test('a file that cannot be read is anything else', () {
      expect(sharedKindOf(SharedFile(path: '${root.path}${Platform.pathSeparator}gone.gpg', name: 'gone.gpg', size: 10)), SharedKind.other);
    });
  });
}
