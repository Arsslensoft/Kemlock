import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_core/models/item_link.dart';
import 'package:kemlock_core/vault/item_links.dart';

import '../core/ids.dart';
import '../core/providers.dart';
import '../core/public_suffixes.dart';
import '../core/toasts.dart';
import '../crypto/account/encoding.dart' show Owner;
import '../crypto/p256.dart';
import '../features/backup/backup_codes.dart';
import '../features/contacts/contact_keys.dart' show withCheckedAddresses;
import '../features/duplicates/dedup_store.dart' show DedupStore;
import '../features/duplicates/duplicate_merge.dart';
import '../features/keys/key_bridge.dart' show combinedPgpKey, grownPgpKey, keyIdentity;
import '../features/keys/key_reminders.dart';
import '../features/links/link_account.dart';
import '../features/lock/unlock_attempts.dart';
import '../features/logins/login_inbox.dart';
import '../features/logins/login_sites.dart';
import '../features/spaces/hidden_passwords.dart';
import '../features/sync/sync_merge.dart';
import '../i18n/messages.dart';
import '../models/backup_service.dart';
import '../models/contact.dart';
import '../models/custom_field.dart';
import '../models/generated_password.dart';
import '../models/identity.dart';
import '../models/json.dart';
import '../models/key_account.dart';
import '../models/login.dart';
import '../models/otp_account.dart';
import '../models/passkey.dart';
import '../models/payment_card.dart';
import '../models/secure_note.dart';
import '../models/vault_entry.dart';
import '../models/vault_file.dart';
import '../models/vault_key.dart';
import '../models/website_rule.dart';
import '../platform/autofill.dart';
import '../platform/shared_items.dart';
import '../platform/unlock_keys.dart';
import '../security_key/oath/oath_name.dart';
import 'attachment_store.dart';
import 'vault_providers.dart';
import 'vault_registry.dart';
import 'vault_store.dart';

/// Where the app is: no vault yet, a locked vault, or an open one.
enum VaultPhase { setup, locked, unlocked }

/// The open vault's id, name and whether the lock screen lists it.
@immutable
class VaultInfo {
  const VaultInfo({required this.id, this.name, this.hidden = false});

  final String id;

  /// Null for the first vault until it's named.
  final String? name;

  /// Not offered on the lock screen.
  final bool hidden;

  @override
  bool operator ==(Object other) => other is VaultInfo && other.id == id && other.name == name && other.hidden == hidden;

  @override
  int get hashCode => Object.hash(id, name, hidden);
}

/// The vault and, while it's open, its keys and contents.
@immutable
class VaultState {
  const VaultState({
    required this.phase,
    this.session,
    this.accounts = const [],
    this.backupServices = const [],
    this.notes = const [],
    this.passkeys = const [],
    this.keys = const [],
    this.keyAccounts = const [],
    this.contacts = const [],
    this.logins = const [],
    this.cards = const [],
    this.identities = const [],
    this.files = const [],
    this.generated = const [],
    required this.vault,
    this.revision = 0,
    this.offerBiometric = false,
    this.replacingKey = false,
    this.keyExposed = false,
    this.offerKeyReplacement = false,
  });

  final VaultPhase phase;

  /// The open vault's keys; null unless [phase] is unlocked.
  final VaultSession? session;
  final List<OtpAccount> accounts;
  final List<BackupService> backupServices;
  final List<SecureNote> notes;
  final List<Passkey> passkeys;
  final List<VaultKey> keys;

  /// What the vault remembers of the accounts on security keys: names,
  /// never secrets or codes (openspec: add-security-key-codes).
  final List<KeyAccount> keyAccounts;

  /// Other people's public keys.
  final List<Contact> contacts;

  /// The vault's logins (openspec: add-passwords).
  final List<Login> logins;

  /// The vault's cards.
  final List<PaymentCard> cards;

  /// The vault's identities.
  final List<Identity> identities;

  /// The vault's File items, each holding one attached file.
  final List<VaultFile> files;

  /// The passwords AutoFill generated that no saved login holds, newest last.
  final List<GeneratedPassword> generated;
  final VaultInfo vault;

  /// Counts the user's changes since unlock; sync runs once they settle and
  /// drops a result that raced one.
  final int revision;

  /// Biometric unlock can be set up for the vault just opened, so the shell offers it.
  final bool offerBiometric;

  /// The open vault's key pair is being replaced: sync stops until it ends
  /// (openspec: replace-vault-key-pair, decision 6).
  final bool replacingKey;

  /// A copy of the open vault's private key is known to have been in the
  /// app's storage beside what opens it, so old phone backups hold it, until
  /// the key pair is replaced (openspec: replace-vault-key-pair, decision 8).
  final bool keyExposed;

  /// The vault just opened is exposed and was never offered a new key pair,
  /// so the shell offers it, once.
  final bool offerKeyReplacement;

  bool get isUnlocked => phase == VaultPhase.unlocked && session != null;

  Lists get lists => Lists(
    accounts: accounts,
    backupServices: backupServices,
    keys: keys,
    notes: notes,
    passkeys: passkeys,
    keyAccounts: keyAccounts,
    contacts: contacts,
    logins: logins,
    cards: cards,
    identities: identities,
    files: files,
  );

  VaultState copyWith({
    VaultPhase? phase,
    VaultSession? session,
    bool clearSession = false,
    List<OtpAccount>? accounts,
    List<BackupService>? backupServices,
    List<SecureNote>? notes,
    List<Passkey>? passkeys,
    List<VaultKey>? keys,
    List<KeyAccount>? keyAccounts,
    List<Contact>? contacts,
    List<Login>? logins,
    List<PaymentCard>? cards,
    List<Identity>? identities,
    List<VaultFile>? files,
    List<GeneratedPassword>? generated,
    VaultInfo? vault,
    int? revision,
    bool? offerBiometric,
    bool? replacingKey,
    bool? keyExposed,
    bool? offerKeyReplacement,
  }) => VaultState(
    phase: phase ?? this.phase,
    session: clearSession ? null : session ?? this.session,
    accounts: accounts ?? this.accounts,
    backupServices: backupServices ?? this.backupServices,
    notes: notes ?? this.notes,
    passkeys: passkeys ?? this.passkeys,
    keys: keys ?? this.keys,
    keyAccounts: keyAccounts ?? this.keyAccounts,
    contacts: contacts ?? this.contacts,
    logins: logins ?? this.logins,
    cards: cards ?? this.cards,
    identities: identities ?? this.identities,
    files: files ?? this.files,
    generated: generated ?? this.generated,
    vault: vault ?? this.vault,
    revision: revision ?? this.revision,
    offerBiometric: offerBiometric ?? this.offerBiometric,
    replacingKey: replacingKey ?? this.replacingKey,
    keyExposed: keyExposed ?? this.keyExposed,
    offerKeyReplacement: offerKeyReplacement ?? this.offerKeyReplacement,
  );
}

final vaultControllerProvider = NotifierProvider<VaultController, VaultState>(VaultController.new);

/// Two entries are the same account when issuer and secret match.
String _accountKey(OtpAccount a) => '${a.issuer}::${a.secret}';

String _displayName(OtpAccount a) => (a.name?.trim().isNotEmpty ?? false) ? a.name!.trim() : a.issuer.isNotEmpty ? a.issuer : a.label;

/// The vault's state machine and every change to its contents, as `App.tsx`
/// kept them: open, lock and switch vaults; add, edit, reorder and remove
/// accounts with an undo; backup services and their codes; imports; and
/// what sync merged. Each entry the user adds or edits is stamped, so sync
/// can tell which copy is newer. A failed save puts the lists back and says so.
class VaultController extends Notifier<VaultState> {
  @override
  VaultState build() {
    final store = ref.read(vaultStoreProvider);
    final setUp = store.isVaultSetup();
    // UserDefaults goes with an uninstall and the Keychain doesn't: a start with no vault leaves
    // no biometric unlock key from an earlier install behind
    if (!setUp && defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(ref.read(unlockKeysProvider).deleteAll().catchError((Object _) {}));
    }
    // Key reminders follow the keys: scheduled again whenever a vault opens and whenever its keys
    // change, by hand, by an import or by sync, since nothing can be read once it is locked
    // (openspec: add-key-expiry-warnings). Locking leaves them as they are.
    listenSelf((previous, next) {
      if (!next.isUnlocked) return;
      final same = previous != null && previous.isUnlocked && identical(previous.keys, next.keys) && previous.vault == next.vault;
      if (!same) unawaited(ref.read(keyRemindersProvider).sync(next.vault, next.keys));
    });
    return VaultState(phase: setUp ? VaultPhase.locked : VaultPhase.setup, vault: _describe());
  }

  VaultStore get _store => ref.read(vaultStoreProvider);
  VaultRegistry get _vaults => ref.read(vaultRegistryProvider);
  String _t(String id, [Map<String, Object?> args = const {}]) => ref.read(messagesProvider).t(id, args);
  int get _now => ref.read(clockProvider)().millisecondsSinceEpoch;

  void _toast(String id, [Map<String, Object?> args = const {}, ToastSeverity severity = ToastSeverity.success]) =>
      ref.read(toastsProvider.notifier).show(_t(id, args), severity: severity);

  VaultInfo _describe() {
    final vaults = ref.read(vaultRegistryProvider);
    final id = vaults.active;
    return VaultInfo(id: id, name: vaults.vaultName(id), hidden: !vaults.isListed(id));
  }

  List<OtpAccount> _touchAccounts(List<OtpAccount> next) => stampChanged(next, state.accounts, now: _now);
  List<BackupService> _touchServices(List<BackupService> next) => stampChanged(next, state.backupServices, now: _now);

  /// Opens the vault after setup or unlock: loads its accounts and services.
  /// When the lock screen had [failures], wrong passwords typed since its
  /// vault, or with [phoneSlot] any vault, last opened, says so once.
  Future<void> open(VaultSession session, {UnlockFailures failures = UnlockFailures.none, bool phoneSlot = false}) async {
    _vaults.rememberVault(_vaults.active);
    final vault = _describe();
    try {
      final accounts = await _store.loadAccounts(session);
      final services = await _store.loadBackupServices(session);
      final notes = await _store.loadNotes(session);
      final passkeys = await _store.loadPasskeys(session);
      final keys = await _store.loadKeys(session);
      final keyAccounts = await _store.loadKeyAccounts(session);
      final storedContacts = await _store.loadContacts(session);
      // A check made before checks kept their addresses covers those of the key as it is now, read
      // this once and written down; a save that fails is tried again the next time
      final contacts = [for (final contact in storedContacts) withCheckedAddresses(contact)];
      if (contacts.indexed.any((c) => !identical(c.$2, storedContacts[c.$1]))) {
        await _store.saveContacts(contacts, session).then<void>((_) {}, onError: (Object _) {});
      }
      final logins = await _store.loadLogins(session);
      final cards = await _store.loadCards(session);
      final identities = await _store.loadIdentities(session);
      final files = await _store.loadFiles(session);
      // Generated passwords are kept a month, and until a login holds them; the others go as the vault opens
      final stored = await _store
          .loadGenerated(session)
          .then<List<GeneratedPassword>>((list) => list, onError: (Object _) => const <GeneratedPassword>[]);
      final since = _now - const Duration(days: generatedPasswordDays).inMilliseconds;
      final held = {for (final login in logins) ?login.password};
      final generated = [
        for (final item in stored)
          if (item.at >= since && !held.contains(item.password)) item,
      ];
      if (generated.length != stored.length) unawaited(_store.saveGenerated(generated, session).catchError((Object _) {}));
      // What is known about its key pair; a value that won't open doesn't keep the vault shut
      final keyInfo = await _store.loadKeyInfo(session).then<KeyInfo?>((info) => info, onError: (Object _) => null);
      state = VaultState(
        phase: VaultPhase.unlocked,
        session: session,
        accounts: accounts,
        backupServices: services,
        notes: notes,
        passkeys: passkeys,
        keys: keys,
        keyAccounts: keyAccounts,
        contacts: contacts,
        logins: logins,
        cards: cards,
        identities: identities,
        files: files,
        generated: generated,
        vault: vault,
        keyExposed: keyInfo?.exposed ?? false,
        offerKeyReplacement: (keyInfo?.exposed ?? false) && !keyInfo!.asked,
      );
    } catch (_) {
      state = VaultState(phase: VaultPhase.locked, vault: vault);
      _toast('app.snack.unlockFailed', const {}, ToastSeverity.error);
      return;
    }
    unawaited(sweepAttachments());
    if (failures.count > 0) {
      final args = failuresArgs(failures, now: ref.read(clockProvider)(), locale: ref.read(localeProvider).locale.toLanguageTag());
      _toast(phoneSlot ? 'vault.failures.reportPhone' : 'vault.failures.report', args, ToastSeverity.info);
    }
    // Offer biometric setup when the phone has biometrics the hardware key can use (Class 3 on
    // Android) and none is set up yet. A hidden vault opens by password only, as the lock screen
    // offers quick unlock for listed ones only. Nor is it offered for a vault that needs a security
    // key, which it would open without the key (openspec: add-security-key-unlock, decision 11).
    if (!_store.hasBiometricUnlock() && !vault.hidden && !_store.unlockMode().needsKey) {
      final available = await ref.read(unlockKeysProvider).status();
      if (available && state.isUnlocked && state.session == session) state = state.copyWith(offerBiometric: true);
    }
  }

  /// The open vault's passkey inbox key, made when [create] and there is
  /// none yet; null without one, or with the vault locked.
  Future<P256KeyPair?> passkeyInbox({bool create = false}) async {
    final session = state.session;
    if (session == null) return null;
    final stored = await _store.loadPasskeyInboxKey(session);
    if (stored != null) return P256KeyPair.fromPkcs8(stored);
    if (!create) return null;
    final pair = newP256KeyPair();
    await _store.savePasskeyInboxKey(pair.toPkcs8(), session);
    return pair;
  }

  /// The inbox key a replacement of the vault's key pair left behind, under
  /// which passkeys made before it may still wait; null without one
  /// (openspec: replace-vault-key-pair, decision 7).
  Future<P256KeyPair?> previousPasskeyInbox() async {
    final session = state.session;
    if (session == null) return null;
    final stored = await _store.loadPreviousPasskeyInboxKey(session);
    return stored == null ? null : P256KeyPair.fromPkcs8(stored);
  }

  /// Forgets the inbox key a replacement left behind, once no passkey waits under it.
  Future<void> dropPreviousPasskeyInbox() async {
    final session = state.session;
    if (session != null) await _store.dropPreviousPasskeyInboxKey(session);
  }

  /// How long a stored file no note names is kept, so Undo and a note
  /// being written can still use it.
  static const unreferencedFileLife = Duration(days: 1);

  /// Deletes the open vault's stored files that no note names and that are
  /// older than [unreferencedFileLife]: removed attachments, deleted notes
  /// and files attached to a note that was never saved. Runs at unlock.
  Future<void> sweepAttachments() async {
    final session = state.session;
    if (session == null) return;
    final vaultId = state.vault.id;
    final named = {
      for (final note in state.notes)
        for (final file in note.files) file.id,
      for (final item in state.files) item.file.id,
    };
    final cutoff = ref.read(clockProvider)().subtract(unreferencedFileLife);
    final store = ref.read(attachmentStoreProvider);
    try {
      for (final file in await store.list(vaultId)) {
        // The vault may have locked or changed meanwhile
        if (state.session != session) return;
        if (!named.contains(file.id) && file.modified.isBefore(cutoff)) await store.delete(vaultId, file.id);
      }
    } catch (_) {
      // Left for the next unlock
    }
  }

  /// The biometric offer was answered.
  void biometricOffered() => state = state.copyWith(offerBiometric: false);

  /// The offer to replace the exposed vault's key pair was shown: it isn't
  /// shown again, though the health card's line stays until the key is replaced.
  Future<void> keyReplacementOffered() async {
    final session = state.session;
    state = state.copyWith(offerKeyReplacement: false);
    if (session != null) await _store.markKeyAsked(session).catchError((Object _) {});
  }

  /// Locks the vault and forgets its keys and contents.
  void lock() => state = VaultState(phase: VaultPhase.locked, vault: _describe());

  /// Every vault was wiped from the lock screen; setup comes next. Codes
  /// other apps could fill go too, every file attached to a note, every
  /// vault's biometric unlock key and every scheduled key reminder, so a
  /// reset leaves none behind; so does a shared item still waiting, with
  /// its file.
  void wiped() {
    unawaited(ref.read(pendingShareProvider.notifier).wipe());
    unawaited(ref.read(keyRemindersProvider).cancelAll());
    unawaited(ref.read(autofillPlatformProvider).removeAll().catchError((Object _) {}));
    unawaited(ref.read(unlockKeysProvider).deleteAll().catchError((Object _) {}));
    unawaited(ref.read(attachmentStoreProvider).deleteAll().catchError((Object _) {}));
    state = VaultState(phase: VaultPhase.setup, vault: _describe());
  }

  /// Locks, with the lock screen set to another listed vault.
  void switchVault(String id) {
    _vaults.rememberVault(id);
    _vaults.active = id;
    lock();
  }

  /// Deletes the open vault, its biometric unlock key and its scheduled key
  /// reminders; the lock screen or, if it was the last, setup comes next.
  void deleteVault() {
    final id = _vaults.active;
    unawaited(ref.read(keyRemindersProvider).cancelVault(id));
    unawaited(ref.read(autofillPlatformProvider).removeVault(id).catchError((Object _) {}));
    unawaited(ref.read(unlockKeysProvider).delete(id).catchError((Object _) {}));
    unawaited(ref.read(attachmentStoreProvider).deleteVault(id).catchError((Object _) {}));
    _vaults.removeVaultData(id);
    state = VaultState(phase: _store.isVaultSetup() ? VaultPhase.locked : VaultPhase.setup, vault: _describe());
  }

  /// Re-reads the open vault's name and visibility after Settings changed them.
  void vaultChanged() => state = state.copyWith(vault: _describe());

  /// Gives the open vault a new key pair under [password], with a new
  /// [kit] or none ([dropKit]) when it has one (openspec:
  /// replace-vault-key-pair). Sync stops while it runs, and the store holds
  /// every other load and save until it ends, so an edit made meanwhile is
  /// saved afterwards with the new key. Throws what
  /// [VaultStore.replaceKeyPair] throws; after [KeyReplacementIncomplete]
  /// the vault goes on with the new key pair all the same.
  ///
  /// A vault that needs a security key takes [proof], what
  /// [VaultStore.proveOwner] gave for its password and key, in place of
  /// the password alone (openspec: add-security-key-unlock, decision 10).
  Future<VaultSession> replaceKey(String password, {RecoveryKey? kit, bool dropKit = false, OwnerProof? proof}) async {
    final session = state.session;
    if (session == null) throw const VaultMissingError('The vault is locked.');
    state = state.copyWith(replacingKey: true);
    try {
      final next = await _store.replaceKeyPair(session, password, kit: kit, dropKit: dropKit, proof: proof);
      await keyReplaced(next);
      return next;
    } on KeyReplacementIncomplete catch (error) {
      await keyReplaced(error.session);
      rethrow;
    } finally {
      if (state.replacingKey) state = state.copyWith(replacingKey: false);
    }
  }

  /// The open vault's key pair was replaced: it goes on with [session], and
  /// offers biometric unlock again, which the replacement turned off.
  Future<void> keyReplaced(VaultSession session) async {
    if (!state.isUnlocked) return;
    final offer = !state.vault.hidden && !_store.unlockMode().needsKey && await ref.read(unlockKeysProvider).status();
    if (!state.isUnlocked) return;
    state = state.copyWith(session: session, replacingKey: false, offerBiometric: offer, keyExposed: false, offerKeyReplacement: false);
  }

  void passwordChanged(VaultSession session) {
    state = state.copyWith(session: session);
    _toast('app.snack.passwordChanged');
  }

  void _bump() => state = state.copyWith(revision: state.revision + 1);

  /// Adds an account, unless one with the same issuer and secret is saved already.
  Future<void> addAccount(OtpAccount data) async {
    final session = state.session;
    if (session == null) return;
    if (state.accounts.any((a) => _accountKey(a) == _accountKey(data))) {
      _toast('app.snack.accountExists', const {}, ToastSeverity.error);
      return;
    }
    final account = data.copyWith(id: newUuid(), addedAt: _now);
    final next = _touchAccounts([...state.accounts, account]);
    try {
      await _store.saveAccounts(next, session);
      state = state.copyWith(accounts: next);
      _bump();
      _toast('app.snack.accountAdded', {'name': _displayName(data)});
    } catch (_) {
      _toast('app.snack.accountAddFailed', const {}, ToastSeverity.error);
    }
  }

  /// Adds several accounts at once (a Google Authenticator QR), skipping ones already saved.
  Future<void> addAccounts(List<OtpAccount> list) async {
    final session = state.session;
    if (session == null) return;
    final seen = {for (final a in state.accounts) _accountKey(a)};
    final now = _now;
    final fresh = <OtpAccount>[
      for (final data in list)
        if (seen.add(_accountKey(data))) data.copyWith(id: newUuid(), addedAt: now),
    ];
    final next = _touchAccounts([...state.accounts, ...fresh]);
    try {
      if (fresh.isNotEmpty) await _store.saveAccounts(next, session);
      state = state.copyWith(accounts: next);
      if (fresh.isNotEmpty) _bump();
      _toast('app.snack.accountsAdded', {
        'count': fresh.length,
        'dupCount': list.length - fresh.length,
      }, fresh.isNotEmpty ? ToastSeverity.success : ToastSeverity.info);
    } catch (_) {
      _toast('app.snack.accountAddFailed', const {}, ToastSeverity.error);
    }
  }

  /// Saves an edited account; on failure the list goes back as it was.
  Future<void> updateAccount(OtpAccount updated) async {
    final session = state.session;
    if (session == null) return;
    final previous = state.accounts;
    final next = _touchAccounts([for (final a in previous) a.id == updated.id ? updated : a]);
    state = state.copyWith(accounts: next);
    try {
      await _store.saveAccounts(next, session);
      _bump();
    } catch (_) {
      state = state.copyWith(accounts: previous);
      _toast('app.snack.accountUpdateFailed', const {}, ToastSeverity.error);
    }
  }

  /// Saves a custom order: the given ids take positions 0, 1, 2… and the rest keep theirs.
  Future<void> reorderAccounts(List<String> orderedIds) async {
    final session = state.session;
    if (session == null) return;
    final position = {for (final (i, id) in orderedIds.indexed) id: i};
    final previous = state.accounts;
    final next = _touchAccounts([for (final a in previous) position.containsKey(a.id) ? a.copyWith(order: position[a.id]) : a]);
    state = state.copyWith(accounts: next);
    try {
      await _store.saveAccounts(next, session);
      _bump();
    } catch (_) {
      state = state.copyWith(accounts: previous);
      _toast('app.snack.accountUpdateFailed', const {}, ToastSeverity.error);
    }
  }

  /// Removes an account, with Undo in the toast for a few seconds. The items linked to it stop naming it.
  Future<void> deleteAccount(OtpAccount removed) async {
    final session = state.session;
    if (session == null) return;
    final index = state.accounts.indexWhere((a) => a.id == removed.id);
    _DroppedLinks? dropped;
    try {
      dropped = await _dropLinksTo(session, [removed]);
      final next = [...state.accounts.where((a) => a.id != removed.id)];
      await _store.saveAccounts(next, session);
      state = state.copyWith(accounts: next);
      _bump();
      ref
          .read(toastsProvider.notifier)
          .show(
            _t('app.snack.accountRemoved', {'name': _displayName(removed)}),
            actionLabel: _t('app.undo'),
            onAction: () => unawaited(_restoreAccount(removed, index, session, relinked: dropped?.ids ?? const [])),
          );
    } catch (_) {
      await dropped?.undo().then<void>((_) {}, onError: (Object _) {});
      _toast('app.snack.accountRemoveFailed', const {}, ToastSeverity.error);
    }
  }

  /// Puts a just-removed account back where it was, in the vault it was
  /// removed [from] and no other: the toast outlives a lock, and Undo tapped
  /// after another vault was opened would save the account into that one.
  /// The items [relinked] that named it name it again.
  Future<void> _restoreAccount(OtpAccount account, int index, VaultSession from, {List<String> relinked = const []}) async {
    final session = state.session;
    if (session == null || !identical(session, from) || state.accounts.any((a) => a.id == account.id)) return;
    final next = [...state.accounts]..insert(index < 0 ? state.accounts.length : index.clamp(0, state.accounts.length), account);
    // Stamped as just changed, so it outlives the deletion sync may already have shared
    final restored = _touchAccounts(next);
    try {
      await _store.saveAccounts(restored, session);
      state = state.copyWith(accounts: restored);
      _bump();
      await _relinkRestored(account, relinked);
    } catch (_) {
      _toast('app.snack.accountAddFailed', const {}, ToastSeverity.error);
    }
  }

  /// Takes what an import brought: the merged lists the import dialog
  /// built, and the [passkeys], [keys], [notes], [keyAccounts] and [contacts]
  /// to add, of which the ones already held are skipped, but for a PGP key
  /// the vault holds another copy of: the two are combined into the held
  /// entry (openspec: add-pgp-key-editing, design decision 9). An import
  /// only adds, and so does a combination. The notes' files are stored
  /// already.
  Future<void> imported(
    List<OtpAccount> accounts,
    List<BackupService> services, {
    List<Passkey> passkeys = const [],
    List<VaultKey> keys = const [],
    List<SecureNote> notes = const [],
    List<KeyAccount> keyAccounts = const [],
    List<Contact> contacts = const [],
    List<Login> logins = const [],
    List<PaymentCard> cards = const [],
    List<Identity> identities = const [],
    List<VaultFile> files = const [],
  }) async {
    final session = state.session;
    if (session == null) return;
    try {
      final nextAccounts = _touchAccounts(accounts);
      final nextServices = _touchServices(services);
      await _store.saveAccounts(nextAccounts, session);
      state = state.copyWith(accounts: nextAccounts);
      await _store.saveBackupServices(nextServices, session);
      state = state.copyWith(backupServices: nextServices);
      if (passkeys.isNotEmpty && await addPasskeys(passkeys) == null) throw StateError('The passkeys were not saved');
      await _importKeys(keys, session);
      final heldNotes = {for (final note in state.notes) note.id};
      await _addAll(_notes, [
        for (final note in notes)
          if (heldNotes.add(note.id)) note,
      ], session);
      if (await addKeyAccounts(keyAccounts) == null) throw StateError('The accounts on a key were not saved');
      // The caller left out the contacts whose key the vault holds; one whose id is taken gets another
      final heldContacts = {for (final contact in state.contacts) contact.id};
      await _addAll(_contacts, [
        for (final contact in contacts) heldContacts.add(contact.id) ? contact : contact.copyWith(id: newUuid()),
      ], session);
      final heldLogins = {for (final login in state.logins) login.id};
      await _addAll(_logins, [
        for (final login in logins)
          if (heldLogins.add(login.id)) login,
      ], session);
      final heldCards = {for (final card in state.cards) card.id};
      await _addAll(_cards, [
        for (final card in cards)
          if (heldCards.add(card.id)) card,
      ], session);
      final heldIdentities = {for (final identity in state.identities) identity.id};
      await _addAll(_identities, [
        for (final identity in identities)
          if (heldIdentities.add(identity.id)) identity,
      ], session);
      final heldFiles = {for (final item in state.files) item.id};
      await _addAll(_files, [
        for (final item in files)
          if (heldFiles.add(item.id)) item,
      ], session);
      _bump();
      _toast('app.snack.importSuccess', {'count': accounts.length});
    } catch (_) {
      _toast('app.snack.importFailed', const {}, ToastSeverity.error);
    }
  }

  /// Adds a service with its codes, all unused, and the custom [fields] it was given.
  Future<void> addBackupService(
    String serviceName,
    List<String> codes, {
    String? name,
    List<WebsiteRule> websites = const [],
    List<CustomField> fields = const [],
  }) async {
    final session = state.session;
    if (session == null) return;
    final made = websitesOf(websites);
    final service = BackupService(
      id: newUuid(),
      serviceName: serviceName,
      codes: [for (final code in codes) BackupCode(code: code)],
      fields: fields,
      addedAt: _now,
    ).copyWith(name: name == null || name.isEmpty ? unset : name, websites: made.websites ?? unset, uris: made.uris ?? unset);
    final next = _touchServices([...state.backupServices, service]);
    try {
      await _store.saveBackupServices(next, session);
      state = state.copyWith(backupServices: next);
      _bump();
      _toast('app.snack.backupSaved', {'name': serviceName});
    } catch (_) {
      _toast('app.snack.backupSaveFailed', const {}, ToastSeverity.error);
    }
  }

  /// Saves an edited service; on failure the list goes back as it was.
  Future<void> updateBackupService(BackupService updated) async {
    final session = state.session;
    if (session == null) return;
    final previous = state.backupServices;
    final next = _touchServices([for (final s in previous) s.id == updated.id ? updated : s]);
    state = state.copyWith(backupServices: next);
    try {
      await _store.saveBackupServices(next, session);
      _bump();
    } catch (_) {
      state = state.copyWith(backupServices: previous);
      _toast('app.snack.backupUpdateFailed', const {}, ToastSeverity.error);
    }
  }

  /// Marks one backup code used or unused, against the latest saved list.
  Future<void> setBackupCodeUsed(String serviceId, int index, bool used) async {
    final service = state.backupServices.where((s) => s.id == serviceId).firstOrNull;
    if (service == null) return;
    final now = ref.read(clockProvider)();
    await updateBackupService(
      service.copyWith(
        codes: [for (final (i, code) in service.codes.indexed) i == index ? markCode(code, used: used, now: now) : code],
      ),
    );
  }

  /// Removes a backup-codes entry; the items linked to it stop naming it.
  Future<void> deleteBackupService(String id) async {
    final session = state.session;
    if (session == null) return;
    final removed = state.backupServices.firstWhereOrNull((s) => s.id == id);
    _DroppedLinks? dropped;
    try {
      if (removed != null) dropped = await _dropLinksTo(session, [removed]);
      final next = [...state.backupServices.where((s) => s.id != id)];
      await _store.saveBackupServices(next, session);
      state = state.copyWith(backupServices: next);
      _bump();
      _toast('app.snack.backupDeleted');
    } catch (_) {
      await dropped?.undo().then<void>((_) {}, onError: (Object _) {});
      _toast('app.snack.backupDeleteFailed', const {}, ToastSeverity.error);
    }
  }

  /// Marks the breach Have I Been Pwned calls [name] dealt with for the accounts and
  /// backup-code lists with these ids, in one go, with Undo in the toast for a few
  /// seconds (openspec: breach-alerts). It is kept on each entry, so sync and exports
  /// carry it. A failed save puts the lists back.
  Future<void> dismissBreach(String name, {Iterable<String> accountIds = const [], Iterable<String> serviceIds = const []}) async {
    final accounts = {
      for (final a in state.accounts)
        if (accountIds.contains(a.id) && !(a.breachesDismissed?.contains(name) ?? false)) a.id,
    };
    final services = {
      for (final s in state.backupServices)
        if (serviceIds.contains(s.id) && !(s.breachesDismissed?.contains(name) ?? false)) s.id,
    };
    if (accounts.isEmpty && services.isEmpty) return;
    final saved = await _saveBreachMarks(
      accounts: [
        for (final a in state.accounts) accounts.contains(a.id) ? a.copyWith(breachesDismissed: [...?a.breachesDismissed, name]) : a,
      ],
      services: [
        for (final s in state.backupServices) services.contains(s.id) ? s.copyWith(breachesDismissed: [...?s.breachesDismissed, name]) : s,
      ],
    );
    if (!saved) return;
    ref
        .read(toastsProvider.notifier)
        .show(
          _t('breaches.snack.dealtWith'),
          actionLabel: _t('app.undo'),
          onAction: () => unawaited(_restoreBreach(name, accounts, services)),
        );
  }

  /// Makes a breach just marked dealt with new again for the same entries.
  Future<void> _restoreBreach(String name, Set<String> accounts, Set<String> services) async {
    List<String>? without(List<String>? names) {
      final rest = [...?names?.where((other) => other != name)];
      return rest.isEmpty ? null : rest;
    }

    await _saveBreachMarks(
      accounts: [
        for (final a in state.accounts) accounts.contains(a.id) ? a.copyWith(breachesDismissed: without(a.breachesDismissed) ?? unset) : a,
      ],
      services: [
        for (final s in state.backupServices)
          services.contains(s.id) ? s.copyWith(breachesDismissed: without(s.breachesDismissed) ?? unset) : s,
      ],
    );
  }

  /// Saves both lists after a breach was marked or unmarked, stamping the entries that
  /// changed. False, with the lists as they were, when a save failed.
  Future<bool> _saveBreachMarks({required List<OtpAccount> accounts, required List<BackupService> services}) async {
    final session = state.session;
    if (session == null) return false;
    final previousAccounts = state.accounts;
    final previousServices = state.backupServices;
    final nextAccounts = _touchAccounts(accounts);
    final nextServices = _touchServices(services);
    state = state.copyWith(accounts: nextAccounts, backupServices: nextServices);
    var accountsSaved = false;
    try {
      await _store.saveAccounts(nextAccounts, session);
      accountsSaved = true;
      await _store.saveBackupServices(nextServices, session);
      _bump();
      return true;
    } catch (_) {
      state = state.copyWith(accounts: previousAccounts, backupServices: previousServices);
      // The accounts went in before the backup codes failed: put them back as they were
      if (accountsSaved) await _store.saveAccounts(previousAccounts, session).catchError((Object _) {});
      _toast('breaches.snack.failed', const {}, ToastSeverity.error);
      return false;
    }
  }

  // ─── Vault items ───────────────────────────────────────────────────────────

  late final _notes = _ItemList<SecureNote>(
    read: (state) => state.notes,
    write: (state, notes) => state.copyWith(notes: notes),
    save: (notes, session) => _store.saveNotes(notes, session),
    name: (note) => note.title,
    messages: const _ItemMessages(
      added: 'vault.snack.noteAdded',
      addFailed: 'vault.snack.noteAddFailed',
      updateFailed: 'vault.snack.noteUpdateFailed',
      removed: 'vault.snack.noteRemoved',
      removeFailed: 'vault.snack.noteRemoveFailed',
    ),
  );

  /// Adds a new note, as of now; true once it is saved.
  Future<bool> addNote(SecureNote note) => _addItem(_notes, note.copyWith(addedAt: _now, updatedAt: unset));

  /// Saves an edited note; on failure the list goes back as it was, and false.
  Future<bool> updateNote(SecureNote note) => _updateItem(_notes, note);

  /// Removes a note, with Undo in the toast for a few seconds.
  Future<void> deleteNote(SecureNote note) => _deleteItem(_notes, note);

  late final _logins = _ItemList<Login>(
    read: (state) => state.logins,
    write: (state, logins) => state.copyWith(logins: logins),
    save: (logins, session) => _store.saveLogins(logins, session),
    name: (login) => login.name,
    messages: const _ItemMessages(
      added: 'vault.snack.loginAdded',
      addFailed: 'vault.snack.loginAddFailed',
      updateFailed: 'vault.snack.loginUpdateFailed',
      removed: 'vault.snack.loginRemoved',
      removeFailed: 'vault.snack.loginRemoveFailed',
    ),
  );

  /// Adds a new login, as of now, its password changed now too; true once it is saved.
  Future<bool> addLogin(Login login) => _addItem(
    _logins,
    login.copyWith(addedAt: _now, updatedAt: unset, passwordChangedAt: (login.password?.isNotEmpty ?? false) ? _now : unset),
  );

  /// Saves an edited login. A changed password keeps the one it replaces
  /// among the previous passwords; on failure the list goes back as it was,
  /// and false.
  Future<bool> updateLogin(Login edited) {
    final current = state.logins.firstWhereOrNull((login) => login.id == edited.id);
    final next = current == null || current.password == edited.password
        ? edited
        : edited.copyWith(password: current.password ?? unset).withPassword(edited.password, _now);
    return _updateItem(_logins, next);
  }

  /// Deletes one of a login's previous passwords for good.
  Future<bool> deletePreviousPassword(Login login, PreviousPassword previous) {
    final rest = [...?login.previousPasswords]..remove(previous);
    return _updateItem(_logins, login.copyWith(previousPasswords: rest.isEmpty ? unset : rest));
  }

  /// Removes a login, with Undo in the toast for a few seconds. Its account stays.
  Future<void> deleteLogin(Login login) => _deleteItem(_logins, login);

  late final _cards = _ItemList<PaymentCard>(
    read: (state) => state.cards,
    write: (state, cards) => state.copyWith(cards: cards),
    save: (cards, session) => _store.saveCards(cards, session),
    name: (card) => card.name,
    messages: const _ItemMessages(
      added: 'vault.snack.cardAdded',
      addFailed: 'vault.snack.cardAddFailed',
      updateFailed: 'vault.snack.cardUpdateFailed',
      removed: 'vault.snack.cardRemoved',
      removeFailed: 'vault.snack.cardRemoveFailed',
    ),
  );

  /// Adds a new card, as of now; true once it is saved.
  Future<bool> addCard(PaymentCard card) => _addItem(_cards, card.copyWith(addedAt: _now, updatedAt: unset));

  /// Saves an edited card; on failure the list goes back as it was, and false.
  Future<bool> updateCard(PaymentCard card) => _updateItem(_cards, card);

  /// Removes a card, with Undo in the toast for a few seconds.
  Future<void> deleteCard(PaymentCard card) => _deleteItem(_cards, card);

  late final _identities = _ItemList<Identity>(
    read: (state) => state.identities,
    write: (state, identities) => state.copyWith(identities: identities),
    save: (identities, session) => _store.saveIdentities(identities, session),
    name: (identity) => identity.name,
    messages: const _ItemMessages(
      added: 'vault.snack.identityAdded',
      addFailed: 'vault.snack.identityAddFailed',
      updateFailed: 'vault.snack.identityUpdateFailed',
      removed: 'vault.snack.identityRemoved',
      removeFailed: 'vault.snack.identityRemoveFailed',
    ),
  );

  /// Adds a new identity, as of now; true once it is saved.
  Future<bool> addIdentity(Identity identity) => _addItem(_identities, identity.copyWith(addedAt: _now, updatedAt: unset));

  /// Saves an edited identity; on failure the list goes back as it was, and false.
  Future<bool> updateIdentity(Identity identity) => _updateItem(_identities, identity);

  /// Removes an identity, with Undo in the toast for a few seconds.
  Future<void> deleteIdentity(Identity identity) => _deleteItem(_identities, identity);

  late final _files = _ItemList<VaultFile>(
    read: (state) => state.files,
    write: (state, files) => state.copyWith(files: files),
    save: (files, session) => _store.saveFiles(files, session),
    name: (file) => file.name,
    messages: const _ItemMessages(
      added: 'files.snack.added',
      addFailed: 'files.snack.addFailed',
      updateFailed: 'files.snack.updateFailed',
      removed: 'files.snack.removed',
      removeFailed: 'files.snack.removeFailed',
    ),
  );

  /// Adds a File item, whose `addedAt` the caller set from the clock and whose sealed file is stored already; true once it is saved.
  Future<bool> addFile(VaultFile file) => _addItem(_files, file);

  /// Saves an edited File item; on failure the list goes back as it was, and false.
  Future<bool> updateFile(VaultFile file) => _updateItem(_files, file);

  /// Removes a File item, with Undo in the toast for a few seconds. Its stored file stays until the sweep at unlock finds that no
  /// item names it, as the file of a removed note attachment does, so Undo still has it.
  Future<void> deleteFile(VaultFile file) => _deleteItem(_files, file);

  /// Takes in what AutoFill saved while the vault was locked (openspec:
  /// add-passwords, design decision 9), oldest first. A saved login updates
  /// the login of the same id, or else of the same site and username: a
  /// different password goes in, the old one kept among the previous
  /// passwords; the same password changes nothing. One that matches no
  /// login, or a login deleted since, is added. A generated password is
  /// kept unless a login holds it. One save for all, no toast; the counts of
  /// logins added and updated, or null when a save failed and nothing changed.
  /// Taking the same records again changes nothing.
  Future<({int added, int updated})?> takeLoginRecords(List<LoginInboxRecord> records, {PublicSuffixList? suffixes}) async {
    final session = state.session;
    if (session == null) return null;
    final previous = state.logins;
    final logins = [...previous];
    final generated = [...state.generated];
    var added = 0;
    var updated = 0;
    String? folded(String? username) => username?.trim().toLowerCase();
    bool sameSite(Login login, String site) => loginDomains(login, suffixes: suffixes).any((domain) => hostMatches(site, domain));
    for (final record in [...records]..sort((a, b) => a.at.compareTo(b.at))) {
      if (record.isGenerated) {
        if (!generated.any((g) => g.password == record.password) && !logins.any((l) => l.password == record.password)) {
          generated.add(GeneratedPassword(password: record.password, site: record.site, at: record.at));
        }
        continue;
      }
      var match = logins.indexWhere((login) => login.id == record.id);
      if (match < 0 && record.site != null) {
        match = logins.indexWhere((login) => sameSite(login, record.site!) && folded(login.username) == folded(record.username));
      }
      if (match < 0) {
        logins.add(record.toLogin());
        added++;
      } else if (logins[match].password != record.password) {
        logins[match] = logins[match].withPassword(record.password, record.at);
        updated++;
      }
      generated.removeWhere((g) => g.password == record.password);
    }
    final generatedChanged = generated.length != state.generated.length || !generated.every(state.generated.contains);
    if (added == 0 && updated == 0 && !generatedChanged) return (added: 0, updated: 0);
    final next = stampChanged(logins, previous, now: _now);
    try {
      if (added > 0 || updated > 0) await _store.saveLogins(next, session);
      if (generatedChanged) await _store.saveGenerated(generated, session);
    } catch (_) {
      return null;
    }
    state = state.copyWith(logins: next, generated: generated);
    if (added > 0 || updated > 0) _bump();
    return (added: added, updated: updated);
  }

  /// Forgets a generated password; true once saved.
  Future<bool> deleteGenerated(GeneratedPassword item) async {
    final session = state.session;
    if (session == null) return false;
    final next = [...state.generated]..remove(item);
    try {
      await _store.saveGenerated(next, session);
    } catch (_) {
      return false;
    }
    state = state.copyWith(generated: next);
    return true;
  }

  late final _keys = _ItemList<VaultKey>(
    read: (state) => state.keys,
    write: (state, keys) => state.copyWith(keys: keys),
    save: (keys, session) => _store.saveKeys(keys, session),
    name: (key) => key.name,
    messages: const _ItemMessages(
      added: 'vault.snack.keyAdded',
      addFailed: 'vault.snack.keyAddFailed',
      updateFailed: 'vault.snack.keyUpdateFailed',
      removed: 'vault.snack.keyRemoved',
      removeFailed: 'vault.snack.keyRemoveFailed',
    ),
  );

  /// The key in the vault that is [key], by [keyIdentity]: a PGP key by its
  /// primary fingerprint, whatever else differs; any other by its key pair.
  VaultKey? heldKey(VaultKey key) {
    final identity = keyIdentity(key);
    return state.keys.where((other) => keyIdentity(other) == identity).firstOrNull;
  }

  /// Adds a key pair, unless the vault holds it already; true once it is saved.
  Future<bool> addKey(VaultKey key) async {
    if (heldKey(key) case final held?) {
      _toast('vault.snack.keyExists', {'name': held.name}, ToastSeverity.error);
      return false;
    }
    return _addItem(_keys, key.copyWith(addedAt: _now, updatedAt: unset));
  }

  /// Saves a key's new name, note or tags; on failure the list goes back as it was, and false.
  Future<bool> updateKey(VaultKey key) => _updateItem(_keys, key);

  /// Saves the PGP key [key] with the new halves [private] and [public] of a
  /// change to it or of a merge with another copy (openspec:
  /// add-pgp-key-editing), under its id, with a new `updatedAt`, once they
  /// are checked against the key as the vault holds it now: they read, have
  /// its primary fingerprint, and hold every packet it held. True once
  /// saved; false, the vault as it was, when a check fails, the key is gone
  /// or the save failed.
  Future<bool> replaceKeyHalves(VaultKey key, Uint8List private, Uint8List public) async {
    final held = state.keys.where((other) => other.id == key.id).firstOrNull;
    final grown = held == null ? null : grownPgpKey(held, private, public);
    if (grown == null) {
      _toast(_keys.messages.updateFailed, const {}, ToastSeverity.error);
      return false;
    }
    return _updateItem(_keys, grown);
  }

  /// Removes a key, with Undo in the toast for a few seconds.
  Future<void> deleteKey(VaultKey key) => _deleteItem(_keys, key);

  late final _contacts = _ItemList<Contact>(
    read: (state) => state.contacts,
    write: (state, contacts) => state.copyWith(contacts: contacts),
    save: (contacts, session) => _store.saveContacts(contacts, session),
    name: (contact) => contact.name,
    messages: const _ItemMessages(
      added: 'vault.snack.contactAdded',
      addFailed: 'vault.snack.contactAddFailed',
      updateFailed: 'vault.snack.contactUpdateFailed',
      removed: 'vault.snack.contactRemoved',
      removeFailed: 'vault.snack.contactRemoveFailed',
    ),
  );

  /// Adds someone's public key, as of now; true once it is saved. The
  /// caller has read and checked the key, and made sure the vault holds
  /// neither it nor a key pair of the same fingerprint.
  Future<bool> addContact(Contact contact) => _addItem(_contacts, contact.copyWith(addedAt: _now, updatedAt: unset));

  /// Saves a changed contact: its name, its note, its check or its key. On
  /// failure the list goes back as it was, and false.
  Future<bool> updateContact(Contact contact) => _updateItem(_contacts, contact);

  /// Removes a contact, with Undo in the toast for a few seconds.
  Future<void> deleteContact(Contact contact) => _deleteItem(_contacts, contact);

  late final _passkeys = _ItemList<Passkey>(
    read: (state) => state.passkeys,
    write: (state, passkeys) => state.copyWith(passkeys: passkeys),
    save: (passkeys, session) => _store.savePasskeys(passkeys, session),
    name: (passkey) => passkey.displayName,
    messages: const _ItemMessages(
      added: 'vault.snack.passkeyAdded',
      addFailed: 'vault.snack.passkeyAddFailed',
      updateFailed: 'vault.snack.passkeyUpdateFailed',
      removed: 'vault.snack.passkeyRemoved',
      removeFailed: 'vault.snack.passkeyRemoveFailed',
    ),
  );

  /// Adds a passkey, unless one with its credential id is in the vault
  /// already; true once it is saved.
  Future<bool> addPasskey(Passkey passkey) async {
    if (state.passkeys.any((other) => other.credentialId == passkey.credentialId)) {
      _toast('vault.snack.passkeyExists', {'name': passkey.displayName}, ToastSeverity.error);
      return false;
    }
    return _addItem(_passkeys, passkey.copyWith(addedAt: passkey.addedAt == 0 ? _now : passkey.addedAt, updatedAt: unset));
  }

  /// Adds the passkeys of [list] the vault doesn't hold yet, by credential
  /// id, in one save, without a toast. Returns how many it added, or null
  /// when the save failed and nothing changed.
  Future<int?> addPasskeys(List<Passkey> list) async {
    final session = state.session;
    if (session == null) return null;
    final held = {for (final passkey in state.passkeys) passkey.credentialId};
    final fresh = [
      for (final passkey in list)
        if (held.add(passkey.credentialId)) passkey.copyWith(addedAt: passkey.addedAt == 0 ? _now : passkey.addedAt, updatedAt: unset),
    ];
    if (fresh.isEmpty) return 0;
    final next = stampChanged([...state.passkeys, ...fresh], state.passkeys, now: _now);
    try {
      await _store.savePasskeys(next, session);
    } catch (_) {
      return null;
    }
    state = state.copyWith(passkeys: next);
    _bump();
    return fresh.length;
  }

  /// Saves an edited passkey; on failure the list goes back as it was, and false.
  Future<bool> updatePasskey(Passkey passkey) => _updateItem(_passkeys, passkey);

  /// Removes a passkey, with Undo in the toast for a few seconds.
  Future<void> deletePasskey(Passkey passkey) => _deleteItem(_passkeys, passkey);

  /// The keys of an import into the list in one save: each the vault does
  /// not hold is added, and each PGP key it holds is combined with the
  /// imported copy (see [imported]); throws when the save fails, leaving
  /// the list as it was.
  Future<void> _importKeys(List<VaultKey> keys, VaultSession session) async {
    if (keys.isEmpty) return;
    final list = state.keys;
    final next = [...list];
    final at = {for (final (i, key) in list.indexed) keyIdentity(key): i};
    var changed = false;
    for (final key in keys) {
      final identity = keyIdentity(key);
      final held = at[identity];
      if (held == null) {
        at[identity] = next.length;
        next.add(key);
        changed = true;
      } else if (await combinedPgpKey(next[held], key) case final combined?) {
        next[held] = combined;
        changed = true;
      }
    }
    if (!changed) return;
    final stamped = stampChanged(next, list, now: _now);
    await _keys.save(stamped, session);
    state = _keys.write(state, stamped);
  }

  // ─── Accounts on a security key ────────────────────────────────────────────

  /// Saves [next] as what the vault remembers of the accounts on keys,
  /// stamping what changed. False, with the list as it was, when the save
  /// failed; true without saving when nothing changed.
  Future<bool> saveKeyAccounts(List<KeyAccount> next) async {
    final session = state.session;
    if (session == null) return false;
    var previous = state.keyAccounts;
    var stamped = stampChanged(next, previous, now: _now);
    if (canonical([for (final a in stamped) a.toJson()]) == canonical([for (final a in previous) a.toJson()])) return true;
    // The accounts that go are no longer named by the items linked to them
    final keptIds = {for (final account in next) account.id};
    final removed = [
      for (final account in previous)
        if (!keptIds.contains(account.id)) account,
    ];
    _DroppedLinks? dropped;
    try {
      if (removed.isNotEmpty) {
        dropped = await _dropLinksTo(session, removed);
        if (dropped != null) {
          // Another account of these may have been among the items that named them
          final held = {for (final account in state.keyAccounts) account.id: account};
          previous = state.keyAccounts;
          final rebased = [
            for (final account in next)
              if (held[account.id]?.links case final links? when !const ListEquality<ItemLink>().equals(links, account.links))
                account.withLinks(links)
              else
                account,
          ];
          stamped = stampChanged(rebased, previous, now: _now);
        }
      }
      await _store.saveKeyAccounts(stamped, session);
    } catch (_) {
      await dropped?.undo().then<void>((_) {}, onError: (Object _) {});
      return false;
    }
    state = state.copyWith(keyAccounts: stamped);
    _bump();
    return true;
  }

  /// Makes what the vault remembers of the key [device] equal to what the
  /// key [listed] (decision 4): a name not yet remembered becomes a new
  /// entry, a remembered name the key no longer lists is deleted, and a
  /// name on both keeps its id, tags and note. Names Yubico's apps hide
  /// are skipped, and other keys' entries are left alone. [keyName] is the
  /// key's name as it gave it at this read, if it gave one. Nothing is
  /// written when nothing changed. False when the save failed.
  Future<bool> reconcileKey(String device, String? keyName, List<KeyAccountSeen> listed) async {
    final held = {
      for (final account in state.keyAccounts)
        if (account.device == device) account.name: account,
    };
    final name = keyName ?? held.values.map((account) => account.keyName).nonNulls.firstOrNull;
    final now = _now;
    final seenNames = <String>{};
    final theirs = <KeyAccount>[];
    for (final seen in listed) {
      if (isHiddenOathName(seen.name) || !seenNames.add(seen.name)) continue;
      final parts = parseOathName(seen.name, timeBased: seen.type == KeyAccountType.totp);
      final before = held[seen.name];
      theirs.add(
        KeyAccount(
          id: before?.id ?? newUuid(),
          device: device,
          keyName: name,
          name: seen.name,
          issuer: parts.issuer,
          label: parts.label,
          period: parts.period,
          type: seen.type,
          algorithm: seen.algorithm,
          touch: seen.touch ?? before?.touch ?? false,
          tags: seen.tags ?? before?.tags,
          note: seen.note ?? before?.note,
          addedAt: before?.addedAt ?? now,
          updatedAt: before?.updatedAt,
          links: before?.links ?? const [],
          fields: seen.fields ?? before?.fields ?? const [],
          extra: before?.extra ?? const {},
        ),
      );
    }
    // The key's entries keep their place in the list; new ones go last.
    final byId = {for (final account in theirs) account.id: account};
    final next = [
      for (final account in state.keyAccounts)
        if (account.device != device) account else ?byId.remove(account.id),
      ...byId.values,
    ];
    return saveKeyAccounts(next);
  }

  /// Saves the tags and note of an on-key account; nothing is sent to the
  /// key. False, with a toast, when the save failed.
  Future<bool> updateKeyAccount(KeyAccount updated) async {
    final saved = await saveKeyAccounts([for (final account in state.keyAccounts) account.id == updated.id ? updated : account]);
    if (!saved) _toast('keyCodes.snack.updateFailed', const {}, ToastSeverity.error);
    return saved;
  }

  /// Forgets one on-key account, once the key no longer holds it.
  Future<bool> removeKeyAccount(String id) => saveKeyAccounts([...state.keyAccounts.where((account) => account.id != id)]);

  /// Adds the on-key accounts of [list] the vault does not remember yet, by
  /// key and name, in one save. Returns how many it added, or null when
  /// the save failed.
  Future<int?> addKeyAccounts(List<KeyAccount> list) async {
    final held = {for (final account in state.keyAccounts) (account.device, account.name)};
    final fresh = [
      for (final account in list)
        if (account.device.isNotEmpty && account.name.isNotEmpty && held.add((account.device, account.name)))
          account.copyWith(id: newUuid(), addedAt: account.addedAt == 0 ? _now : account.addedAt, updatedAt: unset),
    ];
    if (fresh.isEmpty) return 0;
    return await saveKeyAccounts([...state.keyAccounts, ...fresh]) ? fresh.length : null;
  }

  /// Forgets the key [device] in this vault: its remembered accounts, their
  /// tags and notes, and what proves its password. Nothing is sent to the
  /// key, and other keys are left alone.
  Future<bool> forgetKey(String device) async {
    final saved = await saveKeyAccounts([...state.keyAccounts.where((account) => account.device != device)]);
    return await forgetKeyAccess(device) && saved;
  }

  /// What proves the code password of the key [device], when the person
  /// had it remembered on this phone; null otherwise.
  Future<Uint8List?> keyAccess(String device) async {
    final session = state.session;
    if (session == null) return null;
    try {
      return (await _store.loadKeyAccess(session))[device];
    } catch (_) {
      return null;
    }
  }

  /// Remembers [accessKey], never the password, for the key [device], in
  /// this vault on this phone only.
  Future<bool> rememberKeyAccess(String device, Uint8List accessKey) async {
    final session = state.session;
    if (session == null) return false;
    try {
      await _store.saveKeyAccess({...await _store.loadKeyAccess(session), device: accessKey}, session);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drops what was remembered for the key [device]: its password changed,
  /// the key refused it, or the key was forgotten.
  Future<bool> forgetKeyAccess(String device) async {
    final session = state.session;
    if (session == null) return false;
    try {
      final access = await _store.loadKeyAccess(session);
      if (access.remove(device) != null) await _store.saveKeyAccess(access, session);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Adds [fresh] to [kind]'s list in one save, keeping when each was
  /// added; throws when the save fails, leaving the list as it was.
  Future<void> _addAll<T extends VaultEntry<T>>(_ItemList<T> kind, List<T> fresh, VaultSession session) async {
    if (fresh.isEmpty) return;
    final list = kind.read(state);
    final next = stampChanged([...list, ...fresh], list, now: _now);
    await kind.save(next, session);
    state = kind.write(state, next);
  }

  Future<bool> _addItem<T extends VaultEntry<T>>(_ItemList<T> kind, T item) async {
    final session = state.session;
    if (session == null) return false;
    final next = stampChanged([...kind.read(state), item], kind.read(state), now: _now);
    try {
      await kind.save(next, session);
      state = kind.write(state, next);
      _bump();
      _toast(kind.messages.added, {'name': kind.name(item)});
      return true;
    } catch (_) {
      _toast(kind.messages.addFailed, const {}, ToastSeverity.error);
      return false;
    }
  }

  Future<bool> _updateItem<T extends VaultEntry<T>>(_ItemList<T> kind, T updated) async {
    final session = state.session;
    if (session == null) return false;
    final previous = kind.read(state);
    final next = stampChanged([for (final item in previous) item.id == updated.id ? updated : item], previous, now: _now);
    state = kind.write(state, next);
    try {
      await kind.save(next, session);
      _bump();
      return true;
    } catch (_) {
      state = kind.write(state, previous);
      _toast(kind.messages.updateFailed, const {}, ToastSeverity.error);
      return false;
    }
  }

  /// Removes [removed], and the links the other items hold to it, in one go; a failed save puts everything back as it was.
  Future<void> _deleteItem<T extends VaultEntry<T>>(_ItemList<T> kind, T removed) async {
    final session = state.session;
    if (session == null) return;
    final index = kind.read(state).indexWhere((item) => item.id == removed.id);
    _DroppedLinks? dropped;
    try {
      // The items that named it are saved first, so the list below is read as they left it
      dropped = await _dropLinksTo(session, [removed]);
      final next = [...kind.read(state).where((item) => item.id != removed.id)];
      await kind.save(next, session);
      state = kind.write(state, next);
      _bump();
      ref
          .read(toastsProvider.notifier)
          .show(
            _t(kind.messages.removed, {'name': kind.name(removed)}),
            actionLabel: _t('app.undo'),
            onAction: () => unawaited(_restoreItem(kind, removed, index, session, relinked: dropped?.ids ?? const [])),
          );
    } catch (_) {
      await dropped?.undo().then<void>((_) {}, onError: (Object _) {});
      _toast(kind.messages.removeFailed, const {}, ToastSeverity.error);
    }
  }

  /// Puts a just-removed item back where it was, stamped as just changed so
  /// it outlives the deletion sync may already have shared: in the vault it
  /// was removed [from] and no other, as [_restoreAccount]. The items [relinked]
  /// that named it name it again.
  Future<void> _restoreItem<T extends VaultEntry<T>>(
    _ItemList<T> kind,
    T item,
    int index,
    VaultSession from, {
    List<String> relinked = const [],
  }) async {
    final session = state.session;
    final list = kind.read(state);
    if (session == null || !identical(session, from) || list.any((other) => other.id == item.id)) return;
    final next = [...list]..insert(index < 0 ? list.length : index.clamp(0, list.length), item);
    final restored = stampChanged(next, list, now: _now);
    try {
      await kind.save(restored, session);
      state = kind.write(state, restored);
      _bump();
      await _relinkRestored(item, relinked);
    } catch (_) {
      _toast(kind.messages.addFailed, const {}, ToastSeverity.error);
    }
  }

  // Links between items (docs/crypto.md, "Item bodies", `links`; the web vault's links.ts and relink.ts)

  /// The vault's Kemlock Server account as an owner, for the `account:` of the core's link functions; null when the vault
  /// does not sync to a server.
  Owner? get _linkAccount => ref.read(linkAccountProvider);

  /// Whether the person may change [entry]: always for the vault's own, by the verified chain for an entry of a space.
  bool _mayWrite(VaultEntry<Object?> entry) => ref.read(hiddenPasswordsProvider).canEdit(entry);

  /// The entry the vault holds as [entry] now, of its kind and id; [entry] itself when the vault does not hold it.
  VaultEntry<Object?> _held(VaultEntry<Object?> entry) =>
      entriesOf(state.lists).firstWhereOrNull((other) => other.runtimeType == entry.runtimeType && other.id == entry.id) ?? entry;

  /// The entries of [put] by their kind, each list in order.
  Map<Type, List<Object>> _byKind(Iterable<VaultEntry<Object?>> entries) {
    final kinds = <Type, List<Object>>{};
    for (final entry in entries) {
      kinds.putIfAbsent(entry.runtimeType, () => []).add(entry);
    }
    return kinds;
  }

  /// [_applyKind] for entries of any kind: each kind's list saved once with [put] in it and [remove] out of it. All or none: when
  /// a save fails the lists saved before it go back and the error goes on. Gives a step that puts every list back as it was.
  Future<Future<void> Function()> _applyEntries(
    VaultSession session, {
    required Iterable<VaultEntry<Object?>> put,
    Iterable<VaultEntry<Object?>> remove = const [],
  }) async {
    final putting = _byKind(put);
    final removing = _byKind(remove);
    final undo = <Future<void> Function()>[];
    try {
      for (final kind in {...putting.keys, ...removing.keys}) {
        undo.add(await _applyKind(session, put: putting[kind] ?? const [], remove: removing[kind] ?? const []));
      }
    } catch (_) {
      for (final step in undo.reversed) {
        try {
          await step();
        } catch (_) {
          // Best effort: the error that stopped this is the one that goes on
        }
      }
      rethrow;
    }
    return () async {
      for (final step in undo.reversed) {
        await step();
      }
    };
  }

  /// Saves [put], each replacing the entry with its id in its own list, and takes [remove] out of theirs, whatever the kinds,
  /// one save per list and the changed ones stamped as just changed. All or none: false, with the lists as they were, when a
  /// save fails. Sync follows, as after any change.
  Future<bool> saveEntries(List<VaultEntry<Object?>> put, {List<VaultEntry<Object?>> remove = const []}) async {
    final session = state.session;
    if (session == null) return false;
    if (put.isEmpty && remove.isEmpty) return true;
    try {
      await _applyEntries(session, put: put, remove: remove);
      _bump();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Links [a] and [b] to each other, which writes both items; an end that names the other already is left as it is, so
  /// this also writes the missing end of a link that only one end names. False, with a toast, when the person may not change
  /// both, or a save failed.
  Future<bool> linkItems(VaultEntry<Object?> a, VaultEntry<Object?> b) {
    final first = _held(a);
    final second = _held(b);
    final linked = linkEntries(first, second, now: _now, account: _linkAccount);
    return _saveLinked(first, second, linked.a, linked.b);
  }

  /// Unlinks [a] and [b]: both items lose the other, and the code's `linkedLoginId` or the login's `accountId` that tied them
  /// is cleared. False, with a toast, when the person may not change both, or a save failed.
  Future<bool> unlinkItems(VaultEntry<Object?> a, VaultEntry<Object?> b) {
    final first = _held(a);
    final second = _held(b);
    final unlinked = unlinkEntries(first, second, now: _now, account: _linkAccount);
    return _saveLinked(first, second, unlinked.a, unlinked.b);
  }

  /// Saves what a link or an unlink changed of [first] and [second] (the [nextFirst] and [nextSecond] the core made), both
  /// together.
  Future<bool> _saveLinked(VaultEntry<Object?> first, VaultEntry<Object?> second, VaultEntry<Object?> nextFirst, VaultEntry<Object?> nextSecond) async {
    final put = [
      if (!identical(first, nextFirst)) nextFirst,
      if (!identical(second, nextSecond)) nextSecond,
    ];
    if (put.isEmpty) return true;
    if (put.any((entry) => !_mayWrite(entry))) {
      _toast('links.snack.readOnly', const {}, ToastSeverity.error);
      return false;
    }
    final saved = await saveEntries(put);
    if (!saved) _toast('links.snack.failed', const {}, ToastSeverity.error);
    return saved;
  }

  /// The entries that name one of [removed] in their `links`, as they are once they do not: the ones the person may change.
  /// The link of a code and its login (`linkedLoginId`, `accountId`) is not in `links` and is left alone.
  List<VaultEntry<Object?>> _withoutLinksTo(List<VaultEntry<Object?>> removed) {
    // A vault with no link at all has nothing to drop, and needs no account to tell
    if (!entriesOf(state.lists).any((entry) => entry.links.isNotEmpty)) return const [];
    final account = _linkAccount;
    final names = {
      for (final entry in removed) ...{entry.id.toLowerCase(), linkIdOf(entry, account: account).toLowerCase()},
    };
    final going = {for (final entry in removed) (entry.runtimeType, entry.id)};
    final others = <VaultEntry<Object?>>[];
    for (final other in entriesOf(state.lists)) {
      if (going.contains((other.runtimeType, other.id)) || !other.links.ids.any(names.contains) || !_mayWrite(other)) continue;
      var links = other.links;
      for (final name in names) {
        links = links.removing(name);
      }
      others.add(other.withLinks(links) as VaultEntry<Object?>);
    }
    return others;
  }

  /// Takes [removed] out of the `links` of the entries that name them, saved together; null when none does. The step it gives puts
  /// them back as they were; a failed save puts them back and throws.
  Future<_DroppedLinks?> _dropLinksTo(VaultSession session, List<VaultEntry<Object?>> removed) async {
    final others = _withoutLinksTo(removed);
    if (others.isEmpty) return null;
    return _DroppedLinks(await _applyEntries(session, put: others), [for (final other in others) other.id]);
  }

  /// After Undo put [restored] back: the entries of [ids], which named it before it was removed, name it again, as far as
  /// they are still there and the person may change them. A save that fails leaves them one-way links, which the item sheet
  /// offers to mend.
  Future<void> _relinkRestored(VaultEntry<Object?> restored, List<String> ids) async {
    if (ids.isEmpty) return;
    final held = entriesOf(state.lists);
    final put = <VaultEntry<Object?>>[];
    for (final id in ids) {
      final other = held.firstWhereOrNull((entry) => entry.id == id);
      if (other == null || !_mayWrite(other)) continue;
      final linked = linkEntries(restored, other, now: _now, account: _linkAccount);
      if (!identical(linked.b, other)) put.add(linked.b);
    }
    await saveEntries(put);
  }

  /// What a merge does to the items linked to the ones it removes: the item that stays takes over their links, and each item
  /// that named one of them names it instead (relink.ts of the web vault). Null when nothing is linked to the removed items. A
  /// link no item of the vault answers to is taken over too, and an item the person may not change is left as it is.
  ({VaultEntry<Object?> survivor, List<VaultEntry<Object?>> others})? _mergeLinks(Object kept, List<Object> gone) {
    final going = [
      for (final item in gone)
        if (item is VaultEntry<Object?>) item,
    ];
    if (kept is! VaultEntry<Object?> || going.isEmpty) return null;
    // A vault with no link at all has nothing to move
    if (!entriesOf(state.lists).any((entry) => entry.links.isNotEmpty)) return null;
    final account = _linkAccount;
    final lists = state.lists;
    final members = {for (final entry in [kept, ...going]) (entry.runtimeType, entry.id)};
    final goneNames = {
      for (final entry in going) ...{entry.id.toLowerCase(), linkIdOf(entry, account: account).toLowerCase()},
    };
    final ownName = linkIdOf(kept, account: account).toLowerCase();
    final taken = <ItemLink>[];
    final others = <(Type, String), VaultEntry<Object?>>{};
    for (final entry in going) {
      for (final linked in linkedItemsOf(lists, entry, account: account)) {
        final other = linked.entry;
        if (linked.viaLinkedLogin || (other != null && members.contains((other.runtimeType, other.id)))) continue;
        taken.add(entry.links.firstWhereOrNull((link) => link.key == linked.id) ?? ItemLink(linked.id));
        if (other != null && _mayWrite(other)) others[(other.runtimeType, other.id)] = other;
      }
    }
    final links = [
      for (final link in [...kept.links, ...taken])
        if (!link.isReadable || !(goneNames.contains(link.key) || link.key == ownName)) link,
    ];
    final survivor = kept.withLinks(links) as VaultEntry<Object?>;
    final rewritten = [for (final other in others.values) _namingInstead(other, goneNames, ownName)];
    if (rewritten.isEmpty && const ListEquality<ItemLink>().equals(survivor.links, kept.links)) return null;
    return (survivor: survivor, others: rewritten);
  }

  /// [other] with the [gone] names out of its links and [name] in.
  VaultEntry<Object?> _namingInstead(VaultEntry<Object?> other, Set<String> gone, String name) {
    var links = other.links;
    for (final id in gone) {
      links = links.removing(id);
    }
    return other.withLinks(links.adding(name, ownIds: [other.id])) as VaultEntry<Object?>;
  }

  // Duplicate cleaner (the add-duplicate-cleaner plan, tasks group 6)

  late final _accounts = _ItemList<OtpAccount>(
    read: (state) => state.accounts,
    write: (state, accounts) => state.copyWith(accounts: accounts),
    save: (accounts, session) => _store.saveAccounts(accounts, session),
    name: _displayName,
    messages: const _ItemMessages(
      added: 'app.snack.accountAdded',
      addFailed: 'app.snack.accountAddFailed',
      updateFailed: 'app.snack.accountUpdateFailed',
      removed: 'app.snack.accountRemoved',
      removeFailed: 'app.snack.accountRemoveFailed',
    ),
  );

  late final _services = _ItemList<BackupService>(
    read: (state) => state.backupServices,
    write: (state, services) => state.copyWith(backupServices: services),
    save: (services, session) => _store.saveBackupServices(services, session),
    name: (service) => service.serviceName,
    messages: const _ItemMessages(
      added: 'app.snack.backupSaved',
      addFailed: 'app.snack.backupSaveFailed',
      updateFailed: 'app.snack.backupUpdateFailed',
      removed: 'app.snack.backupDeleted',
      removeFailed: 'app.snack.backupDeleteFailed',
    ),
  );

  /// Puts [put] into [kind]'s list (each replaces the item with its id, or joins at the end) and
  /// takes [remove] out, in one save, the changed ones stamped as just changed. On a failed save the
  /// list goes back as it was and the error goes on. Gives a step that puts the list back as it was.
  Future<Future<void> Function()> _applyMerge<T extends VaultEntry<T>>(
    _ItemList<T> kind,
    VaultSession session, {
    List<T> put = const [],
    List<T> remove = const [],
  }) async {
    final before = kind.read(state);
    final putting = {for (final item in put) item.id: item};
    final removing = {for (final item in remove) item.id};
    final held = {for (final item in before) item.id};
    final next = stampChanged(
      [
        for (final item in before)
          if (!removing.contains(item.id)) putting[item.id] ?? item,
        for (final item in put)
          if (!held.contains(item.id)) item,
      ],
      before,
      now: _now,
    );
    state = kind.write(state, next);
    try {
      await kind.save(next, session);
    } catch (_) {
      state = kind.write(state, before);
      rethrow;
    }
    return () async {
      state = kind.write(state, before);
      await kind.save(before, session);
    };
  }

  late final _keyAccounts = _ItemList<KeyAccount>(
    read: (state) => state.keyAccounts,
    write: (state, accounts) => state.copyWith(keyAccounts: accounts),
    save: (accounts, session) => _store.saveKeyAccounts(accounts, session),
    name: (account) => account.name,
    messages: const _ItemMessages(
      added: 'keyCodes.snack.updateFailed',
      addFailed: 'keyCodes.snack.updateFailed',
      updateFailed: 'keyCodes.snack.updateFailed',
      removed: 'keyCodes.snack.updateFailed',
      removeFailed: 'keyCodes.snack.updateFailed',
    ),
  );

  /// [_applyMerge] on the list of the kind of [put]'s items (or, with none, of [remove]'s), which are all of one kind.
  Future<Future<void> Function()> _applyKind(VaultSession session, {required List<Object> put, List<Object> remove = const []}) {
    // TODO(file-items): `VaultFile() => _applyMerge(_files, ...)` once the vault holds File items (state.files, `_files`), so that
    // a File item can be linked, unlinked and relinked like the others.
    return switch (put.isNotEmpty ? put.first : remove.first) {
      KeyAccount() => _applyMerge(_keyAccounts, session, put: put.cast<KeyAccount>(), remove: remove.cast<KeyAccount>()),
      OtpAccount() => _applyMerge(_accounts, session, put: put.cast<OtpAccount>(), remove: remove.cast<OtpAccount>()),
      BackupService() => _applyMerge(_services, session, put: put.cast<BackupService>(), remove: remove.cast<BackupService>()),
      SecureNote() => _applyMerge(_notes, session, put: put.cast<SecureNote>(), remove: remove.cast<SecureNote>()),
      Passkey() => _applyMerge(_passkeys, session, put: put.cast<Passkey>(), remove: remove.cast<Passkey>()),
      VaultKey() => _applyMerge(_keys, session, put: put.cast<VaultKey>(), remove: remove.cast<VaultKey>()),
      Contact() => _applyMerge(_contacts, session, put: put.cast<Contact>(), remove: remove.cast<Contact>()),
      Login() => _applyMerge(_logins, session, put: put.cast<Login>(), remove: remove.cast<Login>()),
      PaymentCard() => _applyMerge(_cards, session, put: put.cast<PaymentCard>(), remove: remove.cast<PaymentCard>()),
      Identity() => _applyMerge(_identities, session, put: put.cast<Identity>(), remove: remove.cast<Identity>()),
      VaultFile() => _applyMerge(_files, session, put: put.cast<VaultFile>(), remove: remove.cast<VaultFile>()),
      _ => throw ArgumentError.value(put.isNotEmpty ? put.first : remove.first, 'put', 'is not an item a merge keeps'),
    };
  }

  /// Merges a group of duplicates as [choices] say (design 6): writes the merge record first, then
  /// relinks the logins linked to a code that goes, moves the links of the items that go to the item that
  /// stays (and the items linked to them to it), then saves the item that stays with the picked
  /// fields and removes the others in one save of their list. Each list it touches goes back as it
  /// was when a save fails, and so does everything before it, so a failed merge leaves the vault as
  /// it was. True once it is done; the toast offers Undo.
  Future<bool> mergeDuplicates(MergeChoices choices) async {
    final session = state.session;
    if (session == null) return false;
    final result = choices.merged(_now);
    final gone = [for (final item in choices.removed) item.item];
    final goneIds = {for (final item in choices.removed) item.id};
    // A login linked to a code that goes is linked to the code that stays
    final relink = result is OtpAccount
        ? [
            for (final login in state.logins)
              if (goneIds.contains(login.accountId)) login,
          ]
        : const <Login>[];
    final record = MergeRecord(
      id: newUuid(),
      at: _now,
      kind: mergeKindOf(result),
      kept: mergeJsonOf(choices.kept.item),
      removed: [for (final item in gone) mergeJsonOf(item)],
      relinked: [for (final login in relink) mergeJsonOf(login)],
    );
    final store = DedupStore(_store);
    final undo = <Future<void> Function()>[];
    try {
      final answers = await store.loadAnswers(session);
      await store.saveAnswers(answers.pruned(_now).withMerge(record), session);
      undo.add(() => store.saveAnswers(answers, session));
      if (relink.isNotEmpty) {
        undo.add(await _applyMerge(_logins, session, put: [for (final login in relink) login.copyWith(accountId: choices.keptId)]));
      }
      // The item that stays takes over the links of the ones that go, and the items linked to them link to it
      final linked = _mergeLinks(result, gone);
      if (linked != null && linked.others.isNotEmpty) {
        undo.add(await _applyEntries(session, put: linked.others));
      }
      undo.add(await _applyKind(session, put: [linked?.survivor ?? result], remove: gone));
      _bump();
      ref
          .read(toastsProvider.notifier)
          .show(
            _t('vault.snack.duplicatesMerged', {'count': gone.length}),
            actionLabel: _t('app.undo'),
            onAction: () => unawaited(undoMerge(record.id, from: session)),
          );
      return true;
    } catch (_) {
      for (final step in undo.reversed) {
        try {
          await step();
        } catch (_) {
          // Best effort: the merge record is what Undo repairs a half merge from
        }
      }
      _toast('vault.snack.duplicatesMergeFailed', const {}, ToastSeverity.error);
      return false;
    }
  }

  /// Puts back the items of the merge with [recordId] as they were, in the vault it was made in and
  /// no other (when [from] is given it must be the open session), stamped as just changed so they
  /// outlive the removals sync may already have shared, and drops the record. False when there is
  /// no such record, it is older than 30 days, or the save failed.
  Future<bool> undoMerge(String recordId, {VaultSession? from}) async {
    final session = state.session;
    if (session == null || (from != null && !identical(session, from))) return false;
    final store = DedupStore(_store);
    final undo = <Future<void> Function()>[];
    try {
      final answers = await store.loadAnswers(session);
      final record = answers.mergeRecords.firstWhereOrNull((record) => record.id == recordId);
      if (record == null || !record.undoable(_now)) return false;
      final kept = mergeItemOf(record.kind, record.kept);
      if (kept == null) return false;
      final removed = <Object>[for (final json in record.removed) ?mergeItemOf(record.kind, json)];
      // Logins that went to another code are linked as they were, unless they are gone since
      final heldLogins = {for (final login in state.logins) login.id};
      final relinked = <Object>[
        for (final json in record.relinked)
          if (mergeItemOf('login', json) case final Login login when heldLogins.contains(login.id)) login,
      ];
      if (relinked.isNotEmpty) {
        undo.add(await _applyKind(session, put: relinked));
      }
      undo.add(await _applyKind(session, put: [kept, ...removed]));
      await store.saveAnswers(answers.withoutMerge(recordId), session);
      _bump();
      _toast('vault.snack.duplicatesUndone');
      return true;
    } catch (_) {
      for (final step in undo.reversed) {
        try {
          await step();
        } catch (_) {
          // Best effort, as when a merge fails
        }
      }
      _toast('vault.snack.duplicatesUndoFailed', const {}, ToastSeverity.error);
      return false;
    }
  }

  /// Takes what sync merged; not a user change, so it doesn't start another
  /// sync. Keys, notes, passkeys, on-key accounts, contacts, logins, cards, identities and files are
  /// saved only when sync changed them.
  Future<void> applySynced(Lists lists) async {
    final session = state.session;
    if (session == null) return;
    bool changed(List<VaultEntry<Object?>> next, List<VaultEntry<Object?>> now) =>
        canonical([for (final entry in next) entry.toJson()]) != canonical([for (final entry in now) entry.toJson()]);
    await _store.saveAccounts(lists.accounts, session);
    await _store.saveBackupServices(lists.backupServices, session);
    if (changed(lists.keys, state.keys)) await _store.saveKeys(lists.keys, session);
    if (changed(lists.notes, state.notes)) await _store.saveNotes(lists.notes, session);
    if (changed(lists.passkeys, state.passkeys)) await _store.savePasskeys(lists.passkeys, session);
    if (changed(lists.keyAccounts, state.keyAccounts)) await _store.saveKeyAccounts(lists.keyAccounts, session);
    if (changed(lists.contacts, state.contacts)) await _store.saveContacts(lists.contacts, session);
    if (changed(lists.logins, state.logins)) await _store.saveLogins(lists.logins, session);
    if (changed(lists.cards, state.cards)) await _store.saveCards(lists.cards, session);
    if (changed(lists.identities, state.identities)) await _store.saveIdentities(lists.identities, session);
    if (changed(lists.files, state.files)) await _store.saveFiles(lists.files, session);
    state = state.copyWith(
      accounts: lists.accounts,
      backupServices: lists.backupServices,
      keys: lists.keys,
      notes: lists.notes,
      passkeys: lists.passkeys,
      keyAccounts: lists.keyAccounts,
      contacts: lists.contacts,
      logins: lists.logins,
      cards: lists.cards,
      identities: lists.identities,
      files: lists.files,
    );
  }
}

/// The items that named an item that was removed, now without it: their ids, and the step that puts them back as they were.
class _DroppedLinks {
  const _DroppedLinks(this.undo, this.ids);

  final Future<void> Function() undo;
  final List<String> ids;
}

/// The toasts a kind of vault item shows.
class _ItemMessages {
  const _ItemMessages({
    required this.added,
    required this.addFailed,
    required this.updateFailed,
    required this.removed,
    required this.removeFailed,
  });

  final String added;
  final String addFailed;
  final String updateFailed;

  /// Takes `{name}`.
  final String removed;
  final String removeFailed;
}

/// How the controller reads, writes and saves one kind of vault item.
class _ItemList<T extends VaultEntry<T>> {
  const _ItemList({required this.read, required this.write, required this.save, required this.name, required this.messages});

  final List<T> Function(VaultState state) read;
  final VaultState Function(VaultState state, List<T> items) write;
  final Future<void> Function(List<T> items, VaultSession session) save;

  /// What a toast calls the item.
  final String Function(T item) name;
  final _ItemMessages messages;
}
