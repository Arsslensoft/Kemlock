import 'dart:typed_data';

import 'fake_security_keys.dart';

/// The NFC message (NDEF) application of a [FakeKey], as an NFC Forum Type
/// 4 tag has it: a message file (`E104`) that starts with the message's
/// length in two bytes, read with READ BINARY once it was selected
/// (openspec: add-vaultwarden-security-key). A YubiKey puts a link ending
/// in its one-time password there.
///
/// A [FakeApplet] is not told how many bytes a command asks for, so a
/// read gives the file from the offset to its end, or [readSize] bytes of
/// it when that is set; a real card gives exactly what was asked.
///
/// ```dart
/// final key = FakeKey(applets: [FakeNdefApplet(message)]);
/// phone.arrive(key.device(kinds: {SecurityKeyLinkKind.nfc}));
/// ```
class FakeNdefApplet extends FakeApplet {
  FakeNdefApplet(List<int> message) : message = Uint8List.fromList(message);

  /// The NDEF message, without its length.
  Uint8List message;

  /// The status word of selecting the message file, when it is to fail.
  int? selectFileStatus;

  /// The status word of reading, when it is to fail.
  int? readStatus;

  /// The most bytes one read gives; null for the rest of the file.
  int? readSize;

  /// Every command received, as `ins p1 p2` in hex.
  final commands = <String>[];

  bool _fileSelected = false;

  @override
  List<int> get aid => const [0xd2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01];

  Uint8List get _file => Uint8List.fromList([message.length >> 8, message.length & 0xff, ...message]);

  @override
  (List<int>, int) command(int cla, int ins, int p1, int p2, Uint8List data) {
    commands.add([ins, p1, p2].map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' '));
    switch (ins) {
      case 0xa4:
        if (p1 != 0x00 || data.length != 2) return (const [], 0x6a86);
        if (selectFileStatus case final status?) return (const [], status);
        // E103 is the capability container, E104 the message
        if (data[0] != 0xe1 || (data[1] != 0x03 && data[1] != 0x04)) return (const [], 0x6a82);
        _fileSelected = data[1] == 0x04;
        return (const [], 0x9000);
      case 0xb0:
        if (!_fileSelected) return (const [], 0x6986);
        if (readStatus case final status?) return (const [], status);
        final file = _file;
        final offset = p1 << 8 | p2;
        if (offset > file.length) return (const [], 0x6b00);
        final end = readSize == null || offset + readSize! > file.length ? file.length : offset + readSize!;
        return (file.sublist(offset, end), 0x9000);
      default:
        return (const [], 0x6d00);
    }
  }
}
