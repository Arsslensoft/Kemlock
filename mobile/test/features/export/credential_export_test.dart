import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/credential_export.dart';
import 'package:kemlock/features/export/credential_export_sheet.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/import/formats/cxf_writer.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/platform/credential_exchange.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_credential_exchange.dart';
import '../../fakes/fake_owner_check.dart';
import '../../helpers/test_app.dart';
import '../spaces/chain_kit.dart';
import '../spaces/policy_kit.dart';
import 'transfer_harness.dart';

// The add-credential-exchange plan, task 8.2

const _login = Login(id: 'l1', name: 'Larkspur', username: 'ada', password: 'hunter2-secret', addedAt: 0);
const _family = Login(id: 'l2', name: 'Family router', username: 'admin', password: 'family-secret', spaceId: 'family', addedAt: 0);
const _card = PaymentCard(id: 'c1', name: 'Everyday Visa', number: '4111111111111111', addedAt: 0);
const _code = OtpAccount(id: 'o1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _hotp = OtpAccount(id: 'o2', issuer: 'Bank', label: 'ada', secret: 'JBSWY3DPEHPK3PXP', type: OtpType.hotp, addedAt: 0);

/// A WebDAV space, which has no grants, so the passwords of its logins are never hidden
final _familySpace = Space(
  id: 'family',
  name: 'family',
  target: SyncTarget(
    dav: const DavAccount(url: 'https://dav.example.com/f', username: 'u', password: 'p'),
    file: syncFile,
    key: 'a2V5',
  ),
  joinedAt: 1,
);

const _familyToo = Login(id: 'l6', name: 'Family printer', username: 'admin', password: 'printer-secret', spaceId: 'family', addedAt: 0);
const _webDavLogin = Login(id: 'l5', name: 'Club wiki', username: 'ada', password: 'wiki-secret', spaceId: 'webdav-1', addedAt: 0);
final _webDavSpace = Space(
  id: 'webdav-1',
  name: 'Club',
  target: SyncTarget(
    dav: const DavAccount(url: 'https://dav.example.com/f', username: 'u', password: 'p'),
    file: syncFile,
    key: 'a2V5',
  ),
  joinedAt: 1,
);

/// The vault's sync settings as a test gives them.
class _SyncWith extends SyncNotifier {
  _SyncWith(this.settings);

  final SyncSettings settings;

  @override
  SyncSnapshot build() => SyncSnapshot(settings: settings);
}

const _noted = Login(
  id: 'l7',
  name: 'Larkspur notes',
  username: 'ada',
  password: 'noted-secret',
  note: 'key is under the doormat',
  addedAt: 0,
);
const _removed = Login(id: 'l3', name: 'Deleted meanwhile', username: 'bob', password: 'deleted-secret', addedAt: 0);
const _added = Login(id: 'l4', name: 'Added meanwhile', username: 'eve', password: 'added-secret', addedAt: 0);

/// What the server spaces say once one has begun to hide the password of the login [id].
class _HidesLogin extends HiddenPasswords {
  const _HidesLogin(this.id);

  final String id;

  @override
  bool hides(Login login) => login.id == id;
}

/// A [HiddenPasswordsNotifier] a test can change while a sheet is up.
class _HidingPasswords extends HiddenPasswordsNotifier {
  void hide(String id) => state = _HidesLogin(id);
}

/// Pumps ten seconds, so the toasts a sheet leaves are gone before a low button is tapped.
Future<void> _clearToasts(WidgetTester tester) => tester.pump(const Duration(seconds: 10));

Finder get _send => find.text(t('export.cxf.button'));

void main() {
  group('the export sheet row', () {
    final exchange = FakeIosCredentialExchange();
    final transfer = FakeCredentialTransfer();

    testWidgets('shows no row while export is switched off, on either phone', (tester) async {
      await openSheet(tester, showExportSheet, overrides: [exchange.asOverride, transfer.asOverride]);

      expect(find.text(t('export.cxf.row.title')), findsNothing);
      expect(find.text(t('export.cxf.row.button')), findsNothing);
    });

    testWidgets('offers a button on iOS 26 once it is switched on, and the steps on Android', (tester) async {
      await openSheet(
        tester,
        showExportSheet,
        overrides: [credentialExportEnabledProvider.overrideWithValue(true), exchange.asOverride, transfer.asOverride],
      );
      expect(find.text(t('export.cxf.row.button')), findsOneWidget);
      expect(find.text(t('export.cxf.row.ios')), findsOneWidget);

      final android = FakeIosCredentialExchange(isSupported: false);
      await openSheet(
        tester,
        showExportSheet,
        overrides: [credentialExportEnabledProvider.overrideWithValue(true), android.asOverride, transfer.asOverride],
      );
      expect(find.text(t('export.cxf.row.button')), findsNothing);
      expect(find.text(t('export.cxf.row.android')), findsOneWidget);
    });

    testWidgets('shows no row on a phone that can do neither', (tester) async {
      await openSheet(
        tester,
        showExportSheet,
        overrides: [
          credentialExportEnabledProvider.overrideWithValue(true),
          FakeIosCredentialExchange(isSupported: false).asOverride,
          FakeCredentialTransfer(available: false).asOverride,
        ],
      );

      expect(find.text(t('export.cxf.row.title')), findsNothing);
    });
  });

  group('the sheet', () {
    testWidgets('says what goes and that the app is chosen next, and reads nothing yet', (tester) async {
      final target = FakeExportTarget();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login], accounts: const [_code], cards: const [_card]),
      );

      final items =
          '${t('export.cxf.kind.logins', {'count': 1})}, ${t('export.cxf.kind.codes', {'count': 1})} and ${t('export.cxf.kind.cards', {'count': 1})}';
      expect(items, '1 login, 1 code and 1 card');
      expect(find.text(t('export.cxf.summary.ios', {'items': items})), findsOneWidget);
      expect(find.text(t('export.cxf.body.ios')), findsOneWidget);
      expect(find.text(t('export.cxf.warning')), findsOneWidget);
      expect(target.sent, isEmpty);
    });

    testWidgets('names the receiving app when the system has named one', (tester) async {
      final target = FakeExportTarget(appName: '1Password');
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login]),
      );

      expect(find.text(t('export.cxf.summary.named', {'items': '1 login', 'app': '1Password'})), findsOneWidget);
      expect(find.text(t('export.cxf.body.named', {'app': '1Password'})), findsOneWidget);
    });

    testWidgets('asks the owner first, then sends the items as Credential Exchange', (tester) async {
      final target = FakeExportTarget();
      final ownerCheck = FakeOwnerCheck();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login], cards: const [_card]),
        ownerCheck: ownerCheck,
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(ownerCheck.reasons, [t('export.cxf.confirm')]);
      final sent = jsonDecode(target.sent.single) as Map<String, Object?>;
      expect((sent['version'] as Map)['major'], 1);
      final titles = [for (final item in ((sent['accounts'] as List).single as Map)['items'] as List) (item as Map)['title']];
      expect(titles, containsAll(['Larkspur', 'Everyday Visa']));
      expect(find.text(t('export.cxf.sent')), findsOneWidget);
      expect(target.cancelled, 0);
    });

    testWidgets("writes the vault's own id as the account id", (tester) async {
      final target = FakeExportTarget();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login]),
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      // RecordingVault opens the vault with the id 'test'
      final account = ((jsonDecode(target.sent.single) as Map<String, Object?>)['accounts']! as List<Object?>).single! as Map;
      expect(account['id'], cxfId('test'));
      expect(account['id'], isNot(cxfId('kemlock')));
    });

    testWidgets('cancelling the owner check reads nothing, sends nothing and tells the other app', (tester) async {
      final target = FakeExportTarget(appName: '1Password');
      final ownerCheck = FakeOwnerCheck(passes: false);
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login]),
        ownerCheck: ownerCheck,
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(ownerCheck.reasons, hasLength(1));
      expect(target.sent, isEmpty);
      expect(target.cancelled, greaterThanOrEqualTo(1));
      expect(find.byType(CredentialExportSheet), findsNothing, reason: 'the sheet closes');
    });

    testWidgets('closing it without sending tells the other app nothing is coming', (tester) async {
      final target = FakeExportTarget(appName: '1Password');
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login]),
      );
      await _clearToasts(tester);

      await tapOn(tester, find.text(t('export.cancel')));

      expect(target.cancelled, greaterThanOrEqualTo(1));
      expect(target.sent, isEmpty);
    });

    testWidgets('leaves out the items of a space that forbids export, and names the space', (tester) async {
      final target = FakeExportTarget();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login, _family]),
        overrides: [
          // A WebDAV space of the settings: not a server space, whose items stay out whole, and not one whose passwords
          // fail closed, so only its rules (the policy of 7.4 will name them) leave it out
          syncProvider.overrideWith(() => _SyncWith(SyncSettings(spaces: [_familySpace]))),
          blockedExportSpacesProvider.overrideWithValue({'family'}),
        ],
      );
      await _clearToasts(tester);

      expect(find.text(t('export.cxf.space', {'count': 1, 'name': 'family'})), findsOneWidget);
      expect(find.text(t('export.cxf.kind.logins', {'count': 1})), findsWidgets);

      await tapOn(tester, _send);

      final text = target.sent.single;
      expect(text, contains('Larkspur'));
      expect(text, isNot(contains('Family router')));
      expect(text, isNot(contains('family-secret')));
    });

    testWidgets('lists what has no Credential Exchange type before anything is read', (tester) async {
      final target = FakeExportTarget();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(
          logins: const [_login],
          accounts: const [_code, _hotp],
          services: const [BackupService(id: 's1', serviceName: 'Bank', codes: [], addedAt: 0)],
        ),
      );

      expect(find.text(t('export.cxf.leftOut.title')), findsOneWidget);
      expect(find.text(t('export.cxf.leftOut.backupServices', {'count': 1})), findsOneWidget);
      expect(find.text(t('export.cxf.leftOut.notTotp', {'count': 1})), findsOneWidget);
      expect(target.sent, isEmpty);
    });

    testWidgets('lets the person turn a kind off, and sends no more than what is on', (tester) async {
      final target = FakeExportTarget();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login], cards: const [_card]),
      );
      await _clearToasts(tester);

      await tapOn(tester, find.text(t('export.cxf.kind.cards', {'count': 1})));
      await tapOn(tester, _send);

      expect(target.sent.single, contains('Larkspur'));
      expect(target.sent.single, isNot(contains('4111111111111111')));
    });

    testWidgets('leaves out a kind the other app did not ask for, and says so', (tester) async {
      final target = FakeExportTarget(appName: 'Bitwarden', askedTypes: const {'basic-auth'});
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login], cards: const [_card]),
      );
      await _clearToasts(tester);

      expect(find.text(t('export.cxf.kind.notAsked', {'app': 'Bitwarden'})), findsOneWidget);
      await tapOn(tester, _send);

      expect(target.sent.single, contains('Larkspur'));
      expect(target.sent.single, isNot(contains('4111111111111111')));
    });

    testWidgets('refuses a request meant for another vault, and offers no send', (tester) async {
      final target = FakeExportTarget(appName: '1Password', vaultId: 'another');
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login]),
      );

      expect(find.text(t('export.cxf.wrongVault')), findsOneWidget);
      expect(_send, findsNothing);
      expect(target.sent, isEmpty);
    });

    testWidgets('says each way the hand-off can fail, with nothing of the data', (tester) async {
      for (final (outcome, message) in [
        (const CredentialExportCancelled(), 'export.cxf.error.cancelled'),
        (const CredentialExportFailed(), 'export.cxf.error.failed'),
        (StateError('hunter2-secret'), 'export.cxf.error.failed'),
      ]) {
        final target = FakeExportTarget(outcome: outcome);
        await openSheet(
          tester,
          (context) => showCredentialExportSheet(context, target: target),
          vault: RecordingVault(logins: const [_login]),
        );
        await _clearToasts(tester);

        await tapOn(tester, _send);

        expect(find.text(t(message)), findsOneWidget);
        expect(find.textContaining('hunter2'), findsNothing);
        expect(find.text(t('export.cxf.sent')), findsNothing);
      }
    });
  });

  group('after the owner check', () {
    testWidgets('sends the vault as it is then, not as the sheet drew it', (tester) async {
      final target = FakeExportTarget();
      final vault = RecordingVault(logins: const [_login, _removed]);
      final ownerCheck = FakeOwnerCheck(whileAsking: () => vault.change((state) => state.copyWith(logins: const [_login, _added])));
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: vault,
        ownerCheck: ownerCheck,
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      final text = target.sent.single;
      expect(text, contains('Larkspur'));
      expect(text, contains('Added meanwhile'));
      expect(text, isNot(contains('Deleted meanwhile')));
      expect(text, isNot(contains('deleted-secret')));
    });

    testWidgets('leaves out a password a space began to hide while the check was up', (tester) async {
      final target = FakeExportTarget();
      late ProviderContainer container;
      final ownerCheck = FakeOwnerCheck(
        whileAsking: () => (container.read(hiddenPasswordsProvider.notifier) as _HidingPasswords).hide('l1'),
      );
      container = await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login], cards: const [_card]),
        ownerCheck: ownerCheck,
        overrides: [hiddenPasswordsProvider.overrideWith(_HidingPasswords.new)],
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(target.sent.single, contains('4111111111111111'));
      expect(target.sent.single, isNot(contains('hunter2-secret')));
    });

    testWidgets('sends nothing when the vault was swapped for another during the check', (tester) async {
      final target = FakeExportTarget(appName: '1Password', vaultId: 'test');
      final vault = RecordingVault(logins: const [_login]);
      final ownerCheck = FakeOwnerCheck(
        whileAsking: () => vault.change((state) => state.copyWith(vault: const VaultInfo(id: 'other'))),
      );
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: vault,
        ownerCheck: ownerCheck,
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(target.sent, isEmpty);
      expect(target.cancelled, greaterThanOrEqualTo(1));
      expect(find.text(t('export.cxf.wrongVault')), findsWidgets);
    });

    testWidgets('two quick taps start one check and one export', (tester) async {
      final target = FakeExportTarget();
      final release = Completer<void>();
      final ownerCheck = FakeOwnerCheck(whileAsking: () => release.future);
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login]),
        ownerCheck: ownerCheck,
      );
      await _clearToasts(tester);
      await tester.ensureVisible(_send);
      await tester.pumpAndSettle();

      // No frame between the taps: the second one reaches the button the first one did
      await tester.tap(_send);
      await tester.tap(_send);
      await tester.pump();

      expect(ownerCheck.reasons, hasLength(1));
      release.complete();
      await tester.pumpAndSettle();
      expect(ownerCheck.reasons, hasLength(1));
      expect(target.sent, hasLength(1));
    });

    testWidgets('sends nothing when the vault is locked again by then', (tester) async {
      final target = FakeExportTarget();
      final vault = RecordingVault(logins: const [_login]);
      final ownerCheck = FakeOwnerCheck(whileAsking: () => vault.change((state) => state.copyWith(phase: VaultPhase.locked)));
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: vault,
        ownerCheck: ownerCheck,
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(target.sent, isEmpty);
      expect(target.cancelled, greaterThanOrEqualTo(1));
    });
  });

  group('on iOS', () {
    testWidgets('hands the JSON to the system and says it went', (tester) async {
      final exchange = FakeIosCredentialExchange();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: IosExportTarget(exchange)),
        vault: RecordingVault(logins: const [_login]),
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(exchange.exported.single, contains('Larkspur'));
      expect(find.text(t('export.cxf.sent')), findsOneWidget);
    });

    testWidgets('closing the system sheet is a cancel, not a failure', (tester) async {
      final exchange = FakeIosCredentialExchange()..exportOutcome = const IosExportCancelled();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: IosExportTarget(exchange)),
        vault: RecordingVault(logins: const [_login]),
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(find.text(t('export.cxf.error.cancelled')), findsOneWidget);
      expect(exchange.exported, isEmpty);
      // The person never went on, so the payload was never made
      expect(exchange.produced, 0);
    });

    testWidgets('makes no payload while the person is still in the system sheet', (tester) async {
      final exchange = FakeIosCredentialExchange()..sheet = Completer<void>();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: IosExportTarget(exchange)),
        vault: RecordingVault(logins: const [_login]),
      );
      await _clearToasts(tester);
      await tester.ensureVisible(_send);
      await tester.pumpAndSettle();

      await tester.tap(_send);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The system's sheet is up: nothing has been written, nowhere
      expect(exchange.produced, 0);
      expect(exchange.exported, isEmpty);

      exchange.sheet!.complete();
      await tester.pumpAndSettle();

      expect(exchange.produced, 1);
      expect(exchange.exported.single, contains('Larkspur'));
      expect(find.text(t('export.cxf.sent')), findsOneWidget);
    });

    testWidgets('makes the payload from the vault as it is once the person has gone on', (tester) async {
      final vault = RecordingVault(logins: const [_login, _removed]);
      final exchange = FakeIosCredentialExchange()..sheet = Completer<void>();
      await openSheet(tester, (context) => showCredentialExportSheet(context, target: IosExportTarget(exchange)), vault: vault);
      await _clearToasts(tester);
      await tester.ensureVisible(_send);
      await tester.pumpAndSettle();
      await tester.tap(_send);
      await tester.pump();

      vault.change((state) => state.copyWith(logins: const [_login, _added]));
      exchange.sheet!.complete();
      await tester.pumpAndSettle();

      final text = exchange.exported.single;
      expect(text, contains('Added meanwhile'));
      expect(text, isNot(contains('Deleted meanwhile')));
    });

    testWidgets('says it failed, with nothing of the data, when the vault was locked while the person chose', (tester) async {
      final vault = RecordingVault(logins: const [_login]);
      final exchange = FakeIosCredentialExchange()..sheet = Completer<void>();
      await openSheet(tester, (context) => showCredentialExportSheet(context, target: IosExportTarget(exchange)), vault: vault);
      await _clearToasts(tester);
      await tester.ensureVisible(_send);
      await tester.pumpAndSettle();
      await tester.tap(_send);
      await tester.pump();

      vault.change((state) => state.copyWith(phase: VaultPhase.locked));
      exchange.sheet!.complete();
      await tester.pumpAndSettle();

      expect(exchange.exported, isEmpty);
      expect(find.text(t('export.cxf.error.failed')), findsOneWidget);
      expect(find.textContaining('hunter2'), findsNothing);
    });
  });

  group('what the other app asked for', () {
    test('a kind is offered only when its main type was asked, and everything when nothing was said', () {
      expect(ExportKind.identities.askedFor(null), isTrue);
      expect(ExportKind.identities.askedFor(const {'person-name'}), isTrue);
      // An address is part of an identity, not the identity
      expect(ExportKind.identities.askedFor(const {'address', 'passport', 'custom-fields'}), isFalse);
      expect(ExportKind.logins.askedFor(const {'totp', 'note'}), isFalse);
      expect(ExportKind.codes.askedFor(const {'totp'}), isTrue);
      expect(ExportKind.notes.askedFor(const {}), isFalse);
      for (final kind in ExportKind.values) {
        expect(kind.askedFor({kind.main}), isTrue, reason: kind.name);
      }
    });

    testWidgets('leaves a login note out unless the note type was asked for', (tester) async {
      final target = FakeExportTarget(appName: 'Bitwarden', askedTypes: const {'basic-auth'});
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_noted]),
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(target.sent.single, contains('Larkspur notes'));
      expect(target.sent.single, isNot(contains('under the doormat')));
    });

    testWidgets('sends the note when it was asked for', (tester) async {
      final target = FakeExportTarget(appName: 'Bitwarden', askedTypes: const {'basic-auth', 'note'});
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_noted]),
      );
      await _clearToasts(tester);

      await tapOn(tester, _send);

      expect(target.sent.single, contains('under the doormat'));
    });
  });

  group('shared server spaces', () {
    // Until add-server-spaces 7.4 gives export a policy, nothing of a server space leaves
    testWidgets('leave every item of a server space out, and the sheet says so', (tester) async {
      final target = FakeExportTarget();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: target),
        vault: RecordingVault(logins: const [_login, _family, _familyToo]),
      );
      await _clearToasts(tester);

      expect(find.text(t('export.cxf.serverSpaces', {'count': 2})), findsOneWidget);
      expect(find.text(t('export.cxf.kind.logins', {'count': 1})), findsWidgets);

      await tapOn(tester, _send);

      final text = target.sent.single;
      expect(text, contains('Larkspur'));
      expect(text, isNot(contains('Family router')));
      expect(text, isNot(contains('family-secret')));
      expect(text, isNot(contains('Family printer')));
    });

    testWidgets('say nothing when the vault holds no item of a shared space', (tester) async {
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: FakeExportTarget()),
        vault: RecordingVault(logins: const [_login]),
      );

      expect(find.textContaining('shared space'), findsNothing);
    });

    test('an item is a server space item unless it is personal or in a WebDAV space the vault lists', () {
      final container = ProviderContainer(
        overrides: [
          syncProvider.overrideWith(() => _SyncWith(SyncSettings(spaces: [_webDavSpace]))),
        ],
      );
      addTearDown(container.dispose);

      final isServer = container.read(serverSpaceItemProvider);

      expect(isServer('webdav-1'), isFalse);
      expect(isServer(''), isFalse);
      expect(isServer('4a000000-0000-4000-8000-0000000000a1'), isTrue);
      expect(isServer('a space this vault has no record of'), isTrue);
    });

    test('a server space whose verified chain forbids export is named, and its items are counted under its name', () {
      final space = uuid(0x5a);
      final held = const SpacePolicies()
          .remembering(space, Person(2).id, spaceWithPolicies(0x5a, Person(2), {'disableExport': true}))
          .naming(space, 'Example Co');
      final container = ProviderContainer(overrides: [spacePoliciesProvider.overrideWith(() => HeldPolicies(held))]);
      addTearDown(container.dispose);

      final blocked = container.read(blockedExportSpacesProvider);
      final plan = planCredentialExport(
        VaultState(
          phase: VaultPhase.unlocked,
          logins: [
            _login,
            _family.copyWith(spaceId: space),
            _webDavLogin,
          ],
          vault: const VaultInfo(id: 'test'),
        ),
        inServerSpace: (id) => id == space,
        blockedSpaces: blocked,
        spaceName: (id) => held.nameOf(id),
      );

      expect(blocked, {space});
      expect(plan.blocked, {'Example Co': 1});
      expect(plan.serverSpaceItems, 0, reason: 'the space that forbids it is named, not counted with the rest');
      expect([for (final login in plan.all.logins) login.id], ['l1', 'l5']);
    });

    test('a server space whose chain allows export still stays out of Credential Exchange, uncounted as blocked', () {
      final space = uuid(0x5a);
      final held = const SpacePolicies().remembering(space, Person(2).id, spaceWithPolicies(0x5a, Person(2)));
      final container = ProviderContainer(overrides: [spacePoliciesProvider.overrideWith(() => HeldPolicies(held))]);
      addTearDown(container.dispose);

      final plan = planCredentialExport(
        VaultState(
          phase: VaultPhase.unlocked,
          logins: [
            _login,
            _family.copyWith(spaceId: space),
          ],
          vault: const VaultInfo(id: 'test'),
        ),
        inServerSpace: (id) => id == space,
        blockedSpaces: container.read(blockedExportSpacesProvider),
      );

      expect(plan.blocked, isEmpty);
      expect(plan.serverSpaceItems, 1);
      expect([for (final login in plan.all.logins) login.id], ['l1']);
    });

    test('while the settings are not read, every space id counts as a server space', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final isServer = container.read(serverSpaceItemProvider);

      expect(isServer('webdav-1'), isTrue);
      expect(isServer(''), isFalse);
    });

    test('the plan counts what it leaves out and keeps personal and WebDAV items', () {
      final plan = planCredentialExport(
        const VaultState(
          phase: VaultPhase.unlocked,
          logins: [_login, _family, _webDavLogin],
          vault: VaultInfo(id: 'test'),
        ),
        inServerSpace: (id) => id == 'family',
      );

      expect(plan.serverSpaceItems, 1);
      expect([for (final login in plan.all.logins) login.id], ['l1', 'l5']);
      expect(plan.counts[ExportKind.logins], 2);
    });
  });

  group('the plan', () {
    test('counts a passkey of another algorithm as left out, and not as something to send', () {
      const es256 = Passkey(
        id: 'p1',
        credentialId: 'AQID',
        rpId: 'larkspur.example',
        userHandle: 'CQ',
        userName: 'ada',
        privateKey: 'AAAA',
        addedAt: 0,
      );
      const eddsa = Passkey(
        id: 'p2',
        credentialId: 'AQID',
        rpId: 'larkspur.example',
        userHandle: 'CQ',
        userName: 'ada',
        privateKey: 'AAAA',
        algorithm: -8,
        addedAt: 0,
      );
      final plan = planCredentialExport(
        const VaultState(
          phase: VaultPhase.unlocked,
          passkeys: [es256, eddsa],
          vault: VaultInfo(id: 'test'),
        ),
        inServerSpace: (id) => false,
      );

      expect(plan.counts[ExportKind.passkeys], 2);
      expect(plan.sendable(ExportKind.passkeys), 1);
      expect(plan.leftOut({ExportKind.passkeys}), {CxfLeftOutReason.algorithm: 1});
    });

    test('counts what the writer would leave out without reading a secret', () {
      final leftOut = cxfLeftOut(const CxfExportItems(codes: [_code, _hotp]));

      expect([for (final item in leftOut) (item.title, item.reason)], [('Bank', CxfLeftOutReason.notTotp)]);
    });
  });
}
