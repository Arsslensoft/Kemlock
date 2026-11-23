import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/import/import_merge.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/vault/vault_export.dart';

import '../compat/before_cards/export_payload.dart';
import 'fast_kdf.dart';

const _accounts = [OtpAccount(id: 'a1', issuer: 'ACME', label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0)];
const _services = [
  BackupService(
    id: 's1',
    serviceName: 'GitHub',
    codes: [BackupCode(code: 'abcd-1234')],
    addedAt: 0,
  ),
];
const _logins = [Login(id: 'l1', name: 'Larkspur Mail', username: 'ada@example.org', password: 'hunter2', addedAt: 2)];
const _cards = [
  PaymentCard(
    id: 'c1',
    name: 'Everyday Visa',
    cardholder: 'Ada Lovelace',
    number: '4111111111111111',
    expMonth: 5,
    expYear: 2029,
    code: '123',
    pin: '4321',
    addedAt: 3,
  ),
  PaymentCard(id: 'c2', name: 'Gift card', cardholder: 'Ada', addedAt: 4),
];
const _identities = [
  Identity(
    id: 'i1',
    name: 'Me',
    email: 'ada@example.org',
    address: IdentityAddress(lines: ['1 Example Road'], city: 'London', country: 'GB'),
    documents: [
      IdentityDocument(id: 'd1', type: 'passport', number: '123456789', expiresOn: '2031-03-14'),
      IdentityDocument(id: 'd2', type: 'idCard', number: '987654321'),
    ],
    addedAt: 5,
  ),
];

// the add-cards-identities-and-websites plan, task 3.4
void main() {
  test('cards and identities round-trip through an encrypted export, with every field, and stay out of its text', () async {
    final file = await exportVault(_accounts, _services, 'pw', logins: _logins, cards: _cards, identities: _identities, deriveKey: fastKdf);

    final payload = await importVault(file, 'pw', deriveKey: fastKdf);

    expect(payload.cards, _cards);
    expect(payload.identities, _identities);
    expect(payload.identities.single.documents, hasLength(2));
    expect(payload.logins, _logins);
    expect(payload.accounts, _accounts);
    for (final secret in ['4111111111111111', '123456789', 'Ada Lovelace']) {
      expect(file, isNot(contains(secret)));
    }
  });

  test('cards and identities round-trip through a plain export, which shows them', () {
    final file = exportVaultPlaintext(_accounts, _services, cards: _cards, identities: _identities);

    final payload = importVaultPlaintext(file);

    expect(payload.cards, _cards);
    expect(payload.identities, _identities);
    expect(file, contains('4111111111111111'), reason: 'a plain export is readable by anyone');
    expect(file, contains('123456789'));
  });

  test('both lists are written only when there is something in them, after the logins', () {
    expect(
      (jsonDecode(exportVaultPlaintext(_accounts, _services, logins: _logins)) as Map<String, Object?>).keys,
      allOf(isNot(contains('cards')), isNot(contains('identities'))),
    );
    final keys = (jsonDecode(
      exportVaultPlaintext(_accounts, _services, logins: _logins, cards: _cards, identities: _identities),
    ) as Map<String, Object?>).keys;
    expect(keys.toList().sublist(keys.length - 3), ['logins', 'cards', 'identities']);
  });

  test('a phone from before cards still reads the codes and logins, and passes the rest over', () {
    final json = jsonDecode(
      exportVaultPlaintext(_accounts, _services, logins: _logins, cards: _cards, identities: _identities),
    ) as Map<String, Object?>;

    final before = payloadBeforeCards(json);

    expect(before.accounts, _accounts);
    expect(before.backupServices, _services);
    expect(before.logins, _logins);
  });

  test('an import adds the cards and identities whose id is new, each once', () {
    final preview = ImportPreview.of(
      importVaultPlaintext(exportVaultPlaintext(_accounts, _services, cards: _cards, identities: _identities)),
    );

    expect(newCards(preview, const []).map((card) => card.id), ['c1', 'c2']);
    expect(newCards(preview, [_cards.first]).map((card) => card.id), ['c2']);
    expect(newIdentities(preview, const []).map((identity) => identity.id), ['i1']);
    expect(newIdentities(preview, _identities), isEmpty);
  });
}
