/// Reading and naming other people's public keys for the contact screens:
/// the readers that run off the UI isolate, what a key is called before the
/// person names it, and the message for each way a key is refused.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../keys/key_bridge.dart';

/// What a code that carries a fingerprint and no key starts with, the form
/// OpenKeychain shows: `OPENPGP4FPR:` and the fingerprint in hexadecimal.
const fingerprintCodePrefix = 'OPENPGP4FPR:';

/// Reads every public key in [input], text or bytes, off the UI isolate:
/// checking an RSA 4096 key's signatures takes a moment. Throws
/// [crypto.KeyFormatException].
Future<List<crypto.PgpPublicKey>> readPublicKeysInBackground(Object input) =>
    Isolate.run(() => crypto.readPublicKeys(input), debugName: 'readPublicKeys');

/// Reads other people's keys; tests replace it with one that needs no isolate.
final publicKeyReaderProvider = Provider<Future<List<crypto.PgpPublicKey>> Function(Object input)>((ref) => readPublicKeysInBackground);

/// Merges two copies of one key off the UI isolate; tests replace it with
/// one that needs no isolate.
final publicKeyMergerProvider = Provider<Future<Uint8List> Function(Uint8List a, Uint8List b)>(
  (ref) =>
      (a, b) => Isolate.run(() => crypto.mergePublicKeys(a, b), debugName: 'mergePublicKeys'),
);

/// The fingerprint a fingerprint-only code holds, upper-case hexadecimal;
/// null when [text] is not such a code, and empty when it is one that is cut
/// or mistyped.
String? fingerprintOfCode(String text) {
  final trimmed = text.trim();
  if (!trimmed.toUpperCase().startsWith(fingerprintCodePrefix)) return null;
  final hex = trimmed.substring(fingerprintCodePrefix.length).replaceAll(RegExp(r'\s'), '').toUpperCase();
  return RegExp(r'^[0-9A-F]{40}$|^[0-9A-F]{64}$').hasMatch(hex) ? hex : '';
}

/// The name in a user ID: `Grace Hopper` of a user ID that goes on with a
/// comment in brackets and an address; its address when it has no name; the
/// user ID itself when it has neither.
String userIdName(String userId) {
  final cut = userId.indexOf('<');
  final name = _withoutComments(cut < 0 ? userId : userId.substring(0, cut)).trim();
  if (name.isNotEmpty && userIdAddress(name) == null) return name;
  return userIdAddress(userId) ?? userId.trim();
}

/// [text] without its comments, each from a `(` to the next `)`. One pass,
/// with no pattern: a user ID is its owner's to write, and a pattern tries
/// a row of `(` again from each of them.
String _withoutComments(String text) {
  final out = StringBuffer();
  var at = 0;
  while (true) {
    final open = text.indexOf('(', at);
    final close = open < 0 ? -1 : text.indexOf(')', open + 1);
    if (close < 0) {
      out.write(text.substring(at));
      return out.toString();
    }
    out.write(text.substring(at, open));
    at = close + 1;
  }
}

/// What a contact is called until the person renames it: the name of the
/// key's first user ID, or for a key without one, "Key" and the start of
/// its fingerprint.
String defaultContactName(crypto.PgpKeyInfo info, Messages messages) {
  final first = info.userIds.map(userIdName).where((name) => name.isNotEmpty).firstOrNull;
  if (first != null) return first;
  return messages.t('contacts.unnamed', {'id': crypto.fingerprintGroups(info.primary.fingerprintHex).take(2).join(' ')});
}

/// The email addresses in a key's user IDs, in lower case.
Set<String> keyAddresses(crypto.PgpKeyInfo? info) => {
  ...?info?.userIds.map(userIdAddress).nonNulls.map((address) => address.toLowerCase()),
};

/// [contact] with the addresses its check covers written down, when it was
/// checked by a version that did not keep them: the addresses of the key it
/// holds now, read this once, so that one its owner adds later is not taken
/// as checked. Any other contact comes back as it is, the same object.
Contact withCheckedAddresses(Contact contact) {
  final fingerprint = contact.checkedFingerprint;
  if (fingerprint == null || contact.checkedAddresses != null) return contact;
  final crypto.PgpKeyInfo info;
  try {
    info = crypto.readPgpKeyInfo(unb64(contact.publicKey));
  } on crypto.KeyFormatException {
    return contact;
  } on FormatException {
    return contact;
  }
  // A mark left by another key covers nothing, and stays as it is
  if (fingerprint.toUpperCase() != info.primary.fingerprintHex) return contact;
  return contact.copyWith(checkedAddresses: keyAddresses(info).toList()..sort());
}

/// The initials on a contact's tile: the first character of the first two
/// words of its name, as they are; one character for a single word.
String contactInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).take(2);
  return [for (final word in words) String.fromCharCode(word.runes.first)].join();
}

/// The message id of where a key came from; a source this version doesn't
/// know reads "another way".
String contactSourceId(String source) => switch (source) {
  ContactSource.qr => 'contacts.source.qr',
  ContactSource.file => 'contacts.source.file',
  ContactSource.paste => 'contacts.source.paste',
  ContactSource.keyserver => 'contacts.source.keyserver',
  _ => 'contacts.source.other',
};

/// Where a key came from, in words (openspec: add-key-lookup, decision 7):
/// for a key found in a domain's key directory, that domain's, read from
/// [sourceEmail]; otherwise what [contactSourceId] names.
String contactSourceText(Messages messages, String source, String? sourceEmail) {
  final at = sourceEmail?.lastIndexOf('@') ?? -1;
  if (source == ContactSource.wkd && at > 0) {
    return messages.t('contacts.source.wkd', {'domain': sourceEmail!.substring(at + 1).toLowerCase()});
  }
  return messages.t(contactSourceId(source));
}

/// The message, with its arguments, for why someone's key was refused.
({String id, Map<String, Object?> args}) contactProblem(crypto.KeyFormatException error) => switch (error.problem) {
  crypto.KeyProblem.damaged when error.detail == crypto.pgpFailsOwnChecks => (id: 'contacts.error.failsChecks', args: const {}),
  crypto.KeyProblem.damaged => (id: 'contacts.error.damaged', args: const {}),
  crypto.KeyProblem.unsupportedKeyType => (id: 'contacts.error.unsupportedKeyType', args: {'detail': error.detail ?? ''}),
  crypto.KeyProblem.tooLarge => (id: 'contacts.error.tooLarge', args: const {}),
  crypto.KeyProblem.privateKeyGiven => (id: 'contacts.error.privateKeyGiven', args: const {}),
  _ => (id: 'contacts.error.unrecognized', args: const {}),
};

/// The contacts of [contacts] whose key passes the checks a key is read
/// with, each holding its key as that reading gives it: a file is outside
/// input, so what an import brings is read again with [read] before it is
/// kept. One whose key fails, or holds anything but one key, is left out.
Future<List<Contact>> soundContacts(List<Contact> contacts, Future<List<crypto.PgpPublicKey>> Function(Object input) read) async {
  final sound = <Contact>[];
  for (final contact in contacts) {
    try {
      final keys = await read(unb64(contact.publicKey));
      if (keys.length == 1) sound.add(contact.copyWith(publicKey: b64(keys.single.bytes)));
    } on crypto.KeyFormatException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return sound;
}
