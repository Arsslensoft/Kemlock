// Keys, notes and passkeys in a plain home: the items Bitwarden's apps see
// for each (a secure note, an SSH key item or a note with a hidden field,
// a login with the passkey), what a second phone reads back, edits made in
// Bitwarden coming back, and a note too long for the server staying here.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as keys;
import 'package:kemlock/features/import/importers.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_formats.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_items.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';

import '../../keys/pgp_kit.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

/// One phone syncing a vault's own entries with the home.
class _Phone {
  _Phone(this.server, this.target) : reader = VwReader(server.userKey);

  final FakeVaultwarden server;
  final VaultwardenTarget target;
  final VwReader reader;
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);
  late VwCredentials credentials = server.credentials();

  Future<VwSyncResult> sync() async {
    final at = server.revision + 500;
    final result = await VaultwardenScopeSync(
      connection: VwConnection(
        api: VwApi(server.client),
        server: FakeVaultwarden.url,
        credentials: credentials,
        onCredentials: (next) async => credentials = next,
      ),
      reader: reader,
      target: target,
    ).sync(lists, state, now: at);
    lists = applyScope(lists, null, result.doc);
    state = ScopeState(known: result.known, lastSyncAt: at, extra: result.state);
    return result;
  }
}

/// The home's items Kemlock made for entries, as the server keeps them.
List<Map<String, Object?>> _entryItems(FakeVaultwarden server, {int? type}) => [
  for (final cipher in server.ciphers.values)
    if (cipher['deletedDate'] == null && (cipher['fields'] as List<Object?>?)?.length != null && (type == null || cipher['type'] == type))
      cipher,
];

Future<String?> _open(Object? value, BwKey key) async => value is String ? bwDecryptString(value, key) : null;

/// The item's custom fields, decrypted, by name.
Future<Map<String, String?>> _fields(Map<String, Object?> cipher, BwKey key) async => {
  for (final field in (cipher['fields'] as List<Object?>? ?? const []).cast<Map<String, Object?>>())
    (await _open(field['name'], key))!: await _open(field['value'], key),
};

/// The item holding entry [id].
Future<Map<String, Object?>> _itemOf(FakeVaultwarden server, String id) async {
  for (final cipher in server.ciphers.values) {
    if (cipher['deletedDate'] != null) continue;
    final field = (await _fields(cipher, server.userKey))[fieldName];
    if (field != null && plainHeader(field)?.id == id) return cipher;
  }
  throw StateError('No item holds $id');
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

Future<VaultKey> _sshKey() async {
  final made = await keys.makeKey(const keys.NewKeyRequest(keys.KeyKind.ssh, keys.GeneratedAlgorithm.ed25519));
  return VaultKey(
    id: 'k-ssh',
    name: 'laptop',
    kind: KeyKind.ssh,
    algorithm: made.algorithm,
    privateKey: b64(made.private),
    publicKey: b64(made.public!),
    origin: KeyOrigin.generated,
    note: 'Work laptop',
    addedAt: 1,
  );
}

Future<Passkey> _passkey() async {
  final made = await keys.makeKey(const keys.NewKeyRequest(keys.KeyKind.signing, keys.GeneratedAlgorithm.ecdsaP256));
  return Passkey(
    id: 'p1',
    credentialId: b64url(List.generate(16, (i) => i + 1)),
    rpId: 'github.com',
    rpName: 'GitHub',
    userHandle: b64url(utf8.encode('user-123')),
    userName: 'octocat',
    userDisplayName: 'The Octocat',
    privateKey: b64(made.private),
    addedAt: DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
  );
}

const _note = SecureNote(id: 'n1', title: 'Passport', text: 'Number 12AB34567', pinned: true, addedAt: 1);

void main() {
  late FakeVaultwarden server;
  late VaultwardenTarget target;

  setUp(() async {
    server = FakeVaultwarden();
    target = await makeHome(server, VaultwardenMode.plain, plainKinds: agreedToAll);
  });

  test('a note is a secure note with its title, text and pin', () async {
    final phone = _Phone(server, target)..lists = const Lists(notes: [_note]);

    await phone.sync();

    final item = await _itemOf(server, 'n1');
    final key = server.userKey;
    expect(item['type'], CipherType.secureNote);
    expect(await _open(item['name'], key), 'Passport');
    expect(await _open(item['notes'], key), 'Number 12AB34567');
    expect(item['favorite'], isTrue);
    expect(item['folderId'], target.folderId);
    final other = _Phone(server, target);
    await other.sync();
    expect(other.lists.notes, [_note]);
  });

  test('an SSH key is an SSH key item where the server keeps them', () async {
    final key = await _sshKey();
    final phone = _Phone(server, target)..lists = Lists(keys: [key]);

    await phone.sync();

    final item = await _itemOf(server, key.id);
    final userKey = server.userKey;
    expect(item['type'], CipherType.sshKey);
    expect(await _open(item['name'], userKey), 'laptop');
    expect(await _open(item['notes'], userKey), 'Work laptop');
    final ssh = item['sshKey']! as Map<String, Object?>;
    final private = (await _open(ssh['privateKey'], userKey))!;
    expect(private, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
    final read = await keys.readPrivateKey(private);
    expect(read.private, unb64(key.privateKey), reason: 'the same key comes back from its OpenSSH form');
    final parsed = parsedKey(key);
    expect(await _open(ssh['publicKey'], userKey), keys.sshPublicKeyLine(parsed, comment: ''));
    expect(await _open(ssh['keyFingerprint'], userKey), keys.keyFingerprint(parsed)!.text);

    final other = _Phone(server, target);
    await other.sync();
    expect(other.lists.keys, [key]);
    // A second sync writes nothing more
    final before = jsonEncode(server.ciphers);
    await phone.sync();
    await other.sync();
    expect(jsonEncode(server.ciphers), before);
  });

  test('asks /api/sync as a client that gets SSH key items', () async {
    final key = await _sshKey();
    final phone = _Phone(server, target)..lists = Lists(keys: [key]);
    await phone.sync();

    final asked = server.requests.where((request) => request.url.path == '/api/sync');
    expect(asked.map((request) => versionAtLeast(request.headers['Bitwarden-Client-Version']!, sshKeyItemsVersion)), everyElement(isTrue));
    expect(_entryItems(server, type: CipherType.sshKey), hasLength(1));
  });

  test('an SSH key on a server without SSH key items is a secure note with a hidden private key', () async {
    server.configVersion = '2024.2.0';
    final key = await _sshKey();
    final phone = _Phone(server, target)..lists = Lists(keys: [key]);

    await phone.sync();

    final item = await _itemOf(server, key.id);
    final userKey = server.userKey;
    expect(item['type'], CipherType.secureNote);
    final line = keys.sshPublicKeyLine(parsedKey(key))!;
    expect(await _open(item['notes'], userKey), '$line\n\n---\nWork laptop');
    final hidden = (item['fields']! as List<Object?>).cast<Map<String, Object?>>().firstWhere((field) => field['type'] == 1);
    expect(await _open(hidden['name'], userKey), privateKeyFieldName);
    final private = (await _open(hidden['value'], userKey))!;
    expect((await keys.readPrivateKey(private)).private, unb64(key.privateKey));
    final other = _Phone(server, target);
    await other.sync();
    expect(other.lists.keys, [key]);
  });

  test('another key is a secure note with its public half, and the private half as PEM', () async {
    final made = await keys.makeKey(const keys.NewKeyRequest(keys.KeyKind.signing, keys.GeneratedAlgorithm.ecdsaP256));
    final key = VaultKey(
      id: 'k-sign',
      name: 'Release signing',
      kind: KeyKind.signing,
      algorithm: made.algorithm,
      privateKey: b64(made.private),
      publicKey: b64(made.public!),
      origin: KeyOrigin.generated,
      addedAt: 1,
    );
    final phone = _Phone(server, target)..lists = Lists(keys: [key]);

    await phone.sync();

    final item = await _itemOf(server, key.id);
    final userKey = server.userKey;
    expect(item['type'], CipherType.secureNote);
    expect(await _open(item['notes'], userKey), keys.publicKeyPem(made));
    final fields = await _fields(item, userKey);
    expect(fields[privateKeyFieldName], keys.exportPkcs8Pem(made));
  });

  test('a passkey is a login for its site, with the passkey Bitwarden reads', () async {
    final passkey = await _passkey();
    final phone = _Phone(server, target)..lists = Lists(passkeys: [passkey]);

    await phone.sync();

    final item = await _itemOf(server, passkey.id);
    final key = server.userKey;
    expect(item['type'], CipherType.login);
    expect(await _open(item['name'], key), 'GitHub');
    final login = item['login']! as Map<String, Object?>;
    expect(await _open(login['username'], key), 'octocat');
    expect(await _open((login['uris']! as List<Object?>).cast<Map<String, Object?>>().single['uri'], key), 'https://github.com');
    expect(login['password'], isNull);
    final credential = (login['fido2Credentials']! as List<Object?>).single! as Map<String, Object?>;
    final open = {
      for (final MapEntry(key: name, :value) in credential.entries) name: name == 'creationDate' ? value : await _open(value, key),
    };
    expect(open, {
      'credentialId': '01020304-0506-0708-090a-0b0c0d0e0f10',
      'keyType': 'public-key',
      'keyAlgorithm': 'ECDSA',
      'keyCurve': 'P-256',
      'keyValue': b64url(unb64(passkey.privateKey)),
      'rpId': 'github.com',
      'rpName': 'GitHub',
      'userHandle': passkey.userHandle,
      'userName': 'octocat',
      'userDisplayName': 'The Octocat',
      'counter': '0',
      'discoverable': 'true',
      'creationDate': '2026-11-01T00:00:00.000Z',
    });

    // Bitwarden's own export of that login reads back as the same passkey
    final export = jsonEncode({
      'encrypted': false,
      'items': [
        {
          'type': 1,
          'name': 'GitHub',
          'login': {
            'username': 'octocat',
            'fido2Credentials': [open],
          },
        },
      ],
    });
    final imported = (await parseForeignExport(export)).passkeys.single;
    expect(
      (imported.credentialId, imported.rpId, imported.userHandle, imported.privateKey, imported.userName),
      (passkey.credentialId, passkey.rpId, passkey.userHandle, passkey.privateKey, passkey.userName),
    );

    final other = _Phone(server, target);
    await other.sync();
    expect(other.lists.passkeys, [passkey]);
  });

  test('a credential id of another length is written as b64 and base64url', () {
    final id = b64url(List.generate(20, (i) => i));
    expect(bitwardenCredentialId(id), 'b64.$id');
  });

  test('edits made in Bitwarden come back, as of the item revision', () async {
    final key = await _sshKey();
    final passkey = await _passkey();
    final phone = _Phone(server, target)..lists = Lists(keys: [key], notes: const [_note], passkeys: [passkey]);
    await phone.sync();

    await _editInBitwarden(server, await _itemOf(server, 'n1'), notes: 'Number 98ZY76543, renewed');
    await _editInBitwarden(server, await _itemOf(server, key.id), name: 'Old laptop');
    await _editInBitwarden(server, await _itemOf(server, passkey.id), name: 'GitHub (work)');
    final noteItem = await _itemOf(server, 'n1');
    await phone.sync();

    final note = phone.lists.notes.single;
    expect((note.title, note.text, note.isPinned), ('Passport', 'Number 98ZY76543, renewed', true));
    expect(note.updatedAt, DateTime.parse(noteItem['revisionDate']! as String).millisecondsSinceEpoch);
    expect(phone.lists.keys.single.name, 'Old laptop');
    expect(phone.lists.keys.single.privateKey, key.privateKey);
    expect(phone.lists.passkeys.single.displayName, 'GitHub (work)');
    // And another phone gets them too
    final other = _Phone(server, target);
    await other.sync();
    expect(other.lists.notes.single.text, 'Number 98ZY76543, renewed');
  });

  test('a passkey taken off its login in Bitwarden is deleted here', () async {
    final passkey = await _passkey();
    final phone = _Phone(server, target)..lists = Lists(passkeys: [passkey]);
    await phone.sync();

    final item = await _itemOf(server, passkey.id);
    server.put({
      ...item,
      'login': {...item['login']! as Map<String, Object?>, 'fido2Credentials': <Object?>[]},
    }, id: item['id']! as String);
    await phone.sync();

    expect(phone.lists.passkeys, isEmpty);
  });

  test('a note too long for the server stays here, the rest syncs, and the run says which', () async {
    final long = SecureNote(id: 'n-long', title: 'Diary', text: 'x' * 9000, addedAt: 1);
    final phone = _Phone(server, target)..lists = Lists(notes: [_note, long]);

    final result = await phone.sync();

    expect(result.state['tooLong'], ['n-long']);
    expect(phone.lists.notes.map((note) => note.id), unorderedEquals(['n1', 'n-long']));
    await expectLater(_itemOf(server, 'n-long'), throwsStateError);
    await _itemOf(server, 'n1');
    // It isn't taken for a deletion later either
    final again = await phone.sync();
    expect(phone.lists.notes.map((note) => note.id), unorderedEquals(['n1', 'n-long']));
    expect(again.state['tooLong'], ['n-long']);

    // Once shorter, it goes
    phone.lists = Lists(
      notes: [
        _note,
        long.copyWith(text: 'x' * 100, updatedAt: server.revision + 100),
      ],
    );
    final shorter = await phone.sync();
    expect(shorter.state['tooLong'], isNull);
    expect(await _open((await _itemOf(server, 'n-long'))['notes'], server.userKey), 'x' * 100);
  });

  group('a PGP key that changed', () {
    /// The item's hidden private key field, still encrypted.
    Future<Object?> hiddenCipherText(Map<String, Object?> item) async {
      for (final field in (item['fields']! as List<Object?>).cast<Map<String, Object?>>()) {
        if (await _open(field['name'], server.userKey) == privateKeyFieldName) return field['value'];
      }
      return null;
    }

    test('writes both halves again: the notes and the hidden field hold the new ones, and the sum matches', () async {
      final before = await pgpVaultKey(updatedAt: 100);
      final phone = _Phone(server, target)..lists = Lists(keys: [before]);
      await phone.sync();
      expect((await _fields(await _itemOf(server, before.id), server.userKey))[privateKeyFieldName], await privateKeyText(before));

      final after = await pgpVaultKey(path: 'gnupg/editing/signing-subkey.after.secret.asc', updatedAt: server.revision + 100);
      phone.lists = Lists(keys: [after]);
      await phone.sync();

      // What the phone keeps: GnuPG's copy combined with the one written before
      final kept = phone.lists.keys.single;
      expect(keys.readPgpKeyInfo(unb64(kept.privateKey)).subkeys, hasLength(3));
      final item = await _itemOf(server, before.id);
      expect(await _open(item['notes'], server.userKey), keyNoteText(kept));
      final fields = await _fields(item, server.userKey);
      expect(fields[privateKeyFieldName], await privateKeyText(kept));
      expect(PlainField.tryParse(fields[fieldName]!)!.sum, valuesSum(laterValues(kept)));
      // Another phone reads the same key, not an edit made in Bitwarden
      final other = _Phone(server, target);
      await other.sync();
      expect(other.lists.keys, [kept]);
    });

    test('a rename alone leaves the hidden private half as it was written', () async {
      final key = await pgpVaultKey(updatedAt: 100);
      final phone = _Phone(server, target)..lists = Lists(keys: [key]);
      await phone.sync();
      final written = await hiddenCipherText(await _itemOf(server, key.id));

      phone.lists = Lists(
        keys: [key.copyWith(name: 'Renamed', updatedAt: server.revision + 100)],
      );
      await phone.sync();

      final item = await _itemOf(server, key.id);
      expect(await _open(item['name'], server.userKey), 'Renamed');
      expect(await hiddenCipherText(item), written);
    });

    test('an SSH key item is not touched by a rename', () async {
      final key = await _sshKey();
      final phone = _Phone(server, target)..lists = Lists(keys: [key]);
      await phone.sync();
      final ssh = (await _itemOf(server, key.id))['sshKey'];

      phone.lists = Lists(
        keys: [key.copyWith(name: 'Renamed', updatedAt: server.revision + 100)],
      );
      await phone.sync();

      final item = await _itemOf(server, key.id);
      expect(item['sshKey'], ssh);
      expect((item['fields']! as List<Object?>).length, 1);
    });
  });

  test('the length the server counts is that of the encrypted notes', () async {
    for (final text in ['', 'a', 'x' * 15, 'x' * 16, 'é' * 100, 'x' * 7000]) {
      expect(encryptedLength(text), (await bwEncryptString(text, server.userKey)).length, reason: '${text.length}');
    }
    expect(tooLongForNotes('x' * 7400), isFalse);
    expect(tooLongForNotes('x' * 7600), isTrue);
  });

  // openspec: add-security-key-codes, task 8.5
  for (final mode in VaultwardenMode.values) {
    test('accounts on a security key stay on the phone, in a ${mode.name} home: no item carries them, and no run loses them', () async {
      final home = FakeVaultwarden();
      final phone = _Phone(home, await makeHome(home, mode, plainKinds: agreedToAll))
        ..lists = const Lists(accounts: [_account], keyAccounts: [_onKey]);

      await phone.sync();
      expect(phone.lists.keyAccounts, [_onKey]);
      expect(phone.lists.accounts, [_account]);
      // A run with nothing changed, which stops at the revision date.
      await phone.sync();
      expect(phone.lists.keyAccounts, [_onKey]);

      final other = _Phone(home, phone.target);
      await other.sync();
      expect(other.lists.accounts.single.id, _account.id);
      expect(other.lists.keyAccounts, isEmpty, reason: 'Vaultwarden holds none of them');
    });
  }

  // openspec: add-passwords, task 7.4
  for (final mode in VaultwardenMode.values) {
    test('logins stay on the phone, in a ${mode.name} home: no item carries them, and no run loses them', () async {
      // What a home holds for the account alone
      final bare = FakeVaultwarden();
      await (_Phone(bare, await makeHome(bare, mode, plainKinds: agreedToAll))..lists = const Lists(accounts: [_account])).sync();
      final items = _entryItems(bare).length;

      final home = FakeVaultwarden();
      final phone = _Phone(home, await makeHome(home, mode, plainKinds: agreedToAll))
        ..lists = const Lists(accounts: [_account], logins: [_login]);

      await phone.sync();
      expect(phone.lists.logins, [_login]);
      expect(_entryItems(home), hasLength(items), reason: 'no item for the login');
      // A run with nothing changed, which stops at the revision date
      await phone.sync();
      expect(phone.lists.logins, [_login]);
      // An edit to a login is no change Vaultwarden has to take
      phone.lists = Lists(
        accounts: phone.lists.accounts,
        logins: [_login.copyWith(password: 'changed', updatedAt: 9)],
      );
      await phone.sync();
      expect(phone.lists.logins.single.password, 'changed');
      expect(_entryItems(home), hasLength(items));
      // Nor is its deletion
      phone.lists = Lists(accounts: phone.lists.accounts);
      await phone.sync();
      expect(phone.lists.logins, isEmpty);
      expect(_entryItems(home), hasLength(items));

      final other = _Phone(home, phone.target);
      await other.sync();
      expect(other.lists.accounts.single.id, _account.id);
      expect(other.lists.logins, isEmpty, reason: 'Vaultwarden holds none of them');
    });
  }

  // the add-cards-identities-and-websites plan, task 3.6
  for (final mode in VaultwardenMode.values) {
    test('cards and identities stay on the phone, in a ${mode.name} home: no item carries them, and no run loses them', () async {
      // What a home holds for the account alone
      final bare = FakeVaultwarden();
      await (_Phone(bare, await makeHome(bare, mode, plainKinds: agreedToAll))..lists = const Lists(accounts: [_account])).sync();
      final items = _entryItems(bare).length;

      final home = FakeVaultwarden();
      final phone = _Phone(home, await makeHome(home, mode, plainKinds: agreedToAll))
        ..lists = const Lists(accounts: [_account], cards: [_card], identities: [_identity]);

      await phone.sync();
      expect(phone.lists.cards, [_card]);
      expect(phone.lists.identities, [_identity]);
      expect(_entryItems(home), hasLength(items), reason: 'no item for either');
      // A run with nothing changed, which stops at the revision date
      await phone.sync();
      expect(phone.lists.cards, [_card]);
      expect(phone.lists.identities, [_identity]);
      // An edit to a card is no change Vaultwarden has to take
      phone.lists = Lists(
        accounts: phone.lists.accounts,
        cards: [_card.copyWith(name: 'Changed', updatedAt: 9)],
        identities: phone.lists.identities,
      );
      await phone.sync();
      expect(phone.lists.cards.single.name, 'Changed');
      expect(phone.lists.identities, [_identity]);
      expect(_entryItems(home), hasLength(items));
      // Nor is a deletion
      phone.lists = Lists(accounts: phone.lists.accounts);
      await phone.sync();
      expect(phone.lists.cards, isEmpty);
      expect(_entryItems(home), hasLength(items));

      final other = _Phone(home, phone.target);
      await other.sync();
      expect(other.lists.accounts.single.id, _account.id);
      expect(other.lists.cards, isEmpty, reason: 'Vaultwarden holds none of them');
      expect(other.lists.identities, isEmpty);
    });
  }
}

const _card = PaymentCard(id: 'c1', name: 'Everyday Visa', number: '4111111111111111', addedAt: 0);

const _identity = Identity(id: 'i1', name: 'Me', email: 'ada@example.org', addedAt: 0);

const _login = Login(
  id: 'l1',
  name: 'Larkspur Mail',
  username: 'ada@example.org',
  password: 'hunter2',
  websites: ['larkspur.example'],
  addedAt: 2,
);

const _account = OtpAccount(id: 'a1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

const _onKey = KeyAccount(
  id: 'ka1',
  device: '0102030405060708',
  keyName: 'YubiKey',
  name: 'Bank:ada',
  issuer: 'Bank',
  label: 'ada',
  addedAt: 1,
);
