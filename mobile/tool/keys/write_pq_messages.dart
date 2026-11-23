// Writes, with Kemlock's message code, what tool/keys/gnupg_check.sh and
// tool/keys/sequoia_check.sh open and verify to check the post-quantum
// keys from the other side (task 6.4 of add-post-quantum-pgp), into
// <keys>/messages, from the unprotected keys tool/keys/write_pgp_keys.dart
// wrote into <keys>. Run it from mobile/:
//
//   dart run tool/keys/write_pq_messages.dart <keys>
//
// - to-standard.asc: to the standard key, signed by it (PKESK 6, SEIPD 2)
// - to-gnupg.gpg: to the GnuPG-format key, signed by it (PKESK 3, SEIPD 1)
// - to-all.gpg: to the standard, the GnuPG-format and the RSA 4096 key at
//   once (PKESK 3 of algorithms 35, 8 and 1, SEIPD 1)
// - standard.sig and standard.clear.asc: a detached and a clear-text
//   signature by the standard key; gnupg.sig: a detached one by the
//   GnuPG-format key
// - message.txt: what each holds or signs

import 'dart:io';
import 'dart:typed_data';

import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/crypto/keys/pgp.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/keys/write_pq_messages.dart <keys>');
    exit(64);
  }
  final keys = args[0];
  final out = Directory('$keys/messages');
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists');
    exit(1);
  }
  out.createSync();
  final message = Uint8List.fromList('A message Kemlock wrote for a post-quantum key.\nIts second line.\n'.codeUnits);
  File('${out.path}/message.txt').writeAsBytesSync(message);
  Uint8List key(String name) => readArmorBlock(File('$keys/$name').readAsBytesSync());
  final standard = PgpSecretKey(key('pq-standard.unprotected.asc'));
  final gnupg = PgpSecretKey(key('pq-gnupg.unprotected.asc'));
  final data = PgpData.bytes(message);

  File('${out.path}/to-standard.asc')
      .writeAsBytesSync((await encrypt(data: data, recipients: [key('pq-standard.public.asc')], signer: standard, text: true))!);
  File('${out.path}/to-gnupg.gpg').writeAsBytesSync(
    (await encrypt(data: data, recipients: [key('pq-gnupg.public.asc')], signer: gnupg, text: false, fileName: 'message.txt'))!,
  );
  File('${out.path}/to-all.gpg').writeAsBytesSync(
    (await encrypt(
      data: data,
      recipients: [key('pq-standard.public.asc'), key('pq-gnupg.public.asc'), key('rsa4096.public.asc')],
      text: false,
      fileName: 'message.txt',
    ))!,
  );
  File('${out.path}/standard.sig').writeAsBytesSync(await sign(data: data, signer: standard, form: PgpSignatureForm.detached));
  File('${out.path}/standard.clear.asc').writeAsBytesSync(await sign(data: data, signer: standard, form: PgpSignatureForm.cleartext));
  File('${out.path}/gnupg.sig').writeAsBytesSync(await sign(data: data, signer: gnupg, form: PgpSignatureForm.detached));
  stdout.writeln('wrote ${out.listSync().length} files into ${out.path}');
}
