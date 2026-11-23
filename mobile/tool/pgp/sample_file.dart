// Writes the plain file the large GnuPG fixtures were made from: [size]
// bytes of a xorshift32 stream, which does not compress. The tests make
// the same bytes (`sampleBytes` in test/crypto/pgp/fixtures.dart) instead
// of keeping 5 MB of them in git.
//
//   dart run tool/pgp/sample_file.dart <file> <size>

import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  final size = int.parse(args[1]);
  final out = Uint8List(size);
  var x = 0x4b454d4c;
  for (var i = 0; i < size; i++) {
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    out[i] = x & 0xff;
  }
  File(args[0]).writeAsBytesSync(out);
}
