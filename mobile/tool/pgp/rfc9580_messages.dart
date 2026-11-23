// Copies the armored sample messages of RFC 9580 appendices A.6 to A.11
// out of the RFC's text, without its indentation, as
// `tool/keys/rfc9580_keys.py` did for the keys. It is Dart because the
// machine it ran on has no Python.
//
// Run once on 2026-11-16 to make test/fixtures/pgp/rfc9580; never rerun
// over it. It refuses to overwrite a file.
//
//   dart run tool/pgp/rfc9580_messages.dart <rfc9580.txt> <output dir>
//
// The text is https://www.rfc-editor.org/rfc/rfc9580.txt, which has no
// page breaks.

import 'dart:io';

void main(List<String> args) {
  final text = File(args[0]).readAsStringSync().replaceAll('\r\n', '\n');
  final out = args[1];

  String block(String section, String nextSection, String begin, String end) {
    final start = text.lastIndexOf(section);
    final stop = text.indexOf(nextSection, start);
    final part = text.substring(start, stop);
    final from = part.indexOf('-----BEGIN PGP $begin-----');
    final to = part.indexOf('-----END PGP $end-----') + '-----END PGP $end-----'.length;
    // The RFC indents its figures by three spaces; lines inside a
    // clear-signed text keep whatever follows those three.
    final lines = [
      for (final line in part.substring(from, to).split('\n'))
        line.startsWith('   ') ? line.substring(3) : line,
    ];
    return '${lines.join('\n')}\n';
  }

  final files = {
    'a6-cleartext-signed.asc': block('A.6.  Sample Cleartext Signed Message', 'The Signature packet here is', 'SIGNED MESSAGE', 'SIGNATURE'),
    'a7-inline-signed.asc': block('A.7.  Sample Inline-Signed Message', 'A.8.  Sample', 'MESSAGE', 'MESSAGE'),
    'a8-x25519-ocb.asc': block('A.8.5.  Complete', 'A.9.  Sample', 'MESSAGE', 'MESSAGE'),
    'a9-skesk6-eax.asc': block('A.9.5.  Complete', 'A.10.  Sample', 'MESSAGE', 'MESSAGE'),
    'a10-skesk6-ocb.asc': block('A.10.5.  Complete', 'A.11.  Sample', 'MESSAGE', 'MESSAGE'),
    'a11-skesk6-gcm.asc': block('A.11.5.  Complete', 'A.12.  Sample', 'MESSAGE', 'MESSAGE'),
  };
  for (final MapEntry(key: name, value: content) in files.entries) {
    final file = File('$out/$name');
    if (file.existsSync()) {
      stderr.writeln('$name exists; the fixtures are never regenerated');
      exit(1);
    }
    file.writeAsStringSync(content);
    stdout.writeln('$name ${content.split('\n').length - 1} lines');
  }
}
