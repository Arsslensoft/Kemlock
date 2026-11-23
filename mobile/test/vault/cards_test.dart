import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

class _NoBiometrics implements Biometrics {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// A vault store whose saves of cards fail on demand, as a full disk would.
class _FlakyStore extends VaultStore {
  _FlakyStore(super.store, super.vaults) : super(deriveKey: fastKdf);

  bool failSaves = false;

  @override
  Future<void> saveCards(List<PaymentCard> cards, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveCards(cards, session);
}

const _visa = PaymentCard(
  id: 'c1',
  name: 'Everyday Visa',
  cardholder: 'Ada Lovelace',
  number: '4111111111111111',
  expMonth: 5,
  expYear: 2029,
  code: '123',
  pin: '4321',
  addedAt: 0,
);

const _me = Identity(
  id: 'i1',
  name: 'Me',
  givenName: 'Ada',
  familyName: 'Lovelace',
  email: 'ada@example.org',
  address: IdentityAddress(lines: ['1 Example Road'], city: 'London', country: 'GB'),
  documents: [IdentityDocument(id: 'd1', type: 'passport', number: '987654321', expiresOn: '2031-03-14')],
  addedAt: 0,
);

void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late _FlakyStore vaultStore;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 11, 21, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = _FlakyStore(store, vaults);
    now = DateTime.utc(2026, 11, 21, 12);
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(catalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(_NoBiometrics()),
        FakeUnlockKeys(available: false).asOverride,
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);
  VaultState state() => container.read(vaultControllerProvider);
  ToastMessage? toast() => container.read(toastsProvider);
  String t(String id, [Map<String, Object?> args = const {}]) => catalog.of(AppLocale.en).t(id, args);
  int ms() => now.millisecondsSinceEpoch;

  Future<VaultSession> openNew() async {
    final session = await vaultStore.setupVault('pw');
    await controller().open(session);
    return session;
  }

  test('a vault without them has neither storage key', () async {
    await openNew();
    expect(state().cards, isEmpty);
    expect(state().identities, isEmpty);
    expect(store.getItem('backmycodes_card_data'), isNull);
    expect(store.getItem('backmycodes_identity_data'), isNull);
  });

  group('cards', () {
    test('are added, stamped and saved encrypted, and come back at the next opening', () async {
      final session = await openNew();

      expect(await controller().addCard(_visa), isTrue);

      final card = state().cards.single;
      expect((card.addedAt, card.updatedAt), (ms(), ms()));
      expect(state().revision, 1);
      expect(toast()?.message, t('vault.snack.cardAdded', {'name': 'Everyday Visa'}));
      final stored = store.getItem('backmycodes_card_data')!;
      for (final secret in ['4111111111111111', 'Everyday Visa', 'Ada Lovelace', '4321']) {
        expect(stored, isNot(contains(secret)));
      }
      expect(store.getItem('backmycodes_identity_data'), isNull);

      controller().lock();
      await controller().open(session);
      expect(state().cards, [card]);
    });

    test('are edited and stamped', () async {
      await openNew();
      await controller().addCard(_visa);

      now = now.add(const Duration(days: 1));
      expect(await controller().updateCard(state().cards.single.copyWith(name: 'Travel Visa')), isTrue);

      expect(state().cards.single.name, 'Travel Visa');
      expect(state().cards.single.updatedAt, ms());
    });

    test('are deleted with Undo, and come back with every field', () async {
      await openNew();
      await controller().addCard(_visa);
      final before = state().cards.single;

      await controller().deleteCard(before);
      expect(state().cards, isEmpty);
      expect(toast()?.message, t('vault.snack.cardRemoved', {'name': 'Everyday Visa'}));

      toast()!.onAction!();
      await pumpEventQueue();
      expect(state().cards.single.toJson()..remove('updatedAt'), before.toJson()..remove('updatedAt'));
    });

    test('a failed save puts the list back as it was, and says so', () async {
      await openNew();
      await controller().addCard(_visa);
      final before = state().cards;

      vaultStore.failSaves = true;
      expect(await controller().updateCard(before.single.copyWith(name: 'Other')), isFalse);

      expect(state().cards, before);
      expect(toast()?.message, t('vault.snack.cardUpdateFailed'));
    });
  });

  group('identities', () {
    test('are added, stamped and saved encrypted, and come back at the next opening', () async {
      final session = await openNew();

      expect(await controller().addIdentity(_me), isTrue);

      final identity = state().identities.single;
      expect((identity.addedAt, identity.updatedAt), (ms(), ms()));
      expect(toast()?.message, t('vault.snack.identityAdded', {'name': 'Me'}));
      final stored = store.getItem('backmycodes_identity_data')!;
      for (final secret in ['ada@example.org', 'Example Road', '987654321', 'Lovelace']) {
        expect(stored, isNot(contains(secret)));
      }
      expect(store.getItem('backmycodes_card_data'), isNull);

      controller().lock();
      await controller().open(session);
      expect(state().identities, [identity]);
    });

    test('are deleted with Undo, with both documents', () async {
      await openNew();
      await controller().addIdentity(
        _me.copyWith(
          documents: [
            ..._me.documents!,
            const IdentityDocument(id: 'd2', type: 'idCard', number: '5'),
          ],
        ),
      );
      final before = state().identities.single;

      await controller().deleteIdentity(before);
      expect(state().identities, isEmpty);

      toast()!.onAction!();
      await pumpEventQueue();
      expect(state().identities.single.documents, before.documents);
    });
  });

  test('come in with an import, each once, and are saved', () async {
    final session = await openNew();
    await controller().addCard(_visa);
    await controller().addIdentity(_me);

    await controller().imported(
      const [],
      const [],
      cards: [
        _visa.copyWith(name: 'Theirs'),
        _visa.copyWith(id: 'c2'),
      ],
      identities: [
        _me.copyWith(name: 'Theirs'),
        _me.copyWith(id: 'i2'),
      ],
    );

    expect(state().cards.map((card) => (card.id, card.name)), [('c1', 'Everyday Visa'), ('c2', 'Everyday Visa')]);
    expect(state().identities.map((identity) => identity.id), ['i1', 'i2']);
    expect((await vaultStore.loadCards(session)).map((card) => card.id), ['c1', 'c2']);
    expect((await vaultStore.loadIdentities(session)).map((identity) => identity.id), ['i1', 'i2']);
  });

  test('go with their vault, and are sealed again with a new key pair', () async {
    final session = await openNew();
    await controller().addCard(_visa);
    await controller().addIdentity(_me);
    expect(vaultStore.sealedValueKeys(mainVault), containsAll(['backmycodes_card_data', 'backmycodes_identity_data']));

    vaults.removeVaultData(mainVault);
    expect(store.getItem('backmycodes_card_data'), isNull);
    expect(store.getItem('backmycodes_identity_data'), isNull);
    expect(await vaultStore.loadCards(session), isEmpty);
    expect(await vaultStore.loadIdentities(session), isEmpty);
  });
}
