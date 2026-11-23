// Other people's public keys through Vaultwarden (openspec: add-pgp-contacts,
// tasks 8.1 and 8.2): the `contact` entry kind sealed and plain, the plain
// item a Bitwarden app shows, what comes back from an edit there, and the
// agreement a plain home waits for.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_formats.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_items.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../contacts/contacts_kit.dart';
import '../../keys/pgp_kit.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

/// One phone syncing a vault's own entries with the home.
class _Phone {
  _Phone(this.server, this.target);

  final FakeVaultwarden server;
  VaultwardenTarget target;
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);
  late VwCredentials credentials = server.credentials();

  VaultwardenScopeSync get _scope => VaultwardenScopeSync(
    connection: VwConnection(
      api: VwApi(server.client),
      server: FakeVaultwarden.url,
      credentials: credentials,
      onCredentials: (next) async => credentials = next,
    ),
    reader: VwReader(server.userKey),
    target: target,
  );

  Future<VwSyncResult> sync() async {
    final at = server.revision + 500;
    final result = await _scope.sync(lists, state, now: at);
    lists = applyScope(lists, null, result.doc);
    state = ScopeState(known: result.known, lastSyncAt: at, extra: result.state);
    return result;
  }

  Future<VwSyncPreview> preview() => _scope.preview(lists, now: server.revision + 500);
}

const _account = OtpAccount(id: 'a1', issuer: 'GitHub', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
const _checkedAt = 1793696400000;
const _onKey = KeyAccount(id: 'ka1', device: '0102030405060708', name: 'Example:alice', issuer: 'Example', label: 'alice', addedAt: 1);

Contact _grace({String? note = 'Compared on a call'}) => contactOf(grace1, checkedAt: _checkedAt, note: note);
Contact _alan() => contactOf(alan, id: 'c2', name: 'Alan Turing', source: ContactSource.file);

Future<String?> _open(Object? value, BwKey key) async => value is String ? bwDecryptString(value, key) : null;

/// The item's custom fields, decrypted, by name.
Future<Map<String, String?>> _fields(Map<String, Object?> cipher, BwKey key) async => {
  for (final field in (cipher['fields'] as List<Object?>? ?? const []).cast<Map<String, Object?>>())
    (await _open(field['name'], key))!: await _open(field['value'], key),
};

/// The items of the home that hold an entry, by the entry's id, with their decrypted field.
Future<Map<String, ({Map<String, Object?> cipher, String field})>> _items(FakeVaultwarden server) async {
  final found = <String, ({Map<String, Object?> cipher, String field})>{};
  for (final cipher in server.ciphers.values) {
    if (cipher['deletedDate'] != null) continue;
    final field = (await _fields(cipher, server.userKey))[fieldName];
    if (field == null) continue;
    final id = (sealedHeader(field) ?? plainHeader(field))?.id;
    if (id != null) found[id] = (cipher: cipher, field: field);
  }
  return found;
}

/// A Bitwarden app's edit of an item's name and notes.
Future<void> _editInBitwarden(FakeVaultwarden server, Map<String, Object?> cipher, {String? name, String? notes}) async {
  final key = server.userKey;
  server.put({
    ...cipher,
    if (name != null) 'name': await bwEncryptString(name, key),
    if (notes != null) 'notes': await bwEncryptString(notes, key),
  }, id: cipher['id']! as String);
}

void main() {
  late FakeVaultwarden server;

  setUp(() => server = FakeVaultwarden());

  group('the formats', () {
    test('a contact seals and opens again unchanged, naming only its id and the home in the clear', () async {
      final key = randomBytes(32);
      final contact = _grace();

      final sealed = await sealEntry(contact, 'home-1', key);

      expect(sealedHeader(sealed), (home: 'home-1', id: 'c1'));
      expect(sealed, isNot(contains('Grace')));
      expect(sealed, isNot(contains(graceFingerprint)));
      expect(await openSealedEntry(sealed, key), contact);
    });

    test('a contact in a plain field is read again unchanged, with its kind named contact', () {
      final contact = _grace();
      final field = PlainField(home: 'home-1', own: true, sum: valuesSum(laterValues(contact)), entry: contact);

      final read = PlainField.tryParse(field.toText())!;

      expect((jsonDecode(field.toText()) as Map<String, Object?>)['kind'], 'contact');
      expect((read.kind, read.entry), (EntryKind.contact, contact));
    });

    test('what a plain item shows: the name, the armored key, then the note after a rule, and never a favourite', () {
      final armored = writeArmor(pgpPublicKeyBlock, keyBytes(grace1)).trimRight();

      expect(laterValues(_grace()), {'name': 'Grace Hopper', 'notes': '$armored\n\n---\nCompared on a call', 'favorite': false});
      expect(laterValues(_grace(note: null))['notes'], armored);
      expect(laterValues(_grace().copyWith(name: '  '))['name'], untitledKeyName);
      expect(armored, keyText(grace1).trimRight());
    });
  });

  group('a sealed home', () {
    test('carries contacts and their checks to another phone, with no agreement asked', () async {
      final target = await makeHome(server, VaultwardenMode.sealed);
      final phone = _Phone(server, target)..lists = Lists(accounts: const [_account], contacts: [_grace(), _alan()]);

      final preview = await phone.preview();
      final first = await phone.sync();
      await phone.sync();

      expect(preview.paused, isEmpty);
      expect(preview.toVault[EntryKind.contact], 2);
      expect(first.state['paused'], isNull);
      final items = await _items(server);
      expect(await _open(items['c1']!.cipher['name'], server.userKey), sealedEntryName);
      expect(items['c1']!.field, startsWith('kemlock-sealed:1:${target.home}:c1:'));
      final other = _Phone(server, target);
      await other.sync();
      expect(other.lists.contacts, [_grace(), _alan()]);
      expect(contactStanding(other.lists.contacts.first, contactsNow).checked, isTrue);
      expect(contactStanding(other.lists.contacts.last, contactsNow).checked, isFalse);
    });

    test('a check made on one phone and a deletion made on the other both arrive', () async {
      final target = await makeHome(server, VaultwardenMode.sealed);
      final phone = _Phone(server, target)..lists = Lists(contacts: [_grace(), _alan()]);
      await phone.sync();
      final other = _Phone(server, target);
      await other.sync();

      final at = server.revision + 1000;
      other.lists = Lists(contacts: [other.lists.contacts.first, other.lists.contacts.last.checked(alanFingerprint, at).stamped(at)]);
      await other.sync();
      phone.lists = Lists(contacts: [phone.lists.contacts.last]);
      await phone.sync();
      await other.sync();

      for (final lists in [phone.lists, other.lists]) {
        expect(lists.contacts.map((c) => c.id), ['c2']);
        expect(lists.contacts.single.checkedFingerprint, alanFingerprint);
      }
    });
  });

  group('a plain home', () {
    test('writes no contact before the user agrees, says how many wait, and keeps them here', () async {
      final target = await makeHome(server, VaultwardenMode.plain);
      final phone = _Phone(server, target)..lists = Lists(accounts: const [_account], contacts: [_grace(), _alan()]);

      final preview = await phone.preview();
      final result = await phone.sync();
      final again = await phone.sync();

      expect(preview.paused, {EntryKind.contact: 2});
      expect(result.state['paused'], {'contact': 2});
      expect(again.state['paused'], {'contact': 2});
      expect((await _items(server)).keys, ['a1'], reason: 'the codes still sync');
      // Their absence there is never taken for a deletion
      expect(phone.lists.contacts, [_grace(), _alan()]);
      expect(phone.state.known, ['a1']);
    });

    test('agreeing writes them, each as a secure note with the armored key, the note, no hidden field and the Kemlock field', () async {
      final target = await makeHome(server, VaultwardenMode.plain);
      final phone = _Phone(server, target)..lists = Lists(contacts: [_grace(), _alan()]);
      await phone.sync();

      phone.target = target.copyWith(plainKinds: {'contact'});
      final agreed = await phone.sync();

      expect(agreed.state['paused'], isNull);
      final key = server.userKey;
      final item = (await _items(server))['c1']!;
      expect(item.cipher['type'], CipherType.secureNote);
      expect(await _open(item.cipher['name'], key), 'Grace Hopper');
      final armored = writeArmor(pgpPublicKeyBlock, keyBytes(grace1)).trimRight();
      expect(await _open(item.cipher['notes'], key), '$armored\n\n---\nCompared on a call');
      expect(item.cipher['favorite'], isFalse);
      expect(item.cipher['folderId'], target.folderId);
      expect((await _fields(item.cipher, key)).keys, [fieldName], reason: 'a public key needs no hidden field');
      final field = PlainField.tryParse(item.field)!;
      expect((field.kind, field.entry, field.own), (EntryKind.contact, _grace(), true));
      // An unchecked contact's note is its key alone
      expect(await _open((await _items(server))['c2']!.cipher['notes'], key), writeArmor(pgpPublicKeyBlock, keyBytes(alan)).trimRight());
    });

    test('two phones sync a contact, its check and its deletion through it', () async {
      final target = await makeHome(server, VaultwardenMode.plain, plainKinds: {...agreedToAll, 'contact'});
      final phone = _Phone(server, target)..lists = Lists(contacts: [_grace(), _alan()]);
      await phone.sync();
      final other = _Phone(server, target);
      await other.sync();
      expect(other.lists.contacts, [_grace(), _alan()]);

      final at = server.revision + 1000;
      other.lists = Lists(contacts: [other.lists.contacts.first.unchecked().stamped(at), other.lists.contacts.last]);
      await other.sync();
      await phone.sync();
      expect(contactStanding(phone.lists.contacts.first, contactsNow).checked, isFalse);

      phone.lists = Lists(contacts: [phone.lists.contacts.first]);
      await phone.sync();
      await other.sync();
      expect(other.lists.contacts.map((c) => c.id), ['c1']);
    });

    test('a rename and a note edit made in Bitwarden come back, with the same key and the same check', () async {
      final target = await makeHome(server, VaultwardenMode.plain, plainKinds: {'contact'});
      final phone = _Phone(server, target)..lists = Lists(contacts: [_grace()]);
      await phone.sync();
      final armored = writeArmor(pgpPublicKeyBlock, keyBytes(grace1)).trimRight();

      await _editInBitwarden(server, (await _items(server))['c1']!.cipher, name: 'Grace (work)', notes: '$armored\n\n---\nMet in Lisbon');
      final edited = (await _items(server))['c1']!.cipher;
      await phone.sync();

      final contact = phone.lists.contacts.single;
      expect((contact.name, contact.note), ('Grace (work)', 'Met in Lisbon'));
      expect(contact.updatedAt, DateTime.parse(edited['revisionDate']! as String).millisecondsSinceEpoch);
      expect(contact.publicKey, _grace().publicKey);
      expect((contact.checkedAt, contact.checkedFingerprint), (_checkedAt, graceFingerprint));
      expect(contactStanding(contact, contactsNow).checked, isTrue);
      final other = _Phone(server, target);
      await other.sync();
      expect(other.lists.contacts.single, contact);
    });

    test('another key pasted into the note changes neither the key nor the check', () async {
      final target = await makeHome(server, VaultwardenMode.plain, plainKinds: {'contact'});
      final phone = _Phone(server, target)..lists = Lists(contacts: [_grace()]);
      await phone.sync();
      final swapped = writeArmor(pgpPublicKeyBlock, keyBytes(graceOther)).trimRight();

      await _editInBitwarden(server, (await _items(server))['c1']!.cipher, notes: '$swapped\n\n---\nCompared on a call');
      await phone.sync();
      await phone.sync();

      final contact = phone.lists.contacts.single;
      expect(contact.publicKey, _grace().publicKey);
      expect((contact.checkedAt, contact.checkedFingerprint, contact.note), (_checkedAt, graceFingerprint, 'Compared on a call'));
      expect(contactStanding(contact, contactsNow).fingerprint, graceFingerprint);
      // The key is read from the Kemlock field alone, on this phone and on any other
      final other = _Phone(server, target);
      await other.sync();
      expect(other.lists.contacts.single.publicKey, _grace().publicKey);
      expect(contactStanding(other.lists.contacts.single, contactsNow).checked, isTrue);
    });

    test('a key too long for the server stays on the phone and is named, as a key is', () async {
      final target = await makeHome(server, VaultwardenMode.plain, plainKinds: {'contact'});
      final long = contactOf('kemlock/pgp-rsa4096.public.asc', id: 'c-long', name: 'Long');
      expect(tooLongForNotes(laterValues(long)['notes'] as String?), isFalse, reason: 'an RSA 4096 key still fits');
      final tooLong = long.copyWith(note: 'x' * 9000);
      final phone = _Phone(server, target)..lists = Lists(contacts: [tooLong, _alan()]);

      final result = await phone.sync();

      expect(result.state['tooLong'], ['c-long']);
      expect((await _items(server)).keys, ['c2']);
      expect(phone.lists.contacts.map((c) => c.id), ['c-long', 'c2']);
    });
  });

  // A run hands back the contacts the home holds and this phone's accounts on a security key, which no home holds
  for (final mode in VaultwardenMode.values) {
    test('a run in a ${mode.name} home keeps both the contacts and the accounts on a security key', () async {
      final target = await makeHome(server, mode, plainKinds: {...agreedToAll, 'contact'});
      final phone = _Phone(server, target)..lists = Lists(accounts: const [_account], contacts: [_grace()], keyAccounts: const [_onKey]);

      await phone.sync();
      expect([for (final contact in phone.lists.contacts) contact.id], ['c1']);
      expect(phone.lists.keyAccounts, const [_onKey]);
      // A run with nothing changed, which stops at the revision date
      await phone.sync();
      expect([for (final contact in phone.lists.contacts) contact.id], ['c1']);
      expect(phone.lists.keyAccounts, const [_onKey]);

      final other = _Phone(server, target);
      await other.sync();
      expect([for (final contact in other.lists.contacts) contact.id], ['c1']);
      expect(other.lists.keyAccounts, isEmpty, reason: 'Vaultwarden holds none of them');
    });

    // Joined with add-pgp-key-editing: combining two copies of a PGP key, and writing its item's private half again
    test('a run in a ${mode.name} home that combines a PGP key keeps the contacts and the accounts on a security key', () async {
      final target = await makeHome(server, mode, plainKinds: {...agreedToAll, 'contact'});
      final before = await pgpVaultKey(updatedAt: 100);
      final phone = _Phone(server, target)..lists = Lists(keys: [before], contacts: [_grace()], keyAccounts: const [_onKey]);
      await phone.sync();

      // GnuPG's copy of the key after a change, which the run combines with the one written before
      final after = await pgpVaultKey(path: 'gnupg/editing/signing-subkey.after.secret.asc', updatedAt: server.revision + 100);
      phone.lists = Lists(keys: [after], contacts: phone.lists.contacts, keyAccounts: phone.lists.keyAccounts);
      await phone.sync();

      expect(crypto.readPgpKeyInfo(unb64(phone.lists.keys.single.privateKey)).subkeys, hasLength(3));
      expect([for (final contact in phone.lists.contacts) contact.id], ['c1']);
      expect(phone.lists.keyAccounts, const [_onKey]);
      final other = _Phone(server, target);
      await other.sync();
      expect(other.lists.keys, phone.lists.keys);
      expect([for (final contact in other.lists.contacts) contact.id], ['c1']);
    });
  }

  test('the sum of a scope without contacts is what it was before contacts', () {
    const lists = Lists(accounts: [_account]);

    // "contacts" is hashed only when there is one, as the other later kinds are
    expect(scopeSum(lists), scopeSum(const Lists(accounts: [_account], contacts: [])));
    expect(scopeSum(Lists(accounts: const [_account], contacts: [_alan()])), isNot(scopeSum(lists)));
  });
}
