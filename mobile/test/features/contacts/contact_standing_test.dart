import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/crypto/keys/openpgp/edit.dart' show changePgpKey;
import 'package:kemlock/crypto/keys/openpgp/key_info.dart' show transferablePublicKey;
import 'package:kemlock/crypto/keys/openpgp/packets.dart' show readPackets;
import 'package:kemlock/features/contacts/contact_keys.dart' show withCheckedAddresses;
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/models/contact.dart';

import 'contacts_kit.dart';

void main() {
  final checkedAt = DateTime(2026, 11, 3, 9, 30).millisecondsSinceEpoch;

  test('checked when the fingerprint that was compared is the one of the key it holds', () {
    final standing = contactStanding(contactOf(grace1, checkedAt: checkedAt), contactsNow);

    expect(standing.checked, isTrue);
    expect(standing.checkedOn, DateTime(2026, 11, 3, 9, 30));
    expect(standing.fingerprint, graceFingerprint);
    expect(standing.key.standing, Standing.ok);
    expect(standing.canEncrypt, isTrue);
  });

  test('not checked when the fingerprint that was compared names another key', () {
    // Another key put under the same contact, by a sync merge or an edit elsewhere: the mark does not follow it
    final swapped = contactOf(grace1, checkedAt: checkedAt).copyWith(publicKey: contactOf(alan).publicKey);

    final standing = contactStanding(swapped, contactsNow);

    expect(standing.checked, isFalse);
    expect(standing.checkedOn, isNull);
    expect(standing.fingerprint, alanFingerprint);
  });

  test('not checked when nothing was compared, or when only a date is left', () {
    expect(contactStanding(contactOf(grace1), contactsNow).checked, isFalse);

    final dateOnly = Contact.fromJson({...contactOf(grace1).toJson(), 'checkedAt': checkedAt});
    expect(contactStanding(dateOnly, contactsNow).checked, isFalse);
  });

  test('a fingerprint written in lower case still counts', () {
    final lower = contactOf(grace1).checked(graceFingerprint.toLowerCase(), checkedAt);

    expect(contactStanding(lower, contactsNow).checked, isTrue);
  });

  test('an expired key is expired and cannot be encrypted to, checked or not', () {
    final standing = contactStanding(contactOf(expired, checkedAt: checkedAt), contactsNow);

    expect(standing.key.standing, Standing.expired);
    expect(standing.key.expires, DateTime.utc(2020, 12, 31, 12));
    expect(standing.canEncrypt, isFalse);
    expect(standing.checked, isTrue);
  });

  test('a key expires on its date: usable the second before, expired from it on', () {
    final contact = contactOf(grace1);
    final expires = contactStanding(contact, contactsNow).key.expires!;

    expect(contactStanding(contact, expires.subtract(const Duration(seconds: 1))).canEncrypt, isTrue);
    expect(contactStanding(contact, expires).canEncrypt, isFalse);
    expect(contactStanding(contact, expires).key.standing, Standing.expired);
  });

  test('a revoked key is revoked and cannot be encrypted to', () {
    for (final path in [revoked, grace3]) {
      final standing = contactStanding(contactOf(path), contactsNow);

      expect(standing.key.standing, Standing.revoked, reason: path);
      expect(standing.canEncrypt, isFalse, reason: path);
    }
  });

  test('a key that only signs has no key to encrypt to', () {
    final standing = contactStanding(contactOf(signOnly), contactsNow);

    expect(standing.key.standing, Standing.ok);
    expect(standing.canEncrypt, isFalse);
  });

  test('a key whose only encryption subkey expired cannot be encrypted to, though the key is in order', () {
    final standing = contactStanding(contactOf('gnupg/expiry/subkey-expired.public.asc'), contactsNow);

    expect(standing.key.standing, Standing.ok);
    expect(standing.canEncrypt, isFalse);
  });

  test('an RSA key and the version 6 key can be encrypted to', () {
    expect(contactStanding(contactOf(rsa3072), contactsNow).canEncrypt, isTrue);
    expect(contactStanding(contactOf(v6), contactsNow).canEncrypt, isTrue);
  });

  test('a key that cannot be read is not checked and cannot be encrypted to', () {
    for (final public in ['', 'not base64 !', 'AAAA']) {
      final broken = contactOf(grace1, checkedAt: checkedAt).copyWith(publicKey: public);

      final standing = contactStanding(broken, contactsNow);

      expect((standing.checked, standing.canEncrypt, standing.info, standing.fingerprint), (false, false, null, null), reason: public);
      expect(standing.key, KeyStanding.ok);
    }
  });

  // A fingerprint compared proves whose key it is; the addresses in it are what its owner says
  group('the addresses a check covers', () {
    // Grace's key as a later copy brings it, with an address she added after it was checked
    late Contact grown;

    setUpAll(() async {
      final secret = (await readPrivateKey(keyText('contacts/grace-1.secret.asc'))).private;
      final later = await changePgpKey(
        secret,
        const AddPgpUserId(name: 'Alice', email: 'Alice@Corp.com'),
        now: contactsNow,
      );
      grown = contactOf(grace1).copyWith(publicKey: b64((await readPublicKeys(transferablePublicKey(readPackets(later)))).single.bytes));
    });

    test('are those the key carried when it was checked, and no address added since', () {
      final standing = contactStanding(grown.checked(graceFingerprint, checkedAt, addresses: ['grace@example.org']), contactsNow);

      expect(standing.checked, isTrue);
      expect(standing.confirmedAddresses, {'grace@example.org'});
      expect(standing.uncheckedAddresses, {'alice@corp.com'});
    });

    test('are none when it is not checked, or checked for another key', () {
      final swapped = grown.checked(alanFingerprint, checkedAt, addresses: ['grace@example.org', 'alice@corp.com']);

      for (final contact in [grown, swapped]) {
        final standing = contactStanding(contact, contactsNow);
        expect(standing.confirmedAddresses, isEmpty);
        expect(standing.uncheckedAddresses, {'grace@example.org', 'alice@corp.com'});
      }
    });

    test('are those of the key as the vault first reads it, for a check that kept none', () {
      // Until then, all of them
      expect(contactStanding(grown.checked(graceFingerprint, checkedAt), contactsNow).confirmedAddresses, {
        'grace@example.org',
        'alice@corp.com',
      });

      final written = withCheckedAddresses(contactOf(grace1, checkedAt: checkedAt));
      expect(written.checkedAddresses, ['grace@example.org']);
      expect(contactStanding(written.copyWith(publicKey: grown.publicKey), contactsNow).confirmedAddresses, {'grace@example.org'});

      // Nothing to write for a contact not checked, checked for another key, or written down already
      final other = contactOf(grace1, checkedAt: checkedAt).copyWith(publicKey: contactOf(alan).publicKey);
      for (final contact in [contactOf(grace1), other, written]) {
        expect(identical(withCheckedAddresses(contact), contact), isTrue);
      }
    });
  });
}
