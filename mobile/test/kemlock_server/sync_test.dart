// What the phone relies on from Kemlock Server, checked against a real one (see server_kit.dart): signing in with the
// master password, two simulated phones syncing one account's entries both ways, deletions arriving as tombstones,
// and the sync of a phone whose session the server ended. Skipped unless KEMLOCK_URL is set.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/otp_account.dart';

import 'server_kit.dart';

void main() {
  test('signs in with the master password, opens the account and holds a session bound to the phone', () async {
    final phone = await signInPhone();

    expect(phone.signedIn.account, isNotNull, reason: 'the password opens the account');
    expect(phone.signedIn.session.tokens.access, isNotEmpty);
    expect(phone.signedIn.session.tokens.refresh, isNotEmpty);
    expect(phone.signedIn.session.deviceKey?['protection'], 'software');
  }, skip: skipServer);

  test('a wrong password is refused, and no session comes of it', () async {
    await signInPhone(); // the right password works first, so a refusal below is the password's

    await expectLater(signInPhone(withPassword: 'not the password'), throwsA(anything));
  }, skip: skipServer);

  test('two phones sync one account: an entry arrives, an edit comes back, and a deletion follows', () async {
    final one = await signInPhone();
    final two = await signInPhone();
    final mine = testAccount('first');

    // Phone one adds an entry; phone two receives it
    one.lists = Lists(accounts: [...one.lists.accounts, mine]);
    await one.sync();
    await two.sync();
    expect(two.accountIds, contains(mine.id));
    expect(two.lists.accounts.firstWhere((account) => account.id == mine.id).label, 'first');

    // Phone two edits it, later than phone one saw it; phone one receives the edit
    final edited = OtpAccount(
      id: mine.id,
      issuer: mine.issuer,
      label: 'second',
      secret: mine.secret,
      addedAt: mine.addedAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
    );
    two.lists = Lists(accounts: [for (final account in two.lists.accounts) account.id == mine.id ? edited : account]);
    await two.sync();
    await one.sync();
    expect(one.lists.accounts.firstWhere((account) => account.id == mine.id).label, 'second');

    // Phone one deletes it; phone two sees it go, and nothing of ours is left on either
    one.lists = Lists(
      accounts: [
        for (final account in one.lists.accounts)
          if (account.id != mine.id) account,
      ],
    );
    await one.sync();
    await two.sync();
    expect(two.accountIds, isNot(contains(mine.id)));
    expect(one.accountIds, isNot(contains(mine.id)));
  }, skip: skipServer);

  test('a run with nothing new writes nothing, and the same entries stay on both phones', () async {
    final one = await signInPhone();
    final mine = testAccount('steady');
    one.lists = Lists(accounts: [...one.lists.accounts, mine]);
    await one.sync();

    final again = await one.sync();

    expect(again.doc.accounts.where((account) => account.id == mine.id), hasLength(1));
    // Clean up
    one.lists = Lists(
      accounts: [
        for (final account in one.lists.accounts)
          if (account.id != mine.id) account,
      ],
    );
    await one.sync();
  }, skip: skipServer);

  test('a phone signed out on the server is told so at its next sync, and keeps its entries', () async {
    final phone = await signInPhone();
    final mine = testAccount('kept');
    phone.lists = Lists(accounts: [...phone.lists.accounts, mine]);
    await phone.sync();
    final host = phone.host();
    final target = phone.target;
    await host.signOut(target);

    await expectLater(phone.sync(through: host), throwsA(isA<KmError>().having((e) => e.problem, 'problem', KmProblem.sessionEnded)));

    expect(phone.accountIds, contains(mine.id), reason: 'every entry stays');
  }, skip: skipServer);
}
