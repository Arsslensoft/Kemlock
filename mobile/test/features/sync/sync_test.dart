// Syncing one scope, ported from the cases of src/lib/sync.test.ts that run
// on the fake WebDAV server, with the settings' JSON and problemOf.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';

import '../contacts/contacts_kit.dart';
import 'fake_webdav.dart';

const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const path = '/files/me/Kemlock/$syncFile';

OtpAccount acct(String id) => OtpAccount(id: id, issuer: id, label: '', secret: 'S$id', addedAt: 1);

/// One device: its lists and what it remembers between syncs.
class Device {
  Device([List<OtpAccount> accounts = const []]) : lists = Lists(accounts: accounts);

  Lists lists;
  List<String> known = [];

  /// The count of the newest file it saw, as the scheduler keeps it.
  int? seen;

  List<String> get ids => [for (final account in lists.accounts) account.id];
}

SyncTarget target() => SyncTarget(dav: dav, file: syncFile, key: b64(randomBytes(32)));

void main() {
  late FakeWebDav server;
  late WebDav webDav;

  setUp(() {
    server = FakeWebDav();
    webDav = WebDav(server.client);
  });

  Future<void> sync(Device d, SyncTarget t, int now) async {
    final result = await syncScope(webDav, t, scopeLists(d.lists, null), d.known, now: now, seen: d.seen);
    d.lists = applyScope(d.lists, null, result.doc);
    d.known = result.known;
    d.seen = result.seq;
  }

  /// The count of the file in the folder.
  Future<int?> count(SyncTarget t) async => (await decryptSyncFile(server.files[path]!.text, unb64(t.key))).seq;

  int writes() => server.requests.where((r) => r.method == 'PUT').length;

  group('syncing two devices through one folder', () {
    test('carries additions and deletions both ways', () async {
      final t = target();
      final phone = Device([acct('github')]);
      final tablet = Device([acct('steam')]);

      await sync(phone, t, 1000);
      await sync(tablet, t, 2000);
      await sync(phone, t, 3000);
      expect(phone.ids..sort(), ['github', 'steam']);
      expect(tablet.ids..sort(), ['github', 'steam']);

      tablet.lists = Lists(accounts: [...tablet.lists.accounts.where((a) => a.id != 'github')]);
      await sync(tablet, t, 4000);
      await sync(phone, t, 5000);
      expect(phone.ids, ['steam']);

      // The server only ever holds ciphertext
      expect(server.files[path]?.text, isNot(contains('"issuer"')));
    });

    test('carries a key, a note and a passkey both ways, and their deletions', () async {
      final t = target();
      const key = VaultKey(
        id: 'k1',
        name: 'laptop',
        kind: KeyKind.ssh,
        algorithm: 'ed25519',
        privateKey: 'MC4CAQAwBQYDK2VwBCIEIA==',
        publicKey: 'MCowBQYDK2VwAyEA',
        origin: KeyOrigin.generated,
        addedAt: 1,
      );
      const note = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 1);
      const passkey = Passkey(
        id: 'p1',
        credentialId: 'cred',
        rpId: 'github.com',
        userHandle: 'aGFuZGxl',
        userName: 'me',
        privateKey: 'MIGH',
        addedAt: 1,
      );
      final phone = Device([acct('github')])..lists = Lists(accounts: [acct('github')], keys: const [key], notes: const [note]);
      final tablet = Device()..lists = const Lists(passkeys: [passkey]);

      await sync(phone, t, 1000);
      await sync(tablet, t, 2000);
      await sync(phone, t, 3000);
      for (final device in [phone, tablet]) {
        expect(
          (device.lists.keys.single.name, device.lists.notes.single.title, device.lists.passkeys.single.rpId),
          ('laptop', 'Passport', 'github.com'),
        );
        expect(device.lists.accounts.single.id, 'github');
      }

      phone.lists = Lists(accounts: phone.lists.accounts, keys: phone.lists.keys, passkeys: phone.lists.passkeys);
      tablet.lists = Lists(accounts: tablet.lists.accounts, notes: tablet.lists.notes, keys: tablet.lists.keys);
      await sync(phone, t, 4000);
      await sync(tablet, t, 5000);
      await sync(phone, t, 6000);
      for (final device in [phone, tablet]) {
        expect(device.lists.notes, isEmpty);
        expect(device.lists.passkeys, isEmpty);
        expect(device.lists.keys.single.id, 'k1');
      }
      // Nothing of them is on the server in the clear
      final text = server.files[path]!.text;
      for (final secret in ['Passport', 'laptop', 'github.com', 'MC4CAQAw']) {
        expect(text, isNot(contains(secret)));
      }
    });

    // openspec: add-pgp-contacts, task 7.2
    test('carries a contact, its check and its deletion both ways', () async {
      final t = target();
      final grace = contactOf(grace1, addedAt: 1);
      final alanTuring = contactOf(alan, id: 'c2', name: 'Alan Turing', addedAt: 1);
      final phone = Device()..lists = Lists(contacts: [grace]);
      final tablet = Device()..lists = Lists(contacts: [alanTuring]);

      await sync(phone, t, 1000);
      await sync(tablet, t, 2000);
      await sync(phone, t, 3000);
      for (final device in [phone, tablet]) {
        expect(device.lists.contacts, unorderedEquals([grace, alanTuring]));
      }
      expect(server.files[path]?.text, isNot(contains('Grace')));

      // Checked on the tablet, the check reaches the phone
      tablet.lists = Lists(contacts: [grace.checked(graceFingerprint, 3500).stamped(3500), alanTuring]);
      await sync(tablet, t, 4000);
      await sync(phone, t, 5000);
      final onPhone = phone.lists.contacts.firstWhere((c) => c.id == 'c1');
      expect(contactStanding(onPhone, contactsNow).checked, isTrue);
      expect(onPhone.checkedAt, 3500);

      // Deleted on the phone, it goes from the tablet
      phone.lists = Lists(contacts: [onPhone]);
      await sync(phone, t, 6000);
      await sync(tablet, t, 7000);
      expect(tablet.lists.contacts.map((c) => c.id), ['c1']);
      expect(tablet.known, ['c1']);
    });

    test('the same key added on two devices before they synced ends as one contact, checked', () async {
      final t = target();
      final phone = Device()..lists = Lists(contacts: [contactOf(grace1, id: 'on-phone', addedAt: 1, checkedAt: 900)]);
      final tablet = Device()..lists = Lists(contacts: [contactOf(grace1, id: 'on-tablet', addedAt: 2)]);

      await sync(phone, t, 1000);
      await sync(tablet, t, 2000);
      await sync(phone, t, 3000);

      for (final device in [phone, tablet]) {
        expect(device.lists.contacts.map((c) => c.id), ['on-phone']);
        expect(contactStanding(device.lists.contacts.single, contactsNow).checked, isTrue);
      }
    });

    test('does not write when nothing changed', () async {
      final t = target();
      final phone = Device([acct('a')]);
      await sync(phone, t, 1000);

      await sync(phone, t, 2000);

      expect(writes(), 1);
    });

    test('merges again when another device wrote between its read and write', () async {
      final t = target();
      final tablet = Device([acct('tablet')]);
      await sync(tablet, t, 1000);
      final phone = Device([acct('phone')]);

      // The tablet syncs again right after the phone has read the file
      final tabletNext = Device([acct('tablet'), acct('late')])..known = tablet.known;
      server.respond = (request) async {
        server.respond = null;
        final res = await server.handle(request);
        await sync(tabletNext, t, 1500);
        return res;
      };

      await sync(phone, t, 2000);

      expect(phone.ids..sort(), ['late', 'phone', 'tablet']);
      await sync(tabletNext, t, 3000);
      expect(tabletNext.ids..sort(), ['late', 'phone', 'tablet']);
    });

    test('names the problem when the passphrase is wrong', () async {
      final phone = Device([acct('a')]);
      await sync(phone, target(), 1000);

      final error = await syncScope(
        webDav,
        target(),
        scopeLists(phone.lists, null),
        [],
        now: 2000,
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(problemOf(error), SyncProblem.key);
    });
  });

  group('syncScope', () {
    test('creates the file only if it is still missing, then replaces only the version it read', () async {
      final t = target();
      final phone = Device([acct('a')]);
      await sync(phone, t, 1000);
      phone.lists = Lists(accounts: [acct('a'), acct('b')]);
      await sync(phone, t, 2000);

      final puts = server.requests.where((r) => r.method == 'PUT').toList();
      expect(puts[0].headers['If-None-Match'], '*');
      expect(puts[0].headers['If-Match'], isNull);
      expect(puts[1].headers['If-Match'], '"v1"');
    });

    test('gives up after losing the race three times', () async {
      final t = target();
      await sync(Device([acct('a')]), t, 1000);
      server.respond = (request) async => request.method == 'PUT' ? http.Response('', 412) : await server.handle(request);

      final error = await syncScope(
        webDav,
        t,
        Lists(accounts: [acct('b')]),
        [],
        now: 2000,
      ).then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<DavError>().having((e) => e.problem, 'problem', DavProblem.conflict));
      expect(problemOf(error), SyncProblem.conflict);
      expect(writes(), 1 + 3);
    });

    test('writes the passphrase salt into the vault file', () async {
      final kdf = newKdf();
      final t = SyncTarget(dav: dav, file: syncFile, key: b64(randomBytes(32)), kdf: kdf);
      await sync(Device([acct('a')]), t, 1000);

      expect(readKdf(server.files[path]!.text), kdf);
    });

    test('returns what the scope holds, to take locally and to remember', () async {
      final t = target();
      final tablet = Device([acct('t')]);
      await sync(tablet, t, 1000);

      final result = await syncScope(webDav, t, Lists(accounts: [acct('p')]), [], now: 2000);

      expect([for (final a in result.doc.accounts) a.id], ['p', 't']);
      expect(result.known, ['p', 't']);
      final remote = await decryptSyncFile(server.files[path]!.text, unb64(t.key));
      expect(sameDoc(remote, result.doc), isTrue);
    });

    test('counts each write one more than the file it replaced, and writes nothing to count when nothing changed', () async {
      final t = target();
      final phone = Device([acct('a')]);
      final tablet = Device([acct('b')]);

      await sync(phone, t, 1000);
      expect((await count(t), phone.seen), (1, 1));
      await sync(tablet, t, 2000);
      expect((await count(t), tablet.seen), (2, 2));
      // The phone takes the tablet's entry, which leaves nothing to write
      await sync(phone, t, 3000);
      expect((await count(t), phone.seen), (2, 2));
      expect(writes(), 2);
      // Back and forth, neither stops the other
      phone.lists = Lists(accounts: [acct('a'), acct('b'), acct('c')]);
      await sync(phone, t, 4000);
      tablet.lists = Lists(accounts: [acct('b')]);
      await sync(tablet, t, 5000);
      await sync(phone, t, 6000);
      expect(phone.ids..sort(), ['b', 'c']);
      expect(tablet.ids..sort(), ['b', 'c']);
      expect((await count(t), phone.seen, tablet.seen), (4, 4, 4));
    });

    test('refuses a file older than one it synced, which would bring a deletion back, and writes nothing', () async {
      final t = target();
      final phone = Device([acct('a'), acct('b')]);
      await sync(phone, t, 1000);
      final first = server.files[path]!.text;
      phone.lists = Lists(accounts: [acct('a')]);
      await sync(phone, t, 2000);
      expect(phone.seen, 2);

      // The server hands the first file back, without the deletion of b
      server.put(path, first);
      final before = server.requests.length;
      final error = await syncScope(
        webDav,
        t,
        scopeLists(phone.lists, null),
        phone.known,
        now: 3000,
        seen: phone.seen,
      ).then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<SyncFileError>().having((e) => e.problem, 'problem', SyncFileProblem.older));
      expect(problemOf(error), SyncProblem.older);
      // Read again as after a lost race, and nothing written
      expect([for (final request in server.requests.skip(before)) request.method], ['GET', 'GET', 'GET']);
      expect(server.files[path]!.text, first);

      // Once the server hands out the newer one again, sync goes on, and b stays deleted
      server.put(
        path,
        await encryptSyncFile(
          SyncDoc(
            accounts: [acct('a')],
            deleted: const [Tombstone(id: 'b', at: 2000)],
            seq: 2,
          ),
          unb64(t.key),
        ),
      );
      await sync(phone, t, 4000);
      expect(phone.ids, ['a']);
    });

    test('merges a file without a count as before, as the TypeScript app and older versions write, and counts on', () async {
      final t = target();
      final phone = Device([acct('a')])..seen = 5;
      server.put(path, await encryptSyncFile(SyncDoc(accounts: [acct('t')]), unb64(t.key)));

      await sync(phone, t, 1000);

      expect(phone.ids, ['a', 't']);
      expect((await count(t), phone.seen), (6, 6));
    });

    test('reads a count, writes it after the deletions, and drops one that is no count', () {
      final read = SyncDoc.fromJson({'accounts': <Object?>[], 'backupServices': <Object?>[], 'deleted': <Object?>[], 'seq': 7, 'later': 1});
      expect(read.seq, 7);
      expect(read.extra, {'later': 1});
      expect(jsonEncode(read.toJson()), '{"accounts":[],"backupServices":[],"deleted":[],"seq":7,"later":1}');

      for (final value in [-1, 1.5, '7', null, maxSyncSeq + 1]) {
        final doc = SyncDoc.fromJson({'accounts': <Object?>[], 'backupServices': <Object?>[], 'deleted': <Object?>[], 'seq': value});
        expect((doc.seq, doc.toJson().containsKey('seq')), (null, false), reason: '$value');
      }
      // A file of codes alone that never counted is written as it always was
      expect(
        jsonEncode(SyncDoc.fromJson({'accounts': <Object?>[], 'backupServices': <Object?>[], 'deleted': <Object?>[]}).toJson()),
        '{"accounts":[],"backupServices":[],"deleted":[]}',
      );
    });

    test('reports a folder it cannot reach, and writes nothing', () async {
      server.respond = (_) async => http.Response('', 401);

      final error = await syncScope(
        webDav,
        target(),
        Lists(accounts: [acct('a')]),
        [],
        now: 1000,
      ).then<Object?>((_) => null, onError: (Object e) => e);

      expect(problemOf(error), SyncProblem.auth);
      expect(writes(), 0);
    });
  });

  group('problemOf', () {
    test('names every problem the server, the file or anything else can have', () {
      expect(
        [for (final problem in DavProblem.values) problemOf(DavError(problem))],
        [SyncProblem.insecure, SyncProblem.auth, SyncProblem.folder, SyncProblem.conflict, SyncProblem.network, SyncProblem.server],
      );
      expect(problemOf(const SyncFileError(SyncFileProblem.key)), SyncProblem.key);
      expect(problemOf(const SyncFileError(SyncFileProblem.format)), SyncProblem.format);
      expect(problemOf(const SyncFileError(SyncFileProblem.older)), SyncProblem.older);
      expect(problemOf(const FormatException()), SyncProblem.server);
      expect(problemOf(StateError('x')), SyncProblem.server);
      expect(problemOf(null), SyncProblem.server);
    });

    test('names what Vaultwarden sync can run into', () {
      expect(
        [for (final problem in VwProblem.values) problemOf(VwError(problem))],
        [
          SyncProblem.insecure,
          SyncProblem.address,
          SyncProblem.auth,
          SyncProblem.auth,
          SyncProblem.signedOut,
          SyncProblem.conflict,
          SyncProblem.network,
          SyncProblem.unsupported,
          SyncProblem.server,
        ],
      );
      expect(
        [for (final issue in VwSyncIssue.values) problemOf(VwSyncError(issue))],
        [SyncProblem.homeMissing, SyncProblem.modeChanged, SyncProblem.removals],
      );
    });

    test('names problems as the message ids end', () {
      expect(
        [for (final problem in SyncProblem.values) problem.name],
        [
          'insecure',
          'auth',
          'folder',
          'conflict',
          'network',
          'server',
          'key',
          'format',
          'address',
          'signedOut',
          'unsupported',
          'homeMissing',
          'modeChanged',
          'removals',
          'older',
          'kemlockAddress',
          'sessionEnded',
          'sessionReused',
          'kemlockOlder',
          'spaceCantBeChecked',
          'spaceKeysPending',
        ],
      );
    });
  });

  group('settings', () {
    // As the TypeScript app stores them, with a key a later version might add at each level
    final stored = {
      'personal': {
        'dav': {'url': 'https://dav.example.com/me/', 'username': 'me', 'password': 'app-pw', 'later': 1},
        'file': syncFile,
        'key': 'a2V5',
        'kdf': {'salt': 'c2FsdA==', 'N': 131072, 'r': 8, 'p': 1},
        'later': 2,
      },
      'spaces': [
        {
          'id': 'fam',
          'name': 'Family',
          'target': {
            'dav': {'url': 'https://dav.example.com/shared/', 'username': 'me', 'password': 'app-pw'},
            'file': spaceFile('fam'),
            'key': 'c3BhY2U=',
          },
          'joinedAt': 1700000000000,
          'later': 3,
        },
      ],
      'later': 4,
    };

    test('reads what the TypeScript app stores and writes it back with the keys it does not know', () {
      final settings = SyncSettings.fromJson(jsonDecode(jsonEncode(stored)));

      expect(settings.personal?.dav.url, 'https://dav.example.com/me/');
      expect(settings.personal?.kdf?.salt, 'c2FsdA==');
      expect(settings.spaces.single.target.file, 'backmycodes-space-fam.json');
      expect(settings.spaces.single.target.kdf, isNull);
      expect(settings.spaces.single.joinedAt, 1700000000000);
      // A space's target gets no kdf key at all, as in the TypeScript
      expect(settings.toJson(), stored);
    });

    test('turns the vault sync off and keeps the rest', () {
      final settings = SyncSettings.fromJson(stored);
      final off = settings.copyWith(personal: null);

      expect(off.personal, isNull);
      expect(off.toJson(), {...stored, 'personal': null});
      expect(settings.copyWith(spaces: []).personal, settings.personal);
      expect(settings.copyWith(), settings);
    });

    test('reads sync as off from nothing, or from something that is not settings', () {
      for (final json in [null, 42, 'x', <Object?>[]]) {
        expect(SyncSettings.fromJson(json), const SyncSettings(), reason: '$json');
      }
      expect(const SyncSettings().toJson(), {'personal': null, 'spaces': <Object?>[]});
      expect(SyncSettings.fromJson({'personal': 'x', 'spaces': 'y'}).toJson(), {'personal': null, 'spaces': <Object?>[]});
    });

    test('keeps what each scope held, with keys it does not know', () {
      final json = {
        'known': ['a', 'b'],
        'lastSyncAt': 1700000000000,
        'later': true,
      };
      expect(ScopeState.fromJson(json).toJson(), json);
      expect(ScopeState.fromJson({}).toJson(), {'known': <String>[], 'lastSyncAt': null});
    });

    test('keeps the keys and passwords out of its text', () {
      final text = '${SyncSettings.fromJson(stored)}';
      expect(text, isNot(contains('app-pw')));
      expect(text, isNot(contains('a2V5')));
    });

    test('names the files', () {
      expect(syncFile, 'backmycodes-sync.json');
      expect(spaceFile('3f2c'), 'backmycodes-space-3f2c.json');
      expect(personalScope, 'personal');
    });
  });
}
