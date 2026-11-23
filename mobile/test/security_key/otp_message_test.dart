// Reading a YubiKey's one-time password from its NFC message, against the
// fake key and hand-written NDEF messages.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/otp_message.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_ndef_applet.dart';
import '../fakes/fake_security_keys.dart';
import 'hex.dart';

const _otp = 'ccccccbchvthlivuitriujjifivbvtrjkjfirllluurj';

Uint8List _fixture(String name) => unhex(File('test/fixtures/security_keys/ndef/$name.hex').readAsStringSync());

/// Reads the code of a key with [applets], held to an Android phone.
Future<String?> _read(List<FakeApplet> applets, {FakeSecurityKeys? phone, bool extendedLength = true}) {
  final keys = phone ?? FakeSecurityKeys();
  keys.arrive(FakeKey(ctap: FakeFidoKey(), applets: applets, extendedLength: extendedLength).device(kinds: {SecurityKeyLinkKind.nfc}));
  return runOnKey(keys, readOtpMessage, viaNfc: true, now: keys.now);
}

void main() {
  test('a Yubico link gives its 44 characters', () async {
    final applet = FakeNdefApplet(_fixture('yubico-link'));

    expect(await _read([applet]), _otp);

    // The message file is selected, its length read, then the message
    expect(applet.commands, ['a4 00 0c', 'b0 00 00', 'b0 00 02']);
  });

  test('a link with another host and the same tail gives them too', () async {
    expect(await _read([FakeNdefApplet(_fixture('other-host-link'))]), _otp);
  });

  test('reads over short APDUs too', () async {
    expect(await _read([FakeNdefApplet(_fixture('yubico-link'))], extendedLength: false), _otp);
  });

  test('reads a message that comes in parts', () async {
    final applet = FakeNdefApplet(_fixture('yubico-link'))..readSize = 20;

    expect(await _read([applet]), _otp);
    expect(applet.commands.where((command) => command.startsWith('b0')), hasLength(5));
  });

  test('an empty message gives no code', () async {
    expect(await _read([FakeNdefApplet(const [])]), isNull);
    expect(await _read([FakeNdefApplet(_fixture('empty-record'))]), isNull);
  });

  test('a text record gives no code', () async {
    expect(await _read([FakeNdefApplet(_fixture('text-record'))]), isNull);
  });

  test('a tail outside the alphabet or the length gives no code', () async {
    expect(await _read([FakeNdefApplet(_fixture('outside-alphabet'))]), isNull);
    expect(await _read([FakeNdefApplet(_fixture('too-short'))]), isNull);
  });

  test('a status word other than success gives no code, and no exception escapes', () async {
    expect(await _read([FakeNdefApplet(_fixture('yubico-link'))..selectFileStatus = 0x6a82]), isNull);
    expect(await _read([FakeNdefApplet(_fixture('yubico-link'))..readStatus = 0x6982]), isNull);
    expect(await _read([FakeNdefApplet(_fixture('yubico-link'))..readStatus = 0x6f00]), isNull);
  });

  test('a key without the message application gives no code', () async {
    expect(await _read(const []), isNull);
  });

  test('an application iPhone was not told of gives no code', () async {
    final phone = FakeSecurityKeys(phone: FakeSecurityKeys.iphone)..declaredAids = {'a0000006472f0001'};

    expect(await _read([FakeNdefApplet(_fixture('yubico-link'))], phone: phone), isNull);

    phone.declaredAids = {'a0000006472f0001', 'd2760000850101'};
    expect(await _read([FakeNdefApplet(_fixture('yubico-link'))], phone: phone), _otp);
  });

  test('a message that says it is longer than a link could be gives no code', () async {
    final applet = FakeNdefApplet(Uint8List(2000));

    expect(await _read([applet]), isNull);
    expect(applet.commands, ['a4 00 0c', 'b0 00 00']);
  });

  test('a key taken away while it is read is the connection\'s error', () async {
    final phone = FakeSecurityKeys()..removeWhen = (frame) => frame[1] == 0xb0;
    phone.arrive(FakeKey(applets: [FakeNdefApplet(_fixture('yubico-link'))]).device(kinds: {SecurityKeyLinkKind.nfc}));

    await expectLater(runOnKey(phone, readOtpMessage, viaNfc: true, now: phone.now), throwsA(isA<SecurityKeyRemoved>()));
  });

  group('the message', () {
    test('takes what follows the last slash, hash, question mark or equals sign', () {
      Uint8List link(String rest) => Uint8List.fromList([0xd1, 0x01, rest.length + 1, 0x55, 0x04, ...rest.codeUnits]);

      expect(otpFromNdef(link('my.yubico.com/neo/$_otp')), _otp);
      expect(otpFromNdef(link('example.org/otp?code=$_otp')), _otp);
      expect(otpFromNdef(link(_otp)), _otp);
      expect(otpFromNdef(link('my.yubico.com/yk/#$_otp/')), isNull);
      expect(otpFromNdef(link('my.yubico.com/yk/#${_otp.toUpperCase()}')), isNull);
      expect(otpFromNdef(link('example.org/${'c' * 65}')), isNull);
      expect(otpFromNdef(link('example.org/${'c' * 64}')), 'c' * 64);
      expect(otpFromNdef(link('example.org/${'c' * 32}')), 'c' * 32);
      expect(otpFromNdef(link('example.org/${'c' * 31}')), isNull);
    });

    test('reads a record with a four-byte length and one with an id', () {
      final rest = 'my.yubico.com/yk/#$_otp'.codeUnits;
      final long = Uint8List.fromList([0xc1, 0x01, 0, 0, 0, rest.length + 1, 0x55, 0x04, ...rest]);
      final withId = Uint8List.fromList([0xd9, 0x01, rest.length + 1, 0x02, 0x55, 0x69, 0x64, 0x04, ...rest]);

      expect(otpFromNdef(long), _otp);
      expect(otpFromNdef(withId), _otp);
    });

    test('gives no code for a cut, chunked or foreign record', () {
      final whole = _fixture('yubico-link');

      expect(otpFromNdef(Uint8List.sublistView(whole, 0, 30)), isNull);
      expect(otpFromNdef(Uint8List(0)), isNull);
      expect(otpFromNdef(Uint8List.fromList([0xd1, 0x01])), isNull);
      // The chunk flag
      expect(otpFromNdef(Uint8List.fromList([whole[0] | 0x20, ...whole.sublist(1)])), isNull);
      // An absolute-URI record (type name format 3), not a well-known one
      expect(otpFromNdef(Uint8List.fromList([0xd3, ...whole.sublist(1)])), isNull);
      // Bytes that are no text
      expect(otpFromNdef(Uint8List.fromList([0xd1, 0x01, 0x03, 0x55, 0x04, 0xff, 0xfe])), isNull);
    });
  });
}
