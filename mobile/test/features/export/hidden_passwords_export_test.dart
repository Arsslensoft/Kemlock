import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_export.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../spaces/chain_kit.dart';
import 'transfer_harness.dart';

// The regression test of the fail-closed fix (docs/plans/add-server-spaces.md, task 5.5): a file export leaves out a login
// of a server space whose chain hasn't reported, because the grant that decides whether its password is hidden isn't
// known yet, and takes it once a report shows a grant without hide-passwords.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);

  const account = OtpAccount(id: 'acc', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
  const own = Login(id: 'own', name: 'Bank', password: '1234', addedAt: 0);
  const shared = Login(id: 'l1', name: 'Larkspur Mail', username: 'ada', password: 'hunter2', addedAt: 0);

  /// What a run of the space reports for Bob, who holds [permission] on "Everyone", where the login is.
  SpaceHold holdFor(CollectionPermission permission) {
    final chain = ChainBuilder(space)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: permission})
      ..confirm(alice, bob);
    return SpaceHold(chain: chain.state, account: bob.id, collections: {'l1': everyone});
  }

  /// The plain export of a vault holding the vault's own login and one of a server space, after a chain is reported when
  /// [hold] is given.
  Future<VaultExportPayload> exportPlain(WidgetTester tester, {SpaceHold? hold}) async {
    final files = FakeFiles();
    final container = await openSheet(
      tester,
      showExportSheet,
      files: files,
      vault: RecordingVault(
        accounts: const [account],
        logins: [
          own,
          shared.copyWith(spaceId: space),
        ],
      ),
    );
    if (hold != null) {
      container.read(hiddenPasswordsProvider.notifier).remember(space, hold);
      // The chain's policies are what tell a file export that this server space may be exported
      container.read(spacePoliciesProvider.notifier).report(space, bob.id, hold.chain);
      await tester.pump(const Duration(seconds: 10));
    }
    // The sheet is taller while it warns of the items left out, so the mode is scrolled to before it is tapped
    await tapOn(tester, find.text(t('export.mode.plaintext')));
    await tapOn(tester, find.text(t('export.plaintext.button')));
    return importVaultPlaintext(files.lastSavedText);
  }

  testWidgets('a file export leaves out a server space login before its chain reports', (tester) async {
    final payload = await exportPlain(tester);

    expect(payload.logins.map((login) => login.id), ['own']);
    expect(payload.accounts.single.issuer, 'GitHub');
  });

  testWidgets('a file export leaves out a login whose grant hides passwords', (tester) async {
    final payload = await exportPlain(tester, hold: holdFor(CollectionPermission.viewHidePasswords));

    expect(payload.logins.map((login) => login.id), ['own']);
  });

  testWidgets('a file export takes the login once a report shows a grant without hide-passwords', (tester) async {
    final payload = await exportPlain(tester, hold: holdFor(CollectionPermission.edit));

    expect(payload.logins.map((login) => login.id), ['own', 'l1']);
  });
}
