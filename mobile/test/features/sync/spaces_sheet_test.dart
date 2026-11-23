// Creating, joining, sharing and leaving shared spaces: SpacesDialog in
// syncDialogs.test.tsx, and the rest of what the sheet does.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/scan/qr_viewfinder.dart';
import 'package:kemlock/features/sync/spaces_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../fakes/fake_clipboard.dart';
import '../../fakes/fake_scanner.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import 'sync_screen_kit.dart';

final _codePattern = RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$');

/// The invite code on screen.
Finder _inviteCode() => find.byWidgetPredicate((widget) => widget is Text && _codePattern.hasMatch(widget.data ?? ''));

/// The card of the space named [name] in the list.
Finder _card(String name) =>
    find.ancestor(of: find.text(name), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == name)).first;

/// Taps the button labelled [label] on the card of the space named [name].
Future<void> _tapOnCard(WidgetTester tester, String name, String label) async {
  final button = find.descendant(of: _card(name), matching: find.text(label));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

const _dav = DavAccount(url: folder, username: 'me', password: 'app-pw');

Space _space(String id, String name) => Space(
  id: id,
  name: name,
  target: SyncTarget(dav: _dav, file: spaceFile(id), key: b64(randomBytes(32))),
  joinedAt: 1,
);

OtpAccount _account(String id, {String? spaceId}) =>
    OtpAccount(id: id, issuer: id, label: '', secret: 'JBSWY3DPEHPK3PXP', spaceId: spaceId, addedAt: 1);

Future<SyncSheetKit> _open(WidgetTester tester, {SyncSettings? settings, Lists? lists, FakeScanner? scanner}) async {
  final kit = SyncSheetKit();
  await kit.pump(tester, showSpacesSheet, overrides: [?scanner?.asOverride]);
  if (settings != null) await kit.save(settings);
  if (lists != null) await kit.vault.applySynced(lists);
  await kit.open(tester);
  return kit;
}

Future<void> _create(WidgetTester tester, SyncSheetKit kit, String name, {String url = folder}) async {
  await tapButton(tester, t('spaces.create'));
  await tester.enterText(field(t('spaces.field.name')), name);
  await kit.fillDav(tester, url: url);
  await tapButton(tester, t('spaces.create.button'));
}

Future<void> _join(WidgetTester tester, SyncSheetKit kit, String invite, String code) async {
  await tapButton(tester, t('spaces.join'));
  await tester.enterText(field(t('spaces.field.invite')), invite);
  await tester.enterText(field(t('spaces.field.code')), code);
  await kit.fillDav(tester);
  await tapButton(tester, t('spaces.join.button'));
}

void main() {
  testWidgets('creates a space, writes its empty file and shows an invite with its code', (tester) async {
    final kit = await _open(tester);

    await _create(tester, kit, 'Family');

    expect(find.text(t('spaces.invite.title', {'name': 'Family'})), findsOneWidget);
    final space = kit.settings!.spaces.single;
    expect(space.name, 'Family');
    expect(space.target.dav.url, folder);
    expect(space.target.file, spaceFile(space.id));
    expect(space.joinedAt, testNow.millisecondsSinceEpoch);
    final file = kit.server.files[folderPath(space.target.file)]!;
    final doc = await decryptSyncFile(file.text, unb64(space.target.key));
    expect(doc.toJson(), {'accounts': <Object?>[], 'backupServices': <Object?>[], 'deleted': <Object?>[]});
    expect(_inviteCode(), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(t('spaces.invite.warning')), findsOneWidget);
  });

  testWidgets('joins a space from an invite and its code', (tester) async {
    final kit = await _open(tester);
    await _create(tester, kit, 'Team');
    final code = tester.widget<Text>(_inviteCode()).data!;
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr, isNotNull);

    // Another vault joins with the same invite
    final space = kit.settings!.spaces.single;
    final invite = await sealInvite(
      SpaceInvite(id: space.id, name: space.name, file: space.target.file, key: unb64(space.target.key)),
      code,
      derive: fastKdf,
    );
    await kit.save(noSync);
    await tapButton(tester, t('enableBiometric.done'));
    await _join(tester, kit, invite, code.toLowerCase());

    expect(kit.settings?.spaces.map((s) => s.name), ['Team']);
    expect(kit.settings?.spaces.single.target.key, space.target.key);
    expect(find.text(t('spaces.joined', {'name': 'Team'})), findsOneWidget);
    expect(find.text(t('spaces.title')), findsOneWidget);
  });

  testWidgets('rejects a wrong invite code', (tester) async {
    final kit = await _open(tester);
    final invite = await sealInvite(
      SpaceInvite(id: 'x', name: 'X', file: 'backmycodes-space-x.json', key: Uint8List(32)),
      'AAAA-BBBB-CCCC',
      derive: fastKdf,
    );

    await _join(tester, kit, invite, 'AAAA-BBBB-DDDD');

    expect(find.text(t('spaces.error.invite.code')), findsOneWidget);
    expect(kit.settings?.spaces, isEmpty);
  });

  testWidgets('rejects text that isn’t an invite', (tester) async {
    final kit = await _open(tester);

    await _join(tester, kit, 'otpauth://totp/GitHub?secret=JBSWY3DPEHPK3PXP', 'AAAA-BBBB-CCCC');

    expect(find.text(t('spaces.error.invite.format')), findsOneWidget);
    expect(kit.server.requests, isEmpty);
  });

  testWidgets('won’t join a space this vault is in already', (tester) async {
    final family = _space('fam', 'Family');
    final kit = await _open(tester, settings: SyncSettings(spaces: [family]));
    final invite = await sealInvite(
      SpaceInvite(id: 'fam', name: 'Family', file: family.target.file, key: unb64(family.target.key)),
      'AAAA-BBBB-CCCC',
      derive: fastKdf,
    );

    await _join(tester, kit, invite, 'AAAA-BBBB-CCCC');

    expect(find.text(t('spaces.error.joined', {'name': 'Family'})), findsOneWidget);
    expect(kit.settings?.spaces, [family]);
  });

  testWidgets('says the space’s file isn’t in the folder given', (tester) async {
    final kit = await _open(tester);
    final invite = await sealInvite(
      SpaceInvite(id: 'x', name: 'X', file: 'backmycodes-space-x.json', key: Uint8List(32)),
      'AAAA-BBBB-CCCC',
      derive: fastKdf,
    );

    await _join(tester, kit, invite, 'AAAA-BBBB-CCCC');

    expect(find.text(t('spaces.error.noFile')), findsOneWidget);
    expect(kit.settings?.spaces, isEmpty);
  });

  testWidgets('refuses a plain http folder for a new space', (tester) async {
    final kit = await _open(tester);

    await _create(tester, kit, 'Family', url: 'http://nas.local/dav/');

    expect(find.text(t('sync.problem.insecure')), findsOneWidget);
    expect(find.text(t('spaces.create.title')), findsOneWidget);
    expect(kit.settings?.spaces, isEmpty);
  });

  testWidgets('creates a space only once it has a name and a folder', (tester) async {
    final kit = await _open(tester);
    await tapButton(tester, t('spaces.create'));
    expect(find.text(t('spaces.create.body')), findsOneWidget);
    expect(button(tester, t('spaces.create.button')).enabled, isFalse);

    await tester.enterText(field(t('spaces.field.name')), '   ');
    await tester.enterText(field(t('sync.field.url')), folder);
    await tester.pump();
    expect(button(tester, t('spaces.create.button')).enabled, isFalse);

    await tester.enterText(field(t('spaces.field.name')), 'Family');
    await tester.pump();
    expect(button(tester, t('spaces.create.button')).enabled, isTrue);
    expect(find.text(t('spaces.field.urlHelper')), findsOneWidget);
    expect(kit.settings?.spaces, isEmpty);
  });

  testWidgets('joins only once there are an invite, its code and a folder', (tester) async {
    await _open(tester);
    await tapButton(tester, t('spaces.join'));
    expect(find.text(t('spaces.join.body')), findsOneWidget);

    await tester.enterText(field(t('spaces.field.invite')), 'bmc-space:abc');
    await tester.enterText(field(t('sync.field.url')), folder);
    await tester.pump();
    expect(button(tester, t('spaces.join.button')).enabled, isFalse);

    await tester.enterText(field(t('spaces.field.code')), 'AAAA-BBBB-CCCC');
    await tester.pump();
    expect(button(tester, t('spaces.join.button')).enabled, isTrue);
  });

  testWidgets('starts a space’s folder from the login the vault syncs with', (tester) async {
    final kit = await _open(
      tester,
      settings: SyncSettings(
        personal: SyncTarget(dav: _dav, file: syncFile, key: b64(randomBytes(32))),
      ),
    );

    await tapButton(tester, t('spaces.join'));

    expect(tester.widget<TextField>(field(t('sync.field.username'))).controller?.text, 'me');
    expect(tester.widget<TextField>(field(t('sync.field.password'))).controller?.text, 'app-pw');
    expect(tester.widget<TextField>(field(t('sync.field.url'))).controller?.text, isEmpty);
    expect(kit.settings?.personal?.dav, _dav);
  });

  testWidgets('scans an invite into its field', (tester) async {
    final scanner = FakeScanner();
    final kit = await _open(tester, scanner: scanner);
    final invite = await sealInvite(
      SpaceInvite(id: 'x', name: 'X', file: 'backmycodes-space-x.json', key: Uint8List(32)),
      'AAAA-BBBB-CCCC',
      derive: fastKdf,
    );
    await tapButton(tester, t('spaces.join'));

    await tester.tap(find.byTooltip(t('recovery.collect.scan')));
    await tester.pumpAndSettle();
    expect(find.byType(QrViewfinder), findsOneWidget);
    expect(field(t('spaces.field.invite')), findsNothing);

    await scanner.emitScan(tester, invite);
    await tester.pumpAndSettle();

    expect(find.byType(QrViewfinder), findsNothing);
    expect(tester.widget<TextField>(field(t('spaces.field.invite'))).controller?.text, invite);
    expect(kit.settings?.spaces, isEmpty);
  });

  testWidgets('stops scanning and goes back to typing the invite', (tester) async {
    await _open(tester, scanner: FakeScanner());
    await tapButton(tester, t('spaces.join'));
    await tester.tap(find.byTooltip(t('recovery.collect.scan')));
    await tester.pumpAndSettle();

    await tapButton(tester, t('recovery.collect.stopScan'));

    expect(find.byType(QrViewfinder), findsNothing);
    expect(field(t('spaces.field.invite')), findsOneWidget);
  });

  testWidgets('says the vault is in no space yet', (tester) async {
    await _open(tester);

    expect(find.text(t('spaces.title')), findsOneWidget);
    expect(find.text(t('spaces.body')), findsOneWidget);
    expect(find.text(t('spaces.empty')), findsOneWidget);
  });

  testWidgets('lists each space with its entries, its server and how its last sync went', (tester) async {
    final semantics = tester.ensureSemantics();
    final kit = await _open(
      tester,
      settings: SyncSettings(spaces: [_space('fam', 'Family'), _space('team', 'Team')]),
      lists: Lists(
        accounts: [
          _account('a', spaceId: 'fam'),
          _account('b', spaceId: 'fam'),
          _account('c'),
        ],
        backupServices: [BackupService(id: 's', serviceName: 'GitHub', codes: const [], spaceId: 'fam', addedAt: 1)],
      ),
    );
    kit.sync.setScopeStatus('team', const ScopeStatus(problem: SyncProblem.auth));
    await tester.pump();

    expect(find.text(t('spaces.empty')), findsNothing);
    expect(
      find.descendant(of: _card('Family'), matching: find.text(t('spaces.row', {'count': 3, 'host': 'dav.example.com'}))),
      findsOneWidget,
    );
    expect(find.descendant(of: _card('Family'), matching: find.text(t('sync.status.never'))), findsOneWidget);
    expect(
      find.descendant(of: _card('Team'), matching: find.text(t('spaces.row', {'count': 0, 'host': 'dav.example.com'}))),
      findsOneWidget,
    );
    final problem = tester.widget<Text>(find.descendant(of: _card('Team'), matching: find.text(t('sync.problem.auth'))));
    expect(problem.style?.color, isNot(tester.widget<Text>(find.text(t('sync.status.never'))).style?.color));
    expect(find.bySemanticsLabel(RegExp('^Family')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('invites someone to a space in the list, and copies the invite', (tester) async {
    final writes = <String?>[];
    answerSensitiveCopies(writes.add);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final family = _space('fam', 'Family');
    await _open(tester, settings: SyncSettings(spaces: [family]));

    await _tapOnCard(tester, 'Family', t('spaces.invite'));
    expect(find.text(t('spaces.invite.title', {'name': 'Family'})), findsOneWidget);
    final code = tester.widget<Text>(_inviteCode()).data!;

    await tapButton(tester, t('spaces.invite.copy'));

    expect(find.text(t('spaces.invite.copied')), findsOneWidget);
    final invite = await openInvite(writes.single!, code, derive: fastKdf);
    expect(invite.id, 'fam');
    expect(invite.name, 'Family');
    expect(invite.file, family.target.file);
    expect(b64(invite.key), family.target.key);
    expect(tester.widget<QrImageView>(find.byType(QrImageView)), isNotNull);

    await tapButton(tester, t('enableBiometric.done'));
    expect(find.text(t('spaces.title')), findsOneWidget);
  });

  testWidgets('leaves a space and takes its entries off this device', (tester) async {
    final team = _space('team', 'Team');
    final kit = await _open(
      tester,
      settings: SyncSettings(spaces: [_space('fam', 'Family'), team]),
      lists: Lists(
        accounts: [
          _account('a', spaceId: 'fam'),
          _account('mine'),
        ],
        backupServices: [BackupService(id: 's', serviceName: 'GitHub', codes: const [], spaceId: 'fam', addedAt: 1)],
      ),
    );
    kit.sync.setScopeStatus('fam', const ScopeStatus(lastSyncAt: 1));

    await _tapOnCard(tester, 'Family', t('spaces.leave'));
    expect(find.text(t('spaces.leave.title', {'name': 'Family'})), findsOneWidget);
    expect(find.text(t('spaces.leave.body')), findsOneWidget);
    await tapButton(tester, t('spaces.leave.confirm'));

    expect(kit.settings?.spaces, [team]);
    expect(kit.vaultState.accounts.map((a) => a.id), ['mine']);
    expect(kit.vaultState.backupServices, isEmpty);
    expect(kit.container.read(syncProvider).status.containsKey('fam'), isFalse);
    expect(find.text('Family'), findsNothing);
  });

  testWidgets("counts a space's keys and notes among its entries", (tester) async {
    await _open(
      tester,
      settings: SyncSettings(spaces: [_space('fam', 'Family')]),
      lists: Lists(
        accounts: [_account('a', spaceId: 'fam')],
        keys: [
          VaultKey(
            id: 'k1',
            name: 'deploy',
            kind: KeyKind.ssh,
            algorithm: 'ed25519',
            privateKey: 'cHJpdmF0ZQ',
            origin: KeyOrigin.generated,
            spaceId: 'fam',
            addedAt: 1,
          ),
        ],
        notes: const [
          SecureNote(id: 'n1', title: 'Flat', spaceId: 'fam', addedAt: 1),
          SecureNote(id: 'n2', title: 'Mine', addedAt: 1),
        ],
      ),
    );

    expect(
      find.descendant(of: _card('Family'), matching: find.text(t('spaces.row', {'count': 3, 'host': 'dav.example.com'}))),
      findsOneWidget,
    );
  });

  testWidgets("leaving a space keeps the vault's own keys, notes and passkeys", (tester) async {
    const mine = SecureNote(id: 'n-mine', title: 'Mine', addedAt: 1);
    final key = VaultKey(
      id: 'k-mine',
      name: 'laptop',
      kind: KeyKind.ssh,
      algorithm: 'ed25519',
      privateKey: 'cHJpdmF0ZQ',
      origin: KeyOrigin.generated,
      addedAt: 1,
    );
    const passkey = Passkey(
      id: 'p1',
      credentialId: 'AAECAwQFBgcICQoLDA0ODw',
      rpId: 'github.com',
      userHandle: 'dXNlcg',
      userName: 'me@example.com',
      privateKey: 'AA==',
      addedAt: 1,
    );
    final kit = await _open(
      tester,
      settings: SyncSettings(spaces: [_space('fam', 'Family'), _space('team', 'Team')]),
      lists: Lists(
        keys: [
          key,
          key.copyWith(id: 'k-fam', spaceId: 'fam'),
        ],
        notes: const [
          mine,
          SecureNote(id: 'n-fam', title: 'Flat', spaceId: 'fam', addedAt: 1),
          SecureNote(id: 'n-team', title: 'Rota', spaceId: 'team', addedAt: 1),
        ],
        passkeys: const [passkey],
      ),
    );

    await _tapOnCard(tester, 'Family', t('spaces.leave'));
    await tapButton(tester, t('spaces.leave.confirm'));

    expect(kit.vaultState.keys.map((k) => k.id), ['k-mine']);
    expect(kit.vaultState.notes.map((n) => n.id), ['n-mine', 'n-team']);
    expect(kit.vaultState.passkeys, [passkey]);
  });

  testWidgets('stays in a space when leaving is cancelled', (tester) async {
    final family = _space('fam', 'Family');
    final kit = await _open(
      tester,
      settings: SyncSettings(spaces: [family]),
      lists: Lists(accounts: [_account('a', spaceId: 'fam')]),
    );

    await _tapOnCard(tester, 'Family', t('spaces.leave'));
    await tapButton(tester, t('changePw.cancel'));

    expect(kit.settings?.spaces, [family]);
    expect(kit.vaultState.accounts.map((a) => a.id), ['a']);
  });

  testWidgets('goes back to the list from a form, and closes', (tester) async {
    await _open(tester);
    await tapButton(tester, t('spaces.create'));
    await tester.enterText(field(t('spaces.field.name')), 'Family');

    await tapButton(tester, t('changePw.cancel'));
    expect(find.text(t('spaces.empty')), findsOneWidget);

    // The form starts empty again
    await tapButton(tester, t('spaces.create'));
    expect(tester.widget<TextField>(field(t('spaces.field.name'))).controller?.text, isEmpty);
    await tapButton(tester, t('changePw.cancel'));

    await tapButton(tester, t('export.close'));
    expect(find.byType(SpacesSheet), findsNothing);
  });

  // openspec: add-offline-mode, "Setting up a server waits"
  group('while offline mode is on', () {
    testWidgets('says sync is paused, keeps each space and its last sync, and cannot create or join', (tester) async {
      final space = _space('s1', 'Family');
      final kit = await _open(tester, settings: SyncSettings(spaces: [space]));
      kit.sync.setScopeStatus('s1', ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.setOffline(tester, true);

      expect(offlineAlert(t('sync.offline')), findsOneWidget);
      expect(find.text('Family'), findsOneWidget);
      expect(button(tester, t('spaces.create')).onPressed, isNull);
      expect(button(tester, t('spaces.join')).onPressed, isNull);
      expect(kit.container.read(syncProvider).status['s1']?.problem, isNull);
      expect(kit.server.requests, isEmpty);

      await tapButton(tester, t('offline.settings'));
      expect(find.byType(SpacesSheet), findsNothing);
    });

    testWidgets('a form already open says so and cannot create', (tester) async {
      final kit = await _open(tester);
      await tapButton(tester, t('spaces.create'));
      await tester.enterText(field(t('spaces.field.name')), 'Family');
      await kit.fillDav(tester);
      await kit.setOffline(tester, true);

      expect(offlineAlert(t('sync.offline.setup')), findsOneWidget);
      expect(button(tester, t('spaces.create.button')).onPressed, isNull);
      expect(kit.server.requests, isEmpty);
      expect(kit.settings?.spaces, isEmpty);
    });

    testWidgets('refuses a scanned invite and keeps nothing of it', (tester) async {
      final scanner = FakeScanner();
      final kit = await _open(tester, scanner: scanner);
      final invite = await sealInvite(
        SpaceInvite(id: 'x', name: 'X', file: 'backmycodes-space-x.json', key: Uint8List(32)),
        'AAAA-BBBB-CCCC',
        derive: fastKdf,
      );
      await tapButton(tester, t('spaces.join'));
      await tester.tap(find.byTooltip(t('recovery.collect.scan')));
      await tester.pumpAndSettle();
      await kit.setOffline(tester, true);

      await scanner.emitScan(tester, invite);
      await tester.pumpAndSettle();

      expect(find.text(t('sync.offline.invite')), findsOneWidget);
      expect(tester.widget<TextField>(field(t('spaces.field.invite'))).controller?.text, isEmpty);
      expect(button(tester, t('spaces.join.button')).onPressed, isNull);
      expect(kit.settings?.spaces, isEmpty);
      expect(kit.server.requests, isEmpty);
    });
  });
}
