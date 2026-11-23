import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../core/storage/key_value_store.dart';
import '../../models/json.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';

/// The count of a listed vault, kept with its other keys.
const _keyFailures = 'backmycodes_unlock_failures';

/// Wrong master passwords typed on the lock screen for one slot since the
/// slot last opened, and when the last one was.
@immutable
class UnlockFailures {
  const UnlockFailures({this.count = 0, this.last});

  /// None since the last open.
  static const none = UnlockFailures();

  final int count;

  /// Epoch ms of the last wrong password, or null without one.
  final int? last;

  /// What [raw] holds; none for anything that isn't a count.
  factory UnlockFailures.parse(String? raw) {
    if (raw == null) return none;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return none;
      final count = asInt(json['count']) ?? 0;
      return UnlockFailures(count: count < 0 ? 0 : count, last: asInt(json['last']));
    } on FormatException {
      return none;
    }
  }

  Map<String, Object?> toJson() => {'count': count, 'last': ?last};

  @override
  bool operator ==(Object other) => other is UnlockFailures && other.count == count && other.last == last;

  @override
  int get hashCode => Object.hash(count, last);

  @override
  String toString() => 'UnlockFailures($count, last: $last)';
}

/// The counts of wrong master passwords (openspec: harden-unlock-and-clipboard,
/// unlock-attempts). The lock screen counts each try against its slot: the
/// listed vault it shows, under that vault's `backmycodes_unlock_failures`,
/// or, with no vault listed, the phone's, [keyUnlockFailuresDevice]. A
/// hidden vault never has one, so nothing in storage names it.
///
/// A try is written down, and reaches the phone's storage, before its
/// password is checked: killing the app during scrypt leaves it counted.
/// Every open from the lock screen resets the slot it was on, whichever
/// vault opened, so a hidden vault opening looks like the listed one opening.
///
/// The counts are in the clear, like the vault config. Whoever can write the
/// app's storage can reset them, and whoever can copy it guesses offline,
/// where no count reaches.
class UnlockAttempts {
  UnlockAttempts(this._store, this._vaults, this._now);

  final KeyValueStore _store;
  final VaultRegistry _vaults;
  final DateTime Function() _now;

  /// The key of [slot]'s count: a listed vault, or the phone when null.
  /// Null for a vault that isn't listed, which has no count.
  String? _key(String? slot) {
    if (slot == null) return keyUnlockFailuresDevice;
    return _vaults.isListed(slot) ? _vaults.vaultKey(_keyFailures, slot) : null;
  }

  /// [slot]'s wrong passwords since it last opened.
  UnlockFailures read(String? slot) {
    final key = _key(slot);
    return key == null ? UnlockFailures.none : UnlockFailures.parse(_store.getItem(key));
  }

  /// Counts a try on [slot], before its password is checked, once it is in
  /// the phone's storage. Returns the count from before it, which the lock
  /// screen keeps for [reset] should the password open a vault.
  Future<UnlockFailures> countTry(String? slot) async {
    final before = read(slot);
    final key = _key(slot);
    if (key == null) return before;
    _store.setItem(key, jsonEncode(UnlockFailures(count: before.count + 1, last: _now().millisecondsSinceEpoch).toJson()));
    await _store.flush();
    return before;
  }

  /// Sets [slot]'s count back to zero, as any open from the lock screen
  /// does. Returns the wrong passwords there were: [before] when the open
  /// was a counted try, else what was stored.
  UnlockFailures reset(String? slot, {UnlockFailures? before}) {
    final previous = before ?? read(slot);
    final key = _key(slot);
    if (key != null && _store.getItem(key) != null) _store.setItem(key, jsonEncode(UnlockFailures.none.toJson()));
    return previous;
  }

  /// Puts [slot]'s count back to [before], what it was before a try whose
  /// password turned out to be the right one of a vault that also needs its
  /// security key (openspec: add-security-key-unlock, decision 7): it was no
  /// wrong password, and the reset to zero waits for the vault to open.
  void restore(String? slot, UnlockFailures before) {
    final key = _key(slot);
    if (key != null && _store.getItem(key) != null) _store.setItem(key, jsonEncode(before.toJson()));
  }

  /// Sets every count the lock screen can show back to zero: each listed
  /// vault's and the phone's. Done when the erase is turned on or its number
  /// changed, by someone who has a vault open: an open resets only the count
  /// of the vault it was typed on, so the others can hold old wrong passwords,
  /// and with the erase off nothing limits them. Left there, a count already
  /// past the new number would erase every vault at the next lock, with no
  /// new wrong password.
  void resetAll() {
    for (final id in [..._vaults.listedVaultIds(), null]) {
      reset(id);
    }
  }

  /// The highest count of any slot the lock screen can show: each listed
  /// vault's and the phone's.
  int highestCount() => [
    for (final id in [..._vaults.listedVaultIds(), null]) read(id).count,
  ].fold(0, (a, b) => a > b ? a : b);
}

/// The wrong-password counts of this phone's lock screen.
final unlockAttemptsProvider = Provider<UnlockAttempts>(
  (ref) => UnlockAttempts(ref.watch(keyValueStoreProvider), ref.watch(vaultRegistryProvider), ref.watch(clockProvider)),
);

/// What the messages about [failures] take: the count, and when the last
/// one was, `today` at a time or on a date ([when]), in [locale]'s formats.
Map<String, Object?> failuresArgs(UnlockFailures failures, {required DateTime now, required String locale}) {
  final last = DateTime.fromMillisecondsSinceEpoch(failures.last ?? now.millisecondsSinceEpoch);
  final today = now.toLocal();
  final sameDay = last.year == today.year && last.month == today.month && last.day == today.day;
  return {
    'count': failures.count,
    'when': sameDay ? 'today' : 'earlier',
    'time': DateFormat.Hm(locale).format(last),
    'date': DateFormat.MMMd(locale).format(last),
  };
}

/// The numbers of wrong passwords in a row the erase can be set to.
const unlockEraseChoices = [10, 15, 20];

/// After how many wrong passwords in a row on one slot every vault on the
/// phone is erased, or null while that is off (openspec:
/// harden-unlock-and-clipboard, decision 9). It is the phone's, not a
/// vault's, since the erase takes every vault: erasing only the one on
/// screen would leave a lock screen that gives a hidden vault away.
int? readUnlockErase(KeyValueStore store) {
  try {
    final json = jsonDecode(store.getItem(keyUnlockErase) ?? '');
    final after = json is Map<String, Object?> ? asInt(json['after']) : null;
    return unlockEraseChoices.contains(after) ? after : null;
  } on FormatException {
    return null;
  }
}

/// Sets the erase to [after] wrong passwords, or turns it off with null.
void writeUnlockErase(KeyValueStore store, int? after) {
  if (after == null) {
    store.removeItem(keyUnlockErase);
  } else {
    store.setItem(keyUnlockErase, jsonEncode({'after': after}));
  }
}

/// The erase setting, read again whenever it is written.
final unlockEraseProvider = Provider<int?>((ref) {
  watchKeys(ref, [keyUnlockErase]);
  return readUnlockErase(ref.watch(keyValueStoreProvider));
});

/// When every vault on the phone was erased after wrong passwords, and
/// after how many, until a vault is made again.
typedef ErasedNote = ({DateTime at, int after});

/// The note the erase left in [store], or null.
ErasedNote? readErasedNote(KeyValueStore store) {
  try {
    final json = jsonDecode(store.getItem(keyErased) ?? '');
    if (json is! Map<String, Object?>) return null;
    final at = asInt(json['at']);
    final after = asInt(json['after']);
    return at == null || after == null ? null : (at: DateTime.fromMillisecondsSinceEpoch(at), after: after);
  } on FormatException {
    return null;
  }
}

/// The note that every vault was erased at [at], after [after] wrong
/// passwords, as [keyErased] keeps it: the erase leaves it
/// (`VaultStore.wipeVault`), even one finished at the next launch.
String erasedNoteValue({required DateTime at, required int after}) => jsonEncode({'at': at.millisecondsSinceEpoch, 'after': after});

/// The note an erase left, read again whenever it is written or deleted.
final erasedNoteProvider = Provider<ErasedNote?>((ref) {
  watchKeys(ref, [keyErased]);
  return readErasedNote(ref.watch(keyValueStoreProvider));
});
