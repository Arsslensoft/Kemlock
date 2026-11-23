// Copies the armored sample keys, messages and signatures of RFC 9980
// appendix A out of the RFC's text, without its indentation, as
// `tool/keys/rfc9580_keys.py` did for RFC 9580's keys, and the values the
// RFC prints beside them (fingerprints, the key shares and the output of
// the key combiner, the session keys) into `values.json`. It is Dart
// because the machine it ran on has no Python.
//
// Run once on 2026-11-17 to make test/fixtures/keys/rfc9980; never rerun
// over it. It refuses to overwrite a file.
//
//   dart run tool/keys/rfc9980_vectors.dart <rfc9980.txt> <output dir>
//
// The text is https://www.rfc-editor.org/rfc/rfc9980.txt, which has no
// page breaks.

import 'dart:convert';
import 'dart:io';

/// The file each subsection's block goes to, by the subsection's title.
const _names = {
  'Transferable Secret Key': 'secret',
  'Transferable Public Key': 'public',
  'Encrypted and Signed Message': 'message',
  'Encrypted and Signed SEIPD v1 Message': 'message-seipd1',
  'Encrypted and Signed SEIPD v2 Message': 'message-seipd2',
  'Detached Signature': 'signature',
};

/// The sentences that introduce a printed value, and its name in
/// `values.json`.
const _values = {
  'The primary key has the fingerprint': 'primaryFingerprint',
  'The subkey has the fingerprint': 'subkeyFingerprint',
  'The hex-encoded mlkemKeyShare input to multiKeyCombine is': 'mlkemKeyShare',
  'The hex-encoded ecdhKeyShare input to multiKeyCombine is': 'ecdhKeyShare',
  'The hex-encoded output of multiKeyCombine is': 'multiKeyCombine',
  'The hex-encoded session key is': 'sessionKey',
};

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/keys/rfc9980_vectors.dart <rfc9980.txt> <output dir>');
    exit(64);
  }
  final lines = const LineSplitter().convert(File(args[0]).readAsStringSync().replaceAll('\r\n', '\n'));
  final out = Directory(args[1])..createSync(recursive: true);
  final start = lines.indexWhere((l) => l.startsWith('Appendix A.  Test Vectors'));
  final end = lines.indexWhere((l) => l.startsWith('Acknowledgments'), start);

  final files = <String, String>{};
  final values = <String, Map<String, String>>{};
  String? section; // a1, a2, ...
  String? file; // a1-secret, ...
  for (var i = start; i < end; i++) {
    final line = lines[i];
    final heading = RegExp(r'^A\.(\d+)\.(\d+)\.  (.+)$').firstMatch(line);
    if (heading != null) {
      section = 'a${heading[1]}';
      final name = _names[heading[3]!.trim()];
      if (name == null) throw StateError('no file name for "${heading[3]}"');
      file = '$section-$name';
      continue;
    }
    final text = line.trim();
    final value = _values[text];
    if (value != null) {
      // The value runs over one or more lines and ends with a full stop
      final hex = StringBuffer();
      while (!hex.toString().endsWith('.')) {
        hex.write(lines[++i].trim());
      }
      final digits = hex.toString().substring(0, hex.length - 1);
      if (!RegExp(r'^[0-9a-f]+$').hasMatch(digits)) throw StateError('not hex: $digits');
      final key = value.endsWith('Fingerprint') ? section! : file!;
      (values[key] ??= {})[value] = digits;
      continue;
    }
    if (text.startsWith('-----BEGIN PGP ')) {
      final block = <String>[];
      while (true) {
        final t = lines[i].trim();
        block.add(t);
        if (t.startsWith('-----END PGP ')) break;
        i++;
      }
      if (files.containsKey(file)) throw StateError('two blocks for $file');
      files[file!] = '${block.join('\n')}\n';
    }
  }

  for (final MapEntry(:key, :value) in files.entries) {
    final target = File('${out.path}/$key.asc');
    if (target.existsSync()) throw StateError('${target.path} exists');
    target.writeAsStringSync(value);
    stdout.writeln('$key.asc: ${value.split('\n').length - 1} lines');
  }
  final target = File('${out.path}/values.json');
  if (target.existsSync()) throw StateError('${target.path} exists');
  target.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(values)}\n');
  stdout.writeln('values.json: ${values.length} entries');
}
