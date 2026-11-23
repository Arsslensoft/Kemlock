import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_reminders.dart';
import '../../fakes/fake_security_keys.dart';
import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';

/// The secret of RFC 4226 and RFC 6238, and its base32 for a vault account.
final rfcSecret = ascii.encode('12345678901234567890');
final rfcSecretBase32 = base32Encode(rfcSecret);

/// A vault account with the RFC secret, to work out what a key must answer.
OtpAccount rfcVaultAccount({
  String id = 'v1',
  String issuer = 'Example',
  String label = 'alice@example.org',
  String algorithm = 'SHA1',
  int digits = 6,
  int period = 30,
  OtpType type = OtpType.totp,
  int? counter,
  List<String>? tags,
  String? note,
  String? spaceId,
}) => OtpAccount(
  id: id,
  type: type,
  issuer: issuer,
  label: label,
  secret: rfcSecretBase32,
  algorithm: algorithm,
  digits: digits,
  period: period,
  counter: counter,
  tags: tags,
  note: note,
  spaceId: spaceId,
  addedAt: 0,
);

/// The four accounts of the mockup's key: two plain ones, one that needs a
/// touch and a counter-based one, with a 60-second one beside them.
List<FakeOathAccount> usualAccounts() => [
  FakeOathAccount('Example:alice@example.org', rfcSecret),
  FakeOathAccount('60/Slow:bob', rfcSecret, algorithm: 'SHA256', digits: 8),
  FakeOathAccount('Registrar:root', rfcSecret, touch: true),
  FakeOathAccount('Example:counter', rfcSecret, hotp: true),
];

/// An open vault on a fake phone, with a fake key that has the code
/// application: what reading a key needs, and no screen.
///
/// The app's clock is the fake phone's: `rig.phone.elapse(...)` moves both.
class CodesRig {
  CodesRig._(this.phone, this.oath, this.key, this.store, this.vaults, this.vaultStore, this.container);

  final FakeSecurityKeys phone;
  final FakeOathKey oath;
  final FakeKey key;
  final KeyValueStore store;
  final VaultRegistry vaults;
  final VaultStore vaultStore;
  final ProviderContainer container;
  late VaultSession session;

  /// 09:00:10 UTC on the test day: ten seconds into a 30-second period.
  static final start = DateTime.utc(2026, 11, 16, 9, 0, 10);

  static Future<CodesRig> open({
    SecurityKeyCapabilities capabilities = FakeSecurityKeys.android,
    FakeOathKey? oath,
    List<FakeApplet>? applets,
    List<Override> overrides = const [],
  }) async {
    final phone = FakeSecurityKeys(phone: capabilities, start: start);
    final application = oath ?? FakeOathKey(accounts: usualAccounts());
    final key = FakeKey(productName: 'YubiKey 5C NFC', applets: applets ?? [application]);
    final store = KeyValueStore.memory();
    final vaults = VaultRegistry(store);
    final unlockKeys = FakeUnlockKeys(available: false);
    final vaultStore = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: unlockKeys);
    final container = ProviderContainer(
      overrides: [
        FakeReminders().asOverride,
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(testCatalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        unlockKeys.asOverride,
        clockProvider.overrideWithValue(phone.now),
        phone.asOverride,
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    final rig = CodesRig._(phone, application, key, store, vaults, vaultStore, container);
    rig.session = await vaultStore.setupVault('pw');
    await rig.vault.open(rig.session);
    // Keeps the provider alive, as a screen that shows codes does.
    container.listen(keyCodesProvider, (_, _) {});
    return rig;
  }

  VaultController get vault => container.read(vaultControllerProvider.notifier);
  VaultState get vaultState => container.read(vaultControllerProvider);
  KeyCodesController get codes => container.read(keyCodesProvider.notifier);
  KeyCodesState get state => container.read(keyCodesProvider);

  int get nowSec => phone.now().millisecondsSinceEpoch ~/ 1000;

  /// The key is held to the phone ([nfcKey]) or plugged in.
  FakeDevice present({Set<SecurityKeyLinkKind> kinds = nfcKey}) {
    final device = key.device(kinds: kinds);
    phone.arrive(device);
    return device;
  }

  /// What the vault remembers of the account named [name] on the key.
  KeyAccount remembered(String name) => vaultState.keyAccounts.singleWhere((account) => account.name == name);

  /// The code showing now for the account named [name], if any.
  String? showing(String name) => state.codeAt(remembered(name).id, nowSec)?.code;
}

const nfcKey = {SecurityKeyLinkKind.nfc};
const usbKey = {SecurityKeyLinkKind.usbHid, SecurityKeyLinkKind.usbCcid};
const smartcardKey = {SecurityKeyLinkKind.smartcard};
