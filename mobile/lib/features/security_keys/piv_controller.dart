/// The state behind the Certificates sheet and the sheets it opens: what
/// was read from the key's PIV application, running an action on it in
/// one session, finding the management key (openspec: add-piv-management,
/// design decision 9), and the vault notes that keep one (decision 10).
/// Nothing here is stored; the state lives as long as the Security key
/// sheet.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/keys/algorithms.dart' show EcPublicHalf, PublicHalf, RawPublicHalf, RsaPublicHalf;
import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/piv/piv_commands.dart';
import '../../security_key/piv/piv_data.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../security_key/piv/piv_session.dart';
import '../../vault/vault_controller.dart';
import 'security_key_controller.dart';

/// The notes of the open vault, where a management key is kept and found
/// again. Tests of the sheets alone put their own in its place.
abstract interface class PivNotes {
  List<SecureNote> get notes;

  /// Saves [note] in the open vault; false when it could not be saved.
  Future<bool> add(SecureNote note);
  Future<bool> update(SecureNote note);
  Future<void> delete(SecureNote note);
}

class _VaultNotes implements PivNotes {
  _VaultNotes(this._ref);

  final Ref _ref;

  VaultController get _vault => _ref.read(vaultControllerProvider.notifier);

  @override
  List<SecureNote> get notes => _ref.read(vaultControllerProvider).notes;

  @override
  Future<bool> add(SecureNote note) => _vault.addNote(note);

  @override
  Future<bool> update(SecureNote note) => _vault.updateNote(note);

  @override
  Future<void> delete(SecureNote note) => _vault.deleteNote(note);
}

final pivNotesProvider = Provider<PivNotes>(_VaultNotes.new);

/// The newest note of [notes] that keeps the management key of the
/// security key named [keyId], or null.
SecureNote? pivNoteFor(List<SecureNote> notes, String? keyId) {
  if (keyId == null) return null;
  final found = [
    for (final note in notes)
      if (note.piv?.key == keyId) note,
  ]..sort((a, b) => b.changedAt.compareTo(a.changedAt));
  return found.firstOrNull;
}

/// Where the management key an operation used came from.
sealed class PivKeySource {
  const PivKeySource();
}

/// The published one the key still has.
class PivFactoryKey extends PivKeySource {
  const PivFactoryKey();
}

/// The one a note of the open vault keeps for this key.
class PivVaultKey extends PivKeySource {
  const PivVaultKey(this.note);

  final SecureNote note;
}

/// The one the person typed or pasted.
class PivTypedKey extends PivKeySource {
  const PivTypedKey(this.key);

  final Uint8List key;
}

/// The key refused the management key of the vault's note: it no longer
/// matches.
class PivVaultKeyRefused implements Exception {
  const PivVaultKeyRefused();
}

/// The key presented is not the one the sheet shows: nothing was sent to
/// it but the reads.
class PivOtherKey implements Exception {
  const PivOtherKey();
}

/// The management key Kemlock can use on the key [state] describes
/// without asking: the factory one if the key still has it, else the one
/// in a note of [notes] for it. Null when it has to be typed.
PivKeySource? pivKnownKey(PivState state, List<SecureNote> notes, {bool skipFactory = false, bool skipNote = false}) {
  if (state.factoryManagementKey == true && !skipFactory) return const PivFactoryKey();
  if (skipNote) return null;
  final note = pivNoteFor(notes, state.keyId);
  return note == null ? null : PivVaultKey(note);
}

/// Proves the management key of [source] to the card of [session].
/// Throws [PivVaultKeyRefused] when the card refuses a note's key, and
/// [PivManagementKeyRefused] when it refuses any other.
Future<void> pivProve(PivSession session, PivKeySource source) async {
  switch (source) {
    case PivFactoryKey():
      await pivAuthenticate(session, pivFactoryManagementKey);
    case PivTypedKey(:final key):
      await pivAuthenticate(session, key);
    case PivVaultKey(:final note):
      final piv = note.piv!;
      final key = parsePivManagementKey(piv.managementKey);
      if (key == null) throw const PivVaultKeyRefused();
      try {
        await pivAuthenticate(session, key, type: PivManagementKeyType.byName(piv.algorithm));
      } on PivManagementKeyRefused {
        throw const PivVaultKeyRefused();
      }
  }
}

/// Whether [now] was read from the key [shown] was read from. A key with
/// an identifier ([PivState.keyId]) is told by it, and one that has lost
/// it, or never had one, is another; two keys without one are told by
/// what every key gives: the firmware version, and what each slot holds,
/// its certificate and the public key the card reports. Two keys of one
/// firmware with no identifier and the same slots, as two blank ones,
/// cannot be told apart.
bool pivSameKey(PivState shown, PivState now) {
  final id = shown.keyId;
  if (id != null || now.keyId != null) return id == now.keyId;
  if (shown.version != now.version) return false;
  for (final slot in PivSlot.values) {
    final (before, after) = (shown.slots[slot], now.slots[slot]);
    if (before?.status != after?.status) return false;
    if (!_sameBytes(before?.certificate, after?.certificate)) return false;
    if (!_samePublic(before?.publicKey, after?.publicKey)) return false;
  }
  return true;
}

bool _sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _samePublic(PublicHalf? a, PublicHalf? b) => switch ((a, b)) {
  (null, null) => true,
  (RsaPublicHalf(n: final n1, e: final e1), RsaPublicHalf(n: final n2, e: final e2)) => n1 == n2 && e1 == e2,
  (EcPublicHalf(curve: final c1, point: final p1), EcPublicHalf(curve: final c2, point: final p2)) => c1 == c2 && _sameBytes(p1, p2),
  (RawPublicHalf(algorithm: final a1, bytes: final b1), RawPublicHalf(algorithm: final a2, bytes: final b2)) =>
    a1 == a2 && _sameBytes(b1, b2),
  _ => false,
};

/// What the sheets know of a security key's PIV application, read in the
/// same connection as the rest of the Security key sheet, and the one
/// way they act on it.
class PivController extends ChangeNotifier {
  PivController._(this.keys) {
    keys.readers.add(_read);
    keys.addListener(_onKeys);
  }

  static final _controllers = Expando<PivController>('piv');

  /// The one for the Security key sheet of [keys], which reads the PIV
  /// application whenever the sheet reads the key. The sheet asks for it
  /// before it starts looking for a key.
  static PivController of(SecurityKeyController keys) => _controllers[keys] ??= PivController._(keys);

  final SecurityKeyController keys;

  PivState? _state;
  bool _absent = false;

  /// What was last read; null before the key was read, or when it has no
  /// PIV application.
  PivState? get state => _state;

  /// The key answered that it has no PIV application.
  bool get absent => _absent;

  bool get busy => keys.busy;

  void _onKeys() {
    // The key was forgotten, as when the vault locked: what was read of it goes too.
    if (keys.key == null && (_state != null || _absent)) {
      _state = null;
      _absent = false;
      notifyListeners();
    }
  }

  void _set(PivState? state, {bool absent = false}) {
    _state = state;
    _absent = absent;
    notifyListeners();
  }

  Future<void> _read(SecurityKeyConnection connection) async {
    try {
      final application = await connection.selectApplication(pivAid);
      final session = await PivSession.open(application.transmit);
      session.close();
      _set(session.state);
    } on SecurityKeyNoApplication {
      _set(null, absent: true);
    } on SecurityKeyNotDeclared {
      _set(null, absent: true);
    } on PivError {
      // An application that does not answer as PIV does is not shown.
      _set(null, absent: true);
    } on PivFormatException {
      _set(null, absent: true);
    }
  }

  /// Runs [action] in a PIV session on the key: the one connected, or the
  /// one the person presents next. The application is read afresh first,
  /// and again after [action], so the sheets show what the key holds; a
  /// key other than the one shown ([pivSameKey]) throws [PivOtherKey]
  /// before [action]. [shown] is what the person saw when they said yes,
  /// for an action confirmed first; without it, what was read last.
  Future<T> run<T>(Future<T> Function(PivSession session) action, {PivState? shown}) => keys.runOnConnection((connection) async {
    final expected = shown ?? _state;
    final PivSession session;
    try {
      session = await PivSession.open((await connection.selectApplication(pivAid)).transmit);
    } on SecurityKeyNoApplication {
      _set(null, absent: true);
      throw const PivOtherKey();
    }
    try {
      if (expected != null && !pivSameKey(expected, session.state)) {
        _set(session.state);
        throw const PivOtherKey();
      }
      _set(session.state);
      try {
        return await action(session);
      } finally {
        await _refresh(session);
      }
    } finally {
      session.close();
    }
  });

  Future<void> _refresh(PivSession session) async {
    try {
      _set(await session.refresh());
    } on Object {
      // The key left: it is read afresh on the next connection.
    }
  }

  /// Takes [state] as what the key now holds, as after a reset.
  void adopt(PivState state) => _set(state);
}

/// What [error], thrown while talking to a key's PIV application, is
/// said as. Null for a cancellation.
String? pivErrorText(BuildContext context, Object error) => switch (error) {
  SecurityKeyCancelled() => null,
  SecurityKeyRemoved() => context.t('securityKeys.error.removed'),
  SecurityKeyTimeout() => context.t('securityKeys.error.timeout'),
  SecurityKeyNfcOff() => context.t('securityKeys.error.nfcOff'),
  SecurityKeyUnavailable() => context.t('securityKeys.wait.none'),
  SecurityKeyDenied() => context.t('securityKeys.denied'),
  PivOtherKey() => context.t('piv.error.otherKey'),
  PivManagementKeyRefused() || PivVaultKeyRefused() => context.t('piv.error.managementKey'),
  PivBadSignature() => context.t('piv.error.badSignature'),
  PivKeyMismatch() => context.t('piv.import.mismatch'),
  PivNoRoom() => context.t('piv.error.noRoom'),
  PivBlocked() => context.t('piv.pin.blocked'),
  PivSecurityStatus() => context.t('piv.error.refused'),
  PivNotSupported() => context.t('piv.error.notSupported'),
  PivError() => context.t('piv.error.refused'),
  _ => context.t('securityKeys.error.failed'),
};

/// The sentence that says which management key an operation used.
String pivUsedText(BuildContext context, PivKeySource source) => switch (source) {
  PivFactoryKey() => context.t('piv.managementKey.used.factory'),
  PivVaultKey() => context.t('piv.managementKey.used.vault'),
  PivTypedKey() => context.t('piv.managementKey.used.typed'),
};

/// What people call [slot]: Sign-in, Signature, Encryption or Card.
String pivSlotName(BuildContext context, PivSlot slot) => switch (slot) {
  PivSlot.authentication => context.t('piv.slot.9a'),
  PivSlot.signature => context.t('piv.slot.9c'),
  PivSlot.keyManagement => context.t('piv.slot.9d'),
  PivSlot.cardAuthentication => context.t('piv.slot.9e'),
};

/// What the key in [slot] is used for, in a sentence.
String pivSlotPurpose(BuildContext context, PivSlot slot) => switch (slot) {
  PivSlot.authentication => context.t('piv.slot.9a.purpose'),
  PivSlot.signature => context.t('piv.slot.9c.purpose'),
  PivSlot.keyManagement => context.t('piv.slot.9d.purpose'),
  PivSlot.cardAuthentication => context.t('piv.slot.9e.purpose'),
};
