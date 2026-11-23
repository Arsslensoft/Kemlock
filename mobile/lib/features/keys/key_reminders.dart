/// The notifications before a PGP key expires (openspec:
/// add-key-expiry-warnings): which ones a vault's keys call for, and keeping
/// the phone's scheduled notifications equal to them.
///
/// A vault's contents can be read only while it is open, so everything that
/// must happen on a locked phone is scheduled beforehand: on every unlock
/// and every change to the keys. A notification names no key, user ID,
/// address or vault, and a hidden vault gets none at all, since one on the
/// lock screen would show that the vault exists.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/storage/key_value_store.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/reminders.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';
import '../settings/prefs.dart';
import 'key_standing.dart';

/// How many days before a key's expiry it is announced; 0 is the day itself.
const reminderDaysBefore = [30, 7, 1, 0];

/// The hour of the day, on the phone's clock, a reminder is shown at.
const reminderHour = 9;

/// iOS keeps 64 pending notifications per app; the soonest this many are
/// scheduled and the next unlock fills in the rest.
const maxPendingReminders = 60;

/// One notification a vault's keys call for: at [when], 09:00 on its day,
/// saying that [count] keys expire in [daysLeft] days.
typedef WantedReminder = ({DateTime when, int daysLeft, int count});

/// The reminders the keys of [standings] call for after [now]: for each key
/// with an expiry ahead, 30, 7 and 1 days before its last day and on that
/// day, at 09:00, leaving out those whose time has passed. Keys due on the
/// same day share one notification, which counts them. A key that expired
/// or was revoked calls for none. At most [limit], the soonest.
///
/// Days are those of the calendar [now] is on: the phone's time zone for a
/// local time, UTC for a UTC one.
///
/// When keys with different days left fall on one morning (one a week from
/// its expiry, another a day from it), the notification speaks for those
/// nearest their expiry; the others have their own later mornings.
List<WantedReminder> wantedReminders(Iterable<KeyStanding> standings, DateTime now, {int limit = maxPendingReminders}) {
  DateTime morning(DateTime day, int daysBefore) => now.isUtc
      ? DateTime.utc(day.year, day.month, day.day - daysBefore, reminderHour)
      : DateTime(day.year, day.month, day.day - daysBefore, reminderHour);

  // Morning -> days left -> how many keys
  final byMorning = <DateTime, Map<int, int>>{};
  for (final standing in standings) {
    final expires = standing.expires;
    if (expires == null || standing.standing.isOver || !now.isBefore(expires)) continue;
    final lastDay = now.isUtc ? expires.toUtc() : expires.toLocal();
    for (final daysBefore in reminderDaysBefore) {
      final when = morning(lastDay, daysBefore);
      if (!when.isAfter(now)) continue;
      final counts = byMorning.putIfAbsent(when, () => {});
      counts[daysBefore] = (counts[daysBefore] ?? 0) + 1;
    }
  }
  final wanted = [
    for (final MapEntry(key: morningOf, value: counts) in byMorning.entries)
      () {
        final nearest = counts.keys.reduce((a, b) => a < b ? a : b);
        return (when: morningOf, daysLeft: nearest, count: counts[nearest]!);
      }(),
  ]..sort((a, b) => a.when.compareTo(b.when));
  return wanted.length > limit ? wanted.sublist(0, limit) : wanted;
}

/// The title of every key reminder. It is fixed, and names nothing.
String reminderTitle(Messages messages) => messages.t('reminders.key.title');

/// What a reminder says: how many keys expire, and when. Nothing else.
String reminderBody(Messages messages, WantedReminder reminder) => messages.t(
  switch (reminder.daysLeft) {
    0 => 'reminders.key.today',
    1 => 'reminders.key.tomorrow',
    7 => 'reminders.key.in7',
    _ => 'reminders.key.in30',
  },
  {'count': reminder.count},
);

/// The id of a vault's notification on the morning of [when]: a stable
/// 31-bit hash (FNV-1a) of the vault's id and the date. It says which vault
/// and which day, never which key.
int reminderId(String vaultId, DateTime when) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode('$vaultId|${_date(when)}')) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

String _date(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}';

/// Keeps the phone's scheduled notifications equal to what the keys call
/// for.
///
/// What each listed vault has scheduled is kept in the app's own storage
/// under [keyKeyReminders], as notification ids with the date, days left
/// and count each was scheduled for: enough to cancel a vault's
/// notifications while another vault is open, and to leave alone the ones
/// that are already right. It holds no key and no name, and a hidden vault
/// never reaches it.
class KeyReminders {
  KeyReminders(this._ref);

  final Ref _ref;
  Future<void> _tail = Future.value();

  Reminders get _reminders => _ref.read(remindersProvider);
  KeyValueStore get _store => _ref.read(keyValueStoreProvider);
  VaultRegistry get _vaults => _ref.read(vaultRegistryProvider);

  /// One change at a time, in the order asked: each reads what the last wrote.
  Future<void> _queued(Future<void> Function() work) {
    final run = _tail.then((_) => work());
    // A phone that refuses a call must not stop the next one
    _tail = run.catchError((Object _) {});
    return _tail;
  }

  Map<String, Map<String, String>> _read() {
    try {
      final parsed = jsonDecode(_store.getItem(keyKeyReminders) ?? '{}');
      if (parsed is! Map<String, Object?>) return {};
      return {
        for (final MapEntry(key: vault, value: ids) in parsed.entries)
          if (ids is Map<String, Object?>)
            vault: {
              for (final MapEntry(key: id, value: what) in ids.entries)
                if (what is String && int.tryParse(id) != null) id: what,
            },
      };
    } on FormatException {
      return {};
    }
  }

  void _write(Map<String, Map<String, String>> all) {
    all.removeWhere((_, ids) => ids.isEmpty);
    if (all.isEmpty) {
      if (_store.getItem(keyKeyReminders) != null) _store.removeItem(keyKeyReminders);
    } else {
      _store.setItem(keyKeyReminders, jsonEncode(all));
    }
  }

  /// Makes the scheduled notifications of [vault], the open vault, match
  /// its [keys]: cancels those no longer called for and schedules the
  /// missing ones, leaving the rest alone. With reminders off it cancels
  /// all of the vault's. A hidden vault is left out here, where the vault is
  /// known, so no caller can forget it: nothing is scheduled for it, and
  /// whatever it had scheduled while it was listed is taken back.
  Future<void> sync(VaultInfo vault, List<VaultKey> keys) => _queued(() async {
    if (vault.hidden || !_vaults.isListed(vault.id)) return _cancelVault(vault.id);
    final prefs = Prefs.parse(_store.getItem(_vaults.vaultKey(prefsKey, vault.id)));
    if (!prefs.keyReminders) return _cancelVault(vault.id);

    final now = _ref.read(clockProvider)();
    final all = _read();
    final mine = all[vault.id] ?? const <String, String>{};
    // Room is shared with the other vaults' notifications
    final others = all.entries.where((entry) => entry.key != vault.id).fold(0, (sum, entry) => sum + entry.value.length);
    final limit = (maxPendingReminders - others).clamp(0, maxPendingReminders);
    final wanted = wantedReminders([for (final key in keys) ?_standingOf(key, now)], now, limit: limit);

    final messages = _ref.read(messagesProvider);
    final pending = await _reminders.pending();
    final next = <String, String>{};
    for (final reminder in wanted) {
      final id = reminderId(vault.id, reminder.when);
      // What it was scheduled to say, so a change of count or language schedules it again
      final what = '${_date(reminder.when)} ${reminder.daysLeft} ${reminder.count} ${messages.locale.name}';
      next['$id'] = what;
      if (mine['$id'] == what && pending.contains(id)) continue;
      await _reminders.schedule(id: id, when: reminder.when, title: reminderTitle(messages), body: reminderBody(messages, reminder));
    }
    for (final id in mine.keys) {
      if (!next.containsKey(id)) await _reminders.cancel(int.parse(id));
    }
    _write({...all, vault.id: next});
  });

  /// The same for the vault that is open now; nothing while none is.
  Future<void> syncOpenVault() {
    final state = _ref.read(vaultControllerProvider);
    return state.isUnlocked ? sync(state.vault, state.keys) : Future.value();
  }

  KeyStanding? _standingOf(VaultKey key, DateTime now) {
    final public = key.publicKey;
    if (key.kind != KeyKind.pgp || public == null) return null;
    try {
      return keyStanding(_ref.read(pgpKeyInfoReaderProvider)(unb64(public)), now);
    } on crypto.KeyFormatException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _cancelVault(String id) async {
    final all = _read();
    final mine = all.remove(id);
    if (mine == null) return;
    for (final scheduled in mine.keys) {
      await _reminders.cancel(int.parse(scheduled));
    }
    _write(all);
  }

  /// Takes back every notification scheduled for the vault [id], whichever
  /// vault is open: when it is deleted.
  Future<void> cancelVault(String id) => _queued(() => _cancelVault(id));

  /// Takes back every key reminder on the phone: when every vault is
  /// erased. The app schedules no other notification, so whatever is
  /// pending goes, with or without the record of it, which the erasing has
  /// already removed.
  Future<void> cancelAll() => _queued(() async {
    final ids = {
      for (final vault in _read().values)
        for (final id in vault.keys) int.parse(id),
      ...await _reminders.pending(),
    };
    for (final id in ids) {
      await _reminders.cancel(id);
    }
    _write({});
  });
}

final keyRemindersProvider = Provider<KeyReminders>(KeyReminders.new);

/// Turns the open vault's key reminders on, after asking the phone for
/// permission to notify: false, with nothing changed, when it is refused.
/// Either way the Vault tab's offer is not made again.
Future<bool> turnKeyRemindersOn(WidgetRef ref) async {
  final prefs = ref.read(prefsProvider.notifier);
  final reminders = ref.read(keyRemindersProvider);
  final granted = await ref.read(remindersProvider).requestPermission();
  prefs.update((prefs) => prefs.copyWith(keyReminders: granted ? true : null, keyRemindersOffered: true));
  if (granted) await reminders.syncOpenVault();
  return granted;
}

/// Turns the open vault's key reminders off, and takes back what it had scheduled.
Future<void> turnKeyRemindersOff(WidgetRef ref) async {
  final reminders = ref.read(keyRemindersProvider);
  ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(keyReminders: false));
  await reminders.syncOpenVault();
}

/// Whether the Vault tab offers key reminders: once, when the open vault
/// holds a PGP key with an expiry ahead, reminders are off and were never
/// offered. Never while a hidden vault is open, which gets none; that is
/// decided here, with [KeyReminders.sync], and not in the screens.
bool offersKeyReminders({required VaultInfo vault, required bool listed, required Prefs prefs, required Iterable<KeyStanding> standings}) =>
    !vault.hidden &&
    listed &&
    !prefs.keyReminders &&
    !prefs.keyRemindersOffered &&
    standings.any((standing) => standing.expires != null && !standing.standing.isOver && standing.daysLeft != null);
