/// Answers the OpenPGP requests of Android mail apps with the open vault's
/// keys (openspec: add-pgp-mail-provider, decisions 6 and 9). It is hosted
/// at the root of the app, outside any screen, so it answers while the
/// vault is locked and with no activity attached.
///
/// In order: a locked vault gives every request the same answer, that the
/// person is needed, without looking at anything in it; then the caller's
/// approval and certificate, so that an app never approved gets that same
/// answer from an open vault too, whatever it sends; then the API version;
/// then the action.
/// A request that needs the person is kept here, without its input, under
/// the request id the service made, for the request screen to show.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../platform/mail_requests.dart';
import '../../vault/vault_controller.dart';
import '../pgp/pgp_controller.dart';
import '../pgp/pgp_job.dart';
import '../pgp/pgp_widgets.dart' show pgpErrorText;
import 'mail_apps.dart';
import 'mail_caller.dart';
import 'mail_key_cache.dart';
import 'mail_keys.dart';

/// The names `org.openintents.openpgp.util.OpenPgpApi` gives (the copy in
/// android/app/src/main/java/org/openintents/openpgp).
abstract final class OpenPgp {
  static const _action = 'org.openintents.openpgp.action.';
  static const checkPermission = '${_action}CHECK_PERMISSION';
  static const sign = '${_action}SIGN';
  static const cleartextSign = '${_action}CLEARTEXT_SIGN';
  static const detachedSign = '${_action}DETACHED_SIGN';
  static const encrypt = '${_action}ENCRYPT';
  static const signAndEncrypt = '${_action}SIGN_AND_ENCRYPT';
  static const decryptVerify = '${_action}DECRYPT_VERIFY';
  static const decryptMetadata = '${_action}DECRYPT_METADATA';
  static const getSignKeyId = '${_action}GET_SIGN_KEY_ID';
  static const getSignKeyIdLegacy = '${_action}GET_SIGN_KEY_ID_LEGACY';
  static const getKeyIds = '${_action}GET_KEY_IDS';
  static const getKey = '${_action}GET_KEY';
  static const backup = '${_action}BACKUP';
  static const queryAutocryptStatus = '${_action}QUERY_AUTOCRYPT_STATUS';
  static const updateAutocryptPeer = '${_action}UPDATE_AUTOCRYPT_PEER';
  static const autocryptKeyTransfer = 'autocrypt_key_transfer';

  static const resultError = 0;
  static const resultSuccess = 1;
  static const resultUserInteraction = 2;

  /// `OpenPgpError`'s ids.
  static const genericError = 0;
  static const incompatibleApiVersions = 1;
  static const noUserIds = 3;
  static const opportunisticMissingKeys = 4;

  /// `OpenPgpSignatureResult`'s results.
  static const noSignature = -1;
  static const invalidSignature = 0;
  static const validKeyConfirmed = 1;
  static const keyMissing = 2;
  static const validKeyUnconfirmed = 3;
  static const invalidKeyRevoked = 4;
  static const invalidKeyExpired = 5;
  static const invalidKeyInsecure = 6;

  /// `OpenPgpDecryptionResult`'s results.
  static const notEncrypted = -1;
  static const encrypted = 1;

  static const autocryptUnavailable = 0;
  static const autocryptAvailable = 2;

  /// The versions OpenKeychain answers; Thunderbird and FairEmail send 12.
  static const minApiVersion = 3;
  static const maxApiVersion = 12;
}

/// The most input a request may carry: 50 MB (decision 10, an assumption
/// to correct by what a phone measures). The decrypted content has the
/// same bound, so a small message cannot unpack to fill memory.
const maxMailInput = 50 * 1024 * 1024;

/// How long a mail request's job may run. A mail app sends its request and
/// waits, and nobody is at Kemlock's screens to cancel one: a message made
/// to be slow, short of every bound, would keep a core busy for as long as
/// it took. Two minutes is many times what the largest message takes on a
/// slow phone.
const mailJobTimeout = Duration(minutes: 2);

/// What a job stopped at its time limit comes to.
const mailJobTimedOut = PgpFailedOutcome(pgp.PgpException(pgp.PgpProblem.cancelled, detail: 'the mail job ran out of time'));

/// The outcome of [job], or [mailJobTimedOut] once it has run past [limit]:
/// it is then cancelled, which kills the isolate of a job that writes no
/// file, as a mail job writes none.
Future<PgpOutcome> outcomeWithin(PgpJob job, Duration limit) async {
  var ranOut = false;
  final timer = Timer(limit, () {
    ranOut = true;
    job.cancel();
  });
  try {
    final outcome = await job.result;
    // A job that ended on its own as the time ran out keeps what it came to
    return ranOut && outcome is PgpCancelledOutcome ? mailJobTimedOut : outcome;
  } finally {
    timer.cancel();
  }
}

/// What the person is asked on the request screen.
sealed class MailStep {
  const MailStep();
}

/// The vault is locked: the lock screen, with a line naming the app.
final class UnlockStep extends MailStep {
  const UnlockStep();
}

/// The app was never approved by the open vault, or was under another
/// certificate.
final class ApproveStep extends MailStep {
  const ApproveStep({required this.otherCertificate});

  final bool otherCertificate;
}

/// The mail app asks which key to sign with.
final class PickKeyStep extends MailStep {
  const PickKeyStep({this.address, this.preselect});

  /// The address the app gave, whose keys are listed first.
  final String? address;

  /// The key ID the app had before, when it is still allowed.
  final int? preselect;
}

/// The request needs an own key the app is not allowed to use.
final class AddKeyStep extends MailStep {
  const AddKeyStep(this.vaultKeyId);

  final String vaultKeyId;
}

/// The request needs a protected key that is not open yet.
final class PassphraseStep extends MailStep {
  const PassphraseStep(this.vaultKeyId);

  final String vaultKeyId;
}

/// Some recipients have no usable key.
final class MissingKeysStep extends MailStep {
  const MissingKeysStep(this.addresses);

  final List<String> addresses;
}

/// Some recipients' keys were never checked, and the app never went on
/// for them.
final class UncheckedStep extends MailStep {
  const UncheckedStep(this.contactIds);

  final List<String> contactIds;
}

/// A request that needs the person, kept until its screen ends or for ten
/// minutes.
@immutable
class MailPending {
  const MailPending(this.call, this.step, this.at);

  /// The request, without its input.
  final MailCall call;

  /// What it needed when it was answered.
  final MailStep step;
  final DateTime at;
}

/// What working on a request came to: an answer, or a step for the person.
typedef _Outcome = ({MailAnswer? answer, MailStep? step});

class MailHandler {
  MailHandler(this._ref);

  final Ref _ref;

  /// How long a request that needs the person is kept for its screen.
  static const pendingFor = Duration(minutes: 10);

  /// How many are kept for one app, as the service keeps (`PendingRequests`):
  /// its oldest is forgotten for a new one, so no app fills the memory.
  static const pendingPerApp = 8;

  final _pending = <String, MailPending>{};

  /// Every answer starts from here.
  static const _personNeeded = {'result_code': OpenPgp.resultUserInteraction};

  Messages get _messages => _ref.read(messagesProvider);
  DateTime get _now => _ref.read(clockProvider)();

  /// The request kept under [requestId], if any.
  MailPending? pending(String requestId) {
    _prune();
    return _pending[requestId];
  }

  /// Forgets [requestId], once its screen ended.
  void forget(String requestId) => _pending.remove(requestId);

  /// Opens the protected key [vaultKeyId] with [passphrase] for the mail
  /// requests that follow, until the vault locks (decision 13); the
  /// passphrase is not kept. Throws a [pgp.PgpException],
  /// [pgp.PgpProblem.wrongPassphrase] when it is not the key's.
  Future<void> openKey(String vaultKeyId, String passphrase) async {
    final key = _ref.read(vaultControllerProvider).keys.firstWhere((k) => k.id == vaultKeyId);
    final opened = await _ref.read(mailKeyOpenerProvider)(unb64(key.privateKey), passphrase);
    // Kept only while the vault that opened it is open, and the key is the same
    final now = _ref.read(vaultControllerProvider);
    if (now.isUnlocked && now.keys.any((k) => k.id == key.id && k.privateKey == key.privateKey)) {
      _ref.read(mailKeyCacheProvider).keep(key, opened);
    }
  }

  /// Answers [call]; a [MailCall.dry] call that comes down to the work on
  /// its input, with [MailAnswer.sendInput].
  Future<MailAnswer> answer(MailCall call) async {
    // Decision 6: nothing about the vault, the caller or the request is looked at
    if (!_ref.read(vaultControllerProvider).isUnlocked) return _askPerson(call, const UnlockStep());
    final outcome = await _work(call, dry: call.dry);
    final step = outcome.step;
    if (step != null) return _askPerson(call, step);
    // Only a dry call ends with neither
    return outcome.answer ?? MailAnswer.sendInput;
  }

  /// What the request screen of [requestId] should ask next, worked out
  /// without the input the request had: null when nothing more can be
  /// asked before the mail app sends it again.
  Future<MailStep?> stepFor(String requestId) async {
    final kept = pending(requestId);
    if (kept == null) return null;
    if (!_ref.read(vaultControllerProvider).isUnlocked) return const UnlockStep();
    final dry = await _work(kept.call, dry: true);
    if (dry.step != null) return dry.step;
    // What only the input could tell, and is still to ask
    final keys = readMailKeys(_ref.read);
    final app = approvalOf(kept.call.caller, await _apps());
    switch (kept.step) {
      case AddKeyStep(:final vaultKeyId) when app != null && !app.keys.contains(vaultKeyId) && keys.ownByVaultId(vaultKeyId) != null:
        return kept.step;
      case PassphraseStep(:final vaultKeyId) when _needsPassphrase(keys.ownByVaultId(vaultKeyId)):
        return kept.step;
      default:
        return null;
    }
  }

  MailAnswer _askPerson(MailCall call, MailStep step) {
    _prune();
    final theirs = [
      for (final MapEntry(:key, :value) in _pending.entries)
        if (value.call.caller.package == call.caller.package) key,
    ];
    if (theirs.length >= pendingPerApp) theirs.take(theirs.length - pendingPerApp + 1).forEach(_pending.remove);
    _pending[call.requestId] = MailPending(call.withoutInput(), step, _now);
    return const MailAnswer(_personNeeded);
  }

  void _prune() {
    final cutoff = _now.subtract(pendingFor);
    _pending.removeWhere((_, kept) => kept.at.isBefore(cutoff));
  }

  Future<List<MailApp>> _apps() => _ref.read(mailAppsProvider.notifier).current();

  // ─── The order of checks ──────────────────────────────────────────────────

  /// Works [call] out. With [dry] the input is not there: the result is the
  /// step still to ask, or neither when the work itself is what is left.
  Future<_Outcome> _work(MailCall call, {required bool dry}) async {
    final apps = await _apps();
    final MailApp app;
    switch (judgeCaller(call.caller, apps)) {
      case MailCallerStanding.refused:
        return _answer(_error(OpenPgp.genericError, _messages.t('mail.error.refused')));
      case MailCallerStanding.unknown:
        return _ask(const ApproveStep(otherCertificate: false));
      case MailCallerStanding.otherCertificate:
        return _ask(const ApproveStep(otherCertificate: true));
      case MailCallerStanding.approved:
        app = approvalOf(call.caller, apps)!;
    }
    // Only after the caller: no version an unapproved app sends shows it whether the vault is open
    final version = call.extras['api_version'];
    if (version is! int || version < OpenPgp.minApiVersion || version > OpenPgp.maxApiVersion) {
      return _answer(_error(OpenPgp.incompatibleApiVersions, _messages.t('mail.error.version')));
    }
    if (call.inputTooLarge || (call.input?.length ?? 0) > maxMailInput) {
      return _answer(_error(OpenPgp.genericError, _messages.t('mail.error.tooLarge')));
    }
    final keys = readMailKeys(_ref.read);
    return switch (call.action) {
      OpenPgp.checkPermission => _answer(_success()),
      OpenPgp.getKeyIds => _keyIds(call, app, keys),
      OpenPgp.getKey => _getKey(call, app, keys),
      OpenPgp.getSignKeyId => _signKeyId(call, app, keys),
      OpenPgp.queryAutocryptStatus => _answer(_autocryptStatus(call, keys)),
      OpenPgp.updateAutocryptPeer => _answer(_success()),
      OpenPgp.cleartextSign || OpenPgp.sign => _sign(call, app, keys, dry: dry, detached: false),
      OpenPgp.detachedSign => _sign(call, app, keys, dry: dry, detached: true),
      OpenPgp.encrypt => _encrypt(call, app, keys, dry: dry, signed: false),
      OpenPgp.signAndEncrypt => _encrypt(call, app, keys, dry: dry, signed: true),
      OpenPgp.decryptVerify => _decrypt(call, app, keys, dry: dry),
      _ => _answer(_error(OpenPgp.genericError, _messages.t('mail.error.unsupported', {'action': _actionName(call.action)}))),
    };
  }

  static String _actionName(String action) => action.startsWith(OpenPgp._action) ? action.substring(OpenPgp._action.length) : action;

  static _Outcome _answer(Map<String, Object?> result, [Uint8List? output]) => (answer: MailAnswer(result, output: output), step: null);

  static _Outcome _ask(MailStep step) => (answer: null, step: step);

  /// What a dry run comes to when only the work is left.
  static const _Outcome _workLeft = (answer: null, step: null);

  static Map<String, Object?> _success([Map<String, Object?> extras = const {}]) => {'result_code': OpenPgp.resultSuccess, ...extras};

  static Map<String, Object?> _error(int id, String message) => {
    'result_code': OpenPgp.resultError,
    'error': {'id': id, 'message': message},
  };

  Map<String, Object?> _noKey() => _error(OpenPgp.genericError, _messages.t('mail.error.noKey'));

  /// For a key ID that keys of more than one fingerprint share: none is
  /// picked for the app.
  Map<String, Object?> _sharedId() => _error(OpenPgp.genericError, _messages.t('mail.error.sharedKeyId'));

  /// For a key on a security key, which signs and decrypts only in the PGP sheets.
  Map<String, Object?> _onCard() => _error(OpenPgp.genericError, _messages.t('mail.error.onCard'));

  bool _armor(MailCall call) => call.extras['ascii_armor'] == true;

  static List<int> _longs(Object? value) => [
    if (value is List)
      for (final v in value)
        if (v is int) v,
  ];

  static List<String> _strings(Object? value) => [
    if (value is List)
      for (final v in value)
        if (v is String && v.trim().isNotEmpty) v,
  ];

  // ─── Key questions ────────────────────────────────────────────────────────

  /// The key IDs for the addresses of `user_ids`. The mail app encrypts to
  /// them by ID next, with no address left to tell what a check covers, so
  /// a checked contact found for an address its check does not cover is
  /// asked about here, as encrypting asks about an unchecked one.
  _Outcome _keyIds(MailCall call, MailApp app, MailKeys keys) {
    final ids = <int>{};
    final unchecked = <String>[];
    for (final userId in _strings(call.extras['user_ids'])) {
      final address = mailAddress(userId);
      if (address == null) continue;
      final found = keys.recipientsFor(address);
      ids
        ..addAll(found.own.map((k) => k.keyId))
        ..addAll(found.contacts.map((k) => k.keyId));
      for (final k in found.contacts) {
        if (k.checked && !k.confirms(address) && !app.unchecked.contains(k.fingerprint) && !unchecked.contains(k.contact.id)) {
          unchecked.add(k.contact.id);
        }
      }
    }
    if (unchecked.isNotEmpty) return _ask(UncheckedStep(unchecked));
    return _answer(_success({'key_ids': ids.toList()}));
  }

  Map<String, Object?> _autocryptStatus(MailCall call, MailKeys keys) {
    final userIds = _strings(call.extras['user_ids']);
    var every = userIds.isNotEmpty;
    var confirmed = userIds.isNotEmpty;
    for (final userId in userIds) {
      final address = mailAddress(userId);
      final found = address == null ? null : keys.recipientsFor(address);
      if (address == null || found == null || (found.own.isEmpty && found.contacts.isEmpty)) {
        every = false;
        confirmed = false;
        continue;
      }
      // Confirmed for this address: a key checked before its owner added it is not
      if (found.contacts.any((k) => !k.confirms(address))) confirmed = false;
    }
    return _success({
      'autocrypt_status': every ? OpenPgp.autocryptAvailable : OpenPgp.autocryptUnavailable,
      'keys_confirmed': every && confirmed,
    });
  }

  _Outcome _getKey(MailCall call, MailApp app, MailKeys keys) {
    final keyId = call.extras['key_id'];
    MailOwnKey? own;
    MailContactKey? contact;
    if (keyId is int && keyId != 0) {
      if (keys.sharesId(keyId)) return _answer(_sharedId());
      own = keys.ownById(keyId);
      contact = own == null ? keys.contactById(keyId) : null;
    } else if (call.extras['user_id'] case final String userId) {
      final address = mailAddress(userId);
      if (address != null) {
        own = keys.own.where((k) => k.addresses.contains(address)).firstOrNull;
        contact = own == null ? keys.contacts.where((k) => k.addresses.contains(address)).firstOrNull : null;
      }
    }
    if (own != null && !app.keys.contains(own.key.id)) return _ask(AddKeyStep(own.key.id));
    final public = own?.publicKey ?? contact?.publicKey;
    if (public == null) return _answer(_noKey());
    final output = _armor(call) ? Uint8List.fromList(utf8.encode(pgp.armoredPgpPublicKey(public))) : public;
    return _answer(_success(), output);
  }

  _Outcome _signKeyId(MailCall call, MailApp app, MailKeys keys) {
    final given = call.extras['sign_key_id'];
    if (given is int && given != 0) {
      // The picker would hand the same ID back
      if (keys.sharesId(given)) return _answer(_sharedId());
      final own = keys.ownById(given);
      if (own != null && app.keys.contains(own.key.id) && own.canSignAt(keys.now)) {
        return _answer(_success({'sign_key_id': own.keyId, 'primary_user_id': ?own.userId}));
      }
    }
    final userId = call.extras['user_id'];
    final preselect = call.extras['preselect_key_id'];
    return _ask(
      PickKeyStep(address: userId is String ? mailAddress(userId) : null, preselect: preselect is int && preselect != 0 ? preselect : null),
    );
  }

  // ─── Signing and encrypting ───────────────────────────────────────────────

  bool _needsPassphrase(MailOwnKey? key) =>
      key != null && (key.key.protected ?? key.info.protected) && _ref.read(mailKeyCacheProvider).openedOf(key.key) == null;

  /// The key a job signs or decrypts with: the opened form when mail opened it.
  PgpJobKey _jobKey(MailOwnKey key) => PgpJobKey(_ref.read(mailKeyCacheProvider).openedOf(key.key) ?? unb64(key.key.privateKey));

  /// The own key [call] names to sign with, checked for [app]; or what
  /// stops it.
  ({MailOwnKey? key, _Outcome? stop}) _signer(MailCall call, MailApp app, MailKeys keys) {
    final keyId = call.extras['sign_key_id'];
    if (keyId is! int || keyId == 0) return (key: null, stop: _ask(const PickKeyStep()));
    if (keys.sharesId(keyId)) return (key: null, stop: _answer(_sharedId()));
    final own = keys.ownById(keyId);
    if (own == null) return (key: null, stop: _answer(_noKey()));
    if (own.onCard) return (key: null, stop: _answer(_onCard()));
    if (!app.keys.contains(own.key.id)) return (key: null, stop: _ask(AddKeyStep(own.key.id)));
    if (!own.canSignAt(keys.now)) return (key: null, stop: _answer(_error(OpenPgp.genericError, _messages.t('pgp.error.keyUnusable'))));
    if (_needsPassphrase(own)) return (key: null, stop: _ask(PassphraseStep(own.key.id)));
    return (key: own, stop: null);
  }

  Future<_Outcome> _sign(MailCall call, MailApp app, MailKeys keys, {required bool dry, required bool detached}) async {
    final signer = _signer(call, app, keys);
    if (signer.stop != null) return signer.stop!;
    if (dry) return _workLeft;
    final armor = _armor(call);
    final form = !detached
        ? pgp.PgpSignatureForm.cleartext
        : armor
        ? pgp.PgpSignatureForm.detachedArmored
        : pgp.PgpSignatureForm.detached;
    final outcome = await _run(SignRequest(now: keys.now, text: call.input ?? Uint8List(0), signer: _jobKey(signer.key!), form: form));
    if (outcome is! PgpSignedOutcome) return _answer(_failure(outcome));
    if (!detached) return _answer(_success(), outcome.bytes);
    return _answer(_success({'detached_signature': outcome.bytes, 'signature_micalg': pgp.pgpMicalg(outcome.bytes)}));
  }

  Future<_Outcome> _encrypt(MailCall call, MailApp app, MailKeys keys, {required bool dry, required bool signed}) async {
    final recipients = <Uint8List>[];
    final seen = <String>{};
    final unchecked = <MailContactKey>[];
    // A key named by its ID needs its fingerprint checked; one found by an address, a check that covers the address
    void addContact(MailContactKey k, {String? address}) {
      final confirmed = address == null ? k.checked : k.confirms(address);
      if (!confirmed && !app.unchecked.contains(k.fingerprint) && !unchecked.contains(k)) unchecked.add(k);
      if (seen.add(k.fingerprint)) recipients.add(k.publicKey);
    }

    void addOwn(MailOwnKey k) {
      if (seen.add(k.fingerprint)) recipients.add(k.publicKey);
    }

    for (final keyId in _longs(call.extras['key_ids'])) {
      if (keys.sharesId(keyId)) return _answer(_sharedId());
      final own = keys.ownById(keyId);
      final contact = own == null ? keys.contactById(keyId) : null;
      if (own != null && own.canEncryptAt(keys.now)) {
        addOwn(own);
      } else if (contact != null && contact.canEncrypt) {
        addContact(contact);
      } else {
        // A key Kemlock never held, another vault's among them, or one that may not be encrypted to
        return _answer(own == null && contact == null ? _noKey() : _error(OpenPgp.genericError, _messages.t('pgp.error.keyUnusable')));
      }
    }
    final missing = <String>[];
    for (final userId in _strings(call.extras['user_ids'])) {
      final address = mailAddress(userId) ?? userId.trim();
      final found = keys.recipientsFor(address.toLowerCase());
      if (found.own.isEmpty && found.contacts.isEmpty) {
        missing.add(address);
        continue;
      }
      found.own.forEach(addOwn);
      for (final k in found.contacts) {
        addContact(k, address: address.toLowerCase());
      }
    }
    if (missing.isNotEmpty) {
      if (call.extras['opportunistic'] == true) {
        return _answer(_error(OpenPgp.opportunisticMissingKeys, _messages.t('mail.error.missingKeys', {'addresses': missing.join(', ')})));
      }
      return _ask(MissingKeysStep(missing));
    }
    if (recipients.isEmpty) return _answer(_error(OpenPgp.noUserIds, _messages.t('mail.error.noRecipient')));
    if (unchecked.isNotEmpty) return _ask(UncheckedStep([for (final k in unchecked) k.contact.id]));
    MailOwnKey? signer;
    if (signed) {
      final found = _signer(call, app, keys);
      if (found.stop != null) return found.stop!;
      signer = found.key;
    }
    if (dry) return _workLeft;
    final outcome = await _run(
      EncryptRequest(
        now: keys.now,
        text: call.input ?? Uint8List(0),
        recipients: recipients,
        signer: signer == null ? null : _jobKey(signer),
        binary: !_armor(call),
      ),
    );
    if (outcome is! PgpEncryptedOutcome) return _answer(_failure(outcome));
    return _answer(_success(), outcome.armored);
  }

  // ─── Decrypting and verifying ─────────────────────────────────────────────

  Future<_Outcome> _decrypt(MailCall call, MailApp app, MailKeys keys, {required bool dry}) async {
    // Which key a message needs shows only in the message
    if (dry) return _workLeft;
    final input = call.input ?? Uint8List(0);
    final detached = call.extras['detached_signature'];
    if (detached is Uint8List) {
      final outcome = await _run(VerifyRequest(now: keys.now, text: input, signature: detached, verifiers: keys.verifiers));
      if (outcome is! PgpVerifiedOutcome) return _answer(_failure(outcome));
      return _answer(
        _success({
          'signature': _signatureResult(outcome.verified.signatures, call, keys),
          'decryption': {'result': OpenPgp.notEncrypted},
        }),
      );
    }
    final pgp.PgpMessageInfo info;
    try {
      info = pgp.inspectMessage(pgp.PgpData.bytes(input));
    } on pgp.PgpException catch (e) {
      return _answer(_failure(PgpFailedOutcome(e)));
    }
    final jobKeys = <PgpJobKey>[];
    if (info.kind == pgp.PgpMessageKind.encrypted) {
      final named = {...info.recipientKeyIds};
      final mine = [
        for (final k in keys.own)
          if (!k.onCard && (info.hiddenRecipients > 0 || k.allKeyIdsHex.any(named.contains))) k,
      ];
      final allowed = [
        for (final k in mine)
          if (app.keys.contains(k.key.id)) k,
      ];
      if (allowed.isEmpty) {
        // The vault holds a key for it the app may not use: asked; else as any key never held
        final held = mine.where((k) => k.allKeyIdsHex.any(named.contains)).firstOrNull;
        if (held != null) return _ask(AddKeyStep(held.key.id));
        final onCard = keys.own.any((k) => k.onCard && k.allKeyIdsHex.any(named.contains));
        return _answer(onCard ? _onCard() : _noKey());
      }
      final locked = allowed.where(_needsPassphrase).firstOrNull;
      if (locked != null && allowed.every(_needsPassphrase)) return _ask(PassphraseStep(locked.key.id));
      jobKeys.addAll([
        for (final k in allowed)
          if (!_needsPassphrase(k)) _jobKey(k),
      ]);
    } else if (info.kind case pgp.PgpMessageKind.publicKey || pgp.PgpMessageKind.secretKey || pgp.PgpMessageKind.detachedSignature) {
      return _answer(_failure(const PgpFailedOutcome(pgp.PgpException(pgp.PgpProblem.notAMessage))));
    }
    final outcome = await _run(
      DecryptRequest(
        now: keys.now,
        text: input,
        outputDirectory: null,
        maxInMemory: maxMailInput,
        keys: jobKeys,
        verifiers: keys.verifiers,
      ),
    );
    if (outcome is! PgpDecryptedOutcome) {
      if (outcome case PgpFailedOutcome(:final error) when error.problem == pgp.PgpProblem.noKeyOpensIt) return _answer(_noKey());
      return _answer(_failure(outcome));
    }
    final message = outcome.message;
    final bytes = message.bytes ?? Uint8List(0);
    return _answer(
      _success({
        'signature': _signatureResult(message.signatures, call, keys),
        // No session key: handing it to a mail app to keep is more than it was approved for
        'decryption': {'result': message.encrypted ? OpenPgp.encrypted : OpenPgp.notEncrypted},
        'metadata': {
          'filename': message.fileName,
          'mime_type': message.isText ? 'text/plain' : 'application/octet-stream',
          'modification_time': 0,
          'original_size': message.length,
        },
      }),
      bytes,
    );
  }

  /// The `OpenPgpSignatureResult` of a message's [signatures]: the first
  /// good one, or else the first (decision 9).
  ///
  /// A checked contact is confirmed as the addresses its check covers and
  /// no other: its owner may have put anyone's address in the key since,
  /// so a user ID with another is not among `confirmed_user_ids`, and a
  /// sender with another is `unconfirmed`, as an unchecked key's would be.
  Map<String, Object?> _signatureResult(List<pgp.SignatureResult> signatures, MailCall call, MailKeys keys) {
    if (signatures.isEmpty) return {'result': OpenPgp.noSignature};
    final signature = signatures.firstWhereOrNull((s) => s.verdict == pgp.SignatureVerdict.good) ?? signatures.first;
    final fingerprint = signature.signerFingerprint;
    final own = fingerprint == null ? null : keys.own.firstWhereOrNull((k) => k.fingerprint == fingerprint);
    final contact = fingerprint == null || own != null ? null : keys.contacts.firstWhereOrNull((k) => k.fingerprint == fingerprint);
    final info = own?.info ?? contact?.info;
    final sender = call.extras['sender_address'];
    final address = sender is String ? mailAddress(sender) : null;
    final userIds = info?.userIds ?? const <String>[];
    final senderOnKey = address != null && userIds.any((u) => mailAddress(u) == address);
    // An own key is confirmed as each of its user IDs, a checked contact as those of the addresses its check covers
    final keyChecked = own != null || (contact?.checked ?? false);
    bool confirms(String userId) => own != null || (contact != null && contact.confirms(mailAddress(userId) ?? ''));
    // A sender on the key that the check does not cover is not confirmed
    final checked = keyChecked && (address == null || !senderOnKey || own != null || (contact?.confirms(address) ?? false));
    final issuer = signature.issuer;
    final keyId = info != null
        ? mailKeyId(info.primary)
        : issuer != null && issuer.length >= 16
        ? mailKeyIdOfHex(issuer.substring(issuer.length - 16))
        : 0;
    final result = switch (signature.verdict) {
      pgp.SignatureVerdict.good when signature.keyRevoked => OpenPgp.invalidKeyRevoked,
      // Expired when it was made, or since: OpenKeychain says so of a key expired now
      pgp.SignatureVerdict.good when signature.keyExpired || signature.keyExpiredSince => OpenPgp.invalidKeyExpired,
      pgp.SignatureVerdict.good when info == null => OpenPgp.keyMissing,
      pgp.SignatureVerdict.good => checked ? OpenPgp.validKeyConfirmed : OpenPgp.validKeyUnconfirmed,
      pgp.SignatureVerdict.bad => OpenPgp.invalidSignature,
      pgp.SignatureVerdict.weakHash || pgp.SignatureVerdict.weakKey => OpenPgp.invalidKeyInsecure,
      pgp.SignatureVerdict.unknownSigner || pgp.SignatureVerdict.unsupported => OpenPgp.keyMissing,
    };
    if (info == null || result == OpenPgp.keyMissing || result == OpenPgp.invalidSignature) {
      return {'result': result, 'key_id': keyId, 'timestamp': ?signature.made?.millisecondsSinceEpoch};
    }
    final String senderStatus;
    if (address == null) {
      senderStatus = 'unknown';
    } else if (!senderOnKey) {
      senderStatus = 'missing';
    } else {
      senderStatus = checked ? 'confirmed' : 'unconfirmed';
    }
    return {
      'result': result,
      'key_id': keyId,
      'primary_user_id': ?userIds.firstOrNull,
      'user_ids': userIds,
      // Never null: FairEmail reads it of a good signature
      'confirmed_user_ids': keyChecked
          ? [
              for (final u in userIds)
                if (confirms(u)) u,
            ]
          : const <String>[],
      'sender_status': senderStatus,
      'timestamp': ?signature.made?.millisecondsSinceEpoch,
    };
  }

  // ─── Jobs ─────────────────────────────────────────────────────────────────

  /// Runs [request] in a job, holding no auto-lock: a mail request is not
  /// the person using Kemlock (decision 7). Nobody is there to cancel it,
  /// so one that runs past [mailJobTimeout] is stopped.
  Future<PgpOutcome> _run(PgpRequest request) => outcomeWithin(_ref.read(pgpJobStarterProvider)(request), mailJobTimeout);

  Map<String, Object?> _failure(PgpOutcome outcome) => switch (outcome) {
    PgpFailedOutcome(:final error) when error.problem == pgp.PgpProblem.tooLarge => _error(
      OpenPgp.genericError,
      _messages.t('mail.error.tooLarge'),
    ),
    PgpFailedOutcome(:final error) when identical(error, mailJobTimedOut.error) => _error(
      OpenPgp.genericError,
      _messages.t('mail.error.timeout'),
    ),
    PgpFailedOutcome(:final error) => _error(OpenPgp.genericError, pgpErrorText(_messages, error)),
    _ => _error(OpenPgp.genericError, _messages.t('mail.error.cancelled')),
  };
}

final mailHandlerProvider = Provider<MailHandler>(MailHandler.new);
