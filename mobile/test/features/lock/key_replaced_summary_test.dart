import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/key_replaced_summary.dart';
import 'package:kemlock/features/lock/replace_key_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../helpers/test_app.dart';
import '../recovery/recovery_harness.dart';
import '../sync/sync_screen_kit.dart' show fakeSync;

const _account = OtpAccount(id: 'a1', issuer: 'ACME', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _service = BackupService(
  id: 's1',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'abcd-1234')],
  addedAt: 0,
);
const _note = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 0);
const _key = VaultKey(
  id: 'k1',
  name: 'laptop',
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: 'MC4CAQAwBQYDK2VwBCIEIA==',
  publicKey: 'MCowBQYDK2VwAyEA',
  origin: KeyOrigin.generated,
  addedAt: 0,
);
const _passkey = Passkey(
  id: 'p1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  userHandle: 'dXNlcg',
  userName: 'octocat',
  privateKey: 'MIGHAgEAMBMGByqGSM49AgEG',
  addedAt: 0,
);

VaultState _vault({
  List<OtpAccount> accounts = const [],
  List<BackupService> services = const [],
  List<SecureNote> notes = const [],
  List<VaultKey> keys = const [],
  List<Passkey> passkeys = const [],
}) => VaultState(
  phase: VaultPhase.unlocked,
  vault: const VaultInfo(id: mainVault),
  accounts: accounts,
  backupServices: services,
  notes: notes,
  keys: keys,
  passkeys: passkeys,
);

List<String> _lines(VaultState vault, {({bool webDav, bool spaces, bool vaultwarden})? sync, RecoveryKitInfo? oldKit, int? lastExportAt}) =>
    [for (final (_, id) in KeyReplacedSummary.linesFor(vault, sync: sync, oldKit: oldKit, lastExportAt: lastExportAt)) id];

const _noSync = (webDav: false, spaces: false, vaultwarden: false);

/// What the last screen of a key replacement lists (openspec:
/// replace-vault-key-pair, task 6.3).
void main() {
  test('lists nothing for an empty vault, no codes line among it', () {
    expect(_lines(_vault()), isEmpty);
    expect(_lines(_vault(), sync: _noSync), isEmpty);
  });

  test('lists every kind and WebDAV sync for a vault that has them', () {
    final every = _vault(accounts: [_account], services: [_service], notes: [_note], keys: [_key], passkeys: [_passkey]);

    expect(_lines(every, sync: (webDav: true, spaces: false, vaultwarden: false)), [
      'replaceKey.done.codes',
      'replaceKey.done.backupCodes',
      'replaceKey.done.keys',
      'replaceKey.done.passkeys',
      'replaceKey.done.notes',
      'replaceKey.done.webdav',
    ]);
  });

  test('lists the shared spaces for a vault in one', () {
    expect(_lines(_vault(), sync: (webDav: false, spaces: true, vaultwarden: false)), ['replaceKey.done.spaces']);
  });

  test('lists Vaultwarden for a vault that syncs with it', () {
    expect(_lines(_vault(), sync: (webDav: false, spaces: false, vaultwarden: true)), ['replaceKey.done.vaultwarden']);
  });

  test('lists the exports made while the old kit existed, and not those from before it', () {
    const kit = RecoveryKitInfo(kitId: 'OLDKT', threshold: 1, shares: 1, createdAt: '2026-11-01T00:00:00.000Z');
    final made = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;

    expect(_lines(_vault(), oldKit: kit, lastExportAt: made + 1), ['replaceKey.done.exports']);
    expect(_lines(_vault(), oldKit: kit, lastExportAt: made - 1), isEmpty);
    expect(_lines(_vault(), oldKit: kit), isEmpty);
    expect(_lines(_vault(), lastExportAt: made + 1), isEmpty);
  });

  test('no line, in either language, says old backups or exports stopped opening', () {
    final ids = [
      'replaceKey.done.body',
      'replaceKey.done.nothing',
      for (final (_, id) in KeyReplacedSummary.linesFor(
        _vault(accounts: [_account], services: [_service], notes: [_note], keys: [_key], passkeys: [_passkey]),
        sync: (webDav: true, spaces: true, vaultwarden: true),
        oldKit: const RecoveryKitInfo(kitId: 'K', threshold: 1, shares: 1, createdAt: '2026-01-01T00:00:00.000Z'),
        lastExportAt: DateTime.utc(2026, 6).millisecondsSinceEpoch,
      ))
        id,
    ];
    expect(ids, hasLength(11));
    for (final locale in AppLocale.values) {
      for (final id in ids) {
        final text = testCatalog.of(locale).t(id).toLowerCase();
        for (final claim in ['no longer', 'stop', 'safe', 'plus rien de ce qui', 'ne s’ouvre', 'n’ouvrent plus', 'sûr']) {
          expect(text, isNot(contains(claim)), reason: '${locale.name} $id');
        }
      }
    }
  });

  testWidgets('shows what applies once the key is replaced, from what the vault holds', (tester) async {
    final vaults = RecoveryVaults();
    final session = await vaults.vaults.setupVault('pw');
    await vaults.vaults.saveAccounts([_account], session);
    await vaults.vaults.saveNotes([_note], session);
    final settings = SyncSettings.fromJson({
      'personal': {
        'dav': {'url': 'https://dav.example.com/files/me/Kemlock/', 'username': 'me', 'password': 'app-pw'},
        'file': 'backmycodes-sync.json',
        'key': 'a2V5',
      },
    });
    await pumpLauncher(
      tester,
      vaults,
      showReplaceKeySheet,
      overrides: [fakeSync(SyncSnapshot(settings: settings))],
      before: (container) => container.read(vaultControllerProvider.notifier).open(session),
    );

    await tester.enterText(find.byType(TextField), 'pw');
    await tester.pump();
    await tester.tap(find.text(t('replaceKey.button')));
    await tester.pumpAndSettle();

    expect(find.text(t('replaceKey.done.title')), findsOneWidget);
    expect(find.text(t('replaceKey.done.body')), findsOneWidget);
    for (final id in ['replaceKey.done.codes', 'replaceKey.done.notes', 'replaceKey.done.webdav']) {
      expect(find.text(t(id)), findsOneWidget, reason: id);
    }
    for (final id in ['replaceKey.done.backupCodes', 'replaceKey.done.spaces', 'replaceKey.done.vaultwarden', 'replaceKey.done.exports']) {
      expect(find.text(t(id)), findsNothing, reason: id);
    }
  });
}
