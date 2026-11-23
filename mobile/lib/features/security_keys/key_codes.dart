/// Reading the codes of the accounts kept on a security key, and looking
/// after them there (openspec: add-security-key-codes). The secrets stay
/// on the key; a code read from it lives in memory, in [keyCodesProvider],
/// until its period ends or the vault locks.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/key_account.dart';
import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/oath/oath_messages.dart';
import '../../security_key/oath/oath_name.dart';
import '../../security_key/oath/oath_session.dart';
import '../../vault/vault_controller.dart';
import '../settings/auto_lock.dart';

/// Runs an action on a security key: on the one a screen holds connected,
/// or on the one the person presents next.
typedef KeyRunner = Future<T> Function<T>(Future<T> Function(SecurityKeyConnection connection) action);

/// A code read from a key, and the seconds (Unix time) it is valid for:
/// from [from] up to, not including, [until].
@immutable
class KeyCode {
  const KeyCode(this.code, this.from, this.until);

  final String code;
  final int from;
  final int until;
}

/// What the app is doing with a key right now.
enum KeyCodesActivity {
  idle,

  /// A key was asked for and none is there yet.
  waiting,

  /// Messages are going back and forth.
  working,

  /// The key waits to be touched.
  touch,
}

/// What a key's code application said of itself when it was last opened.
@immutable
class KeyCodesApp {
  const KeyCodesApp({required this.device, required this.password, required this.version});

  /// Its id, as [KeyAccount.device] keeps it.
  final String device;

  /// Whether it asks for a password.
  final bool password;

  /// The firmware version it gave.
  final OathVersion version;
}

/// The codes read from keys since the vault was opened. Nothing of it is stored.
@immutable
class KeyCodesState {
  const KeyCodesState({
    this.codes = const {},
    this.counterCodes = const {},
    this.readAt,
    this.activity = KeyCodesActivity.idle,
    this.plugged,
    this.apps = const {},
  });

  /// By the id of the key as the phone found it ([SecurityKeyDevice.id]):
  /// its code application as it last answered, or null when it has none
  /// Kemlock can read. A key not tried since the vault was opened is absent.
  final Map<String, KeyCodesApp?> apps;

  /// By [KeyAccount.id]: the codes read, the earliest first.
  final Map<String, List<KeyCode>> codes;

  /// By [KeyAccount.id]: the last code asked of a counter-based account,
  /// shown until the Codes tab is left or it is asked again.
  final Map<String, String> counterCodes;

  /// When a key was last read, in Unix seconds; null before any read
  /// since the vault was opened.
  final int? readAt;
  final KeyCodesActivity activity;

  /// The key ([KeyAccount.device]) that was read over a plug and is read
  /// again by itself while the Codes tab is open.
  final String? plugged;

  /// The code of the account [id] that is valid at [nowSec], if one was read.
  KeyCode? codeAt(String id, int nowSec) {
    for (final code in codes[id] ?? const <KeyCode>[]) {
      if (code.from <= nowSec && nowSec < code.until) return code;
    }
    return null;
  }

  /// The code that follows the one valid at [nowSec], if it was read too.
  KeyCode? nextAfter(String id, int nowSec) {
    for (final code in codes[id] ?? const <KeyCode>[]) {
      if (code.from > nowSec) return code;
    }
    return null;
  }

  KeyCodesState copyWith({
    Map<String, List<KeyCode>>? codes,
    Map<String, String>? counterCodes,
    int? readAt,
    KeyCodesActivity? activity,
    Object? plugged = _keep,
    Map<String, KeyCodesApp?>? apps,
  }) => KeyCodesState(
    codes: codes ?? this.codes,
    counterCodes: counterCodes ?? this.counterCodes,
    readAt: readAt ?? this.readAt,
    activity: activity ?? this.activity,
    plugged: identical(plugged, _keep) ? this.plugged : plugged as String?,
    apps: apps ?? this.apps,
  );
}

const _keep = Object();

/// Why an account cannot go to a key (openspec: add-security-key-codes,
/// decision 9). Each is found before anything is written.
enum KeyRefusal {
  /// Steam Guard: a key's code application has no such kind.
  steam,

  /// The account belongs to a shared space.
  space,

  /// `[period/]issuer:label` is over the key's 64 bytes.
  name,

  /// SHA-512 on a firmware before 4.3.1.
  algorithm,

  /// A touch asked for on a firmware before 4.2.4.
  touch,

  /// A secret, number of digits or algorithm the key cannot take.
  secret,
}

/// How an exchange with a key's code application ended.
enum KeyCodesOutcome {
  done,

  /// The person cancelled; nothing to say.
  cancelled,

  /// The application has a password and none was given or remembered.
  passwordNeeded,

  /// The password given is not the key's.
  wrongPassword,

  /// The key accepted the password and failed its own proof.
  untrustedKey,

  /// The key has no code application Kemlock can read.
  unsupported,

  /// The key left, or stopped answering, before the end.
  interrupted,

  /// The account waits for a touch that did not come.
  notTouched,

  /// The key presented is not the one the account is on.
  otherKey,

  /// The key has no room left; [KeyCodesResult.capacity] says how much it holds.
  full,

  /// The key no longer has the account.
  noSuchAccount,

  /// This phone cannot reach a key.
  unavailable,

  /// NFC is turned off.
  nfcOff,

  /// The account cannot go to this key; [KeyCodesResult.refusal] says why.
  refused,

  /// The key already holds an account of that name: the person is asked
  /// before it is replaced.
  exists,

  /// The key's code for an account just written did not match the vault's,
  /// and what was written was taken off the key again.
  mismatch,

  /// The key left after an account was written to it and before its code
  /// could be checked.
  unchecked,

  /// Anything else.
  failed,
}

@immutable
class KeyCodesResult {
  const KeyCodesResult(
    this.outcome, {
    this.device,
    this.rememberedRefused = false,
    this.code,
    this.capacity,
    this.partial = false,
    this.refusal,
    this.nameBytes,
    this.version,
  });

  final KeyCodesOutcome outcome;

  /// The key's id ([KeyAccount.device]), once it said it.
  final String? device;

  /// With [KeyCodesOutcome.passwordNeeded]: a remembered value was tried,
  /// refused by the key and dropped.
  final bool rememberedRefused;

  /// The code one account was asked for.
  final String? code;

  /// With [KeyCodesOutcome.full]: how many accounts a key of this firmware holds.
  final int? capacity;

  /// With [KeyCodesOutcome.interrupted]: the names were read before the
  /// key left, and are remembered; only the codes are missing.
  final bool partial;

  /// With [KeyCodesOutcome.refused]: why the account cannot go to the key.
  final KeyRefusal? refusal;

  /// With [KeyRefusal.name]: how many bytes the name would take on the key.
  final int? nameBytes;

  /// With [KeyRefusal.algorithm] and [KeyRefusal.touch]: the key's firmware.
  final OathVersion? version;

  bool get ok => outcome == KeyCodesOutcome.done;

  /// Whether the password must be typed (again) before trying once more.
  bool get asksPassword => outcome == KeyCodesOutcome.passwordNeeded || outcome == KeyCodesOutcome.wrongPassword;
}

/// Ends an exchange early with [result].
class KeyCodesStop implements Exception {
  const KeyCodesStop(this.result);

  final KeyCodesResult result;
}

/// The bytes [hex] spells.
Uint8List _unhex(String hex) =>
    Uint8List.fromList([for (var i = 0; i + 1 < hex.length; i += 2) int.tryParse(hex.substring(i, i + 2), radix: 16) ?? 0]);

/// What proves [password] to the key whose id is [device].
Uint8List keyAccessFor(String password, String device) => oathAccessKey(password, _unhex(device));

final keyCodesProvider = NotifierProvider<KeyCodesController, KeyCodesState>(KeyCodesController.new);

class KeyCodesController extends Notifier<KeyCodesState> {
  SecurityKeyHub? _hub;
  Timer? _repeat;
  bool _listening = false;
  int _running = 0;
  int _generation = 0;
  String? _pluggedId;

  @override
  KeyCodesState build() {
    // A locked vault, or another vault, has no codes: whatever was read is dropped.
    ref.watch(vaultControllerProvider.select((state) => (state.isUnlocked, state.vault.id)));
    _generation++;
    _repeat?.cancel();
    _repeat = null;
    _pluggedId = null;
    final hub = _hub;
    _hub = null;
    if (hub != null) unawaited(hub.cancel());
    ref.onDispose(() {
      _generation++;
      _repeat?.cancel();
    });
    return const KeyCodesState();
  }

  VaultController get _vault => ref.read(vaultControllerProvider.notifier);
  int get _nowSec => ref.read(clockProvider)().millisecondsSinceEpoch ~/ 1000;

  /// The one-off runner: waits for a key, runs, lets the key go.
  Future<T> _oneShot<T>(Future<T> Function(SecurityKeyConnection connection) action) {
    final messages = ref.read(messagesProvider);
    return runOnKey(
      ref.read(securityKeysProvider),
      action,
      nfcMessage: messages.t('securityKeys.nfc.hold'),
      nfcFailure: messages.t('securityKeys.nfc.failed'),
      hold: ref.read(autoLockHoldsProvider).hold,
      now: ref.read(clockProvider),
      onHub: (hub) {
        _hub = hub;
        final changed = hub.onChanged;
        hub.onChanged = () {
          changed?.call();
          if (identical(_hub, hub) && _running > 0) _setActivity(hub.isWaiting ? KeyCodesActivity.waiting : KeyCodesActivity.working);
        };
      },
    );
  }

  void _setActivity(KeyCodesActivity activity) {
    if (state.activity != activity) state = state.copyWith(activity: activity);
  }

  /// The person gives up waiting for a key, or stops the exchange.
  Future<void> cancel() async => _hub?.cancel();

  /// Proves the password when the application has one: with [accessKey]
  /// when given, else with what the vault remembers for this key. A
  /// remembered value the key refuses is dropped.
  Future<void> _unlock(OathSession oath, Uint8List? accessKey, bool remember) async {
    if (!oath.needsPassword) return;
    final device = oath.select.device;
    final remembered = accessKey == null ? await _vault.keyAccess(device) : null;
    final key = accessKey ?? remembered;
    if (key == null) throw KeyCodesStop(KeyCodesResult(KeyCodesOutcome.passwordNeeded, device: device));
    try {
      await oath.validate(key);
    } on OathError catch (error) {
      if (error.failure != OathFailure.wrongPassword) rethrow;
      if (remembered != null) {
        await _vault.forgetKeyAccess(device);
        throw KeyCodesStop(KeyCodesResult(KeyCodesOutcome.passwordNeeded, device: device, rememberedRefused: true));
      }
      throw KeyCodesStop(KeyCodesResult(KeyCodesOutcome.wrongPassword, device: device));
    }
    if (accessKey != null && remember) await _vault.rememberKeyAccess(device, accessKey);
  }

  /// Opens the code application of the key [runner] reaches (the next key
  /// presented, without one), proves its password, and runs [action].
  /// Every way it can end comes back as a [KeyCodesResult]; nothing is
  /// thrown. With [device], a key other than that one is refused before
  /// [action]. With [unlock] false the password is not asked for, as for
  /// erasing the application.
  Future<KeyCodesResult> onKey(
    Future<KeyCodesResult> Function(OathSession oath, SecurityKeyConnection connection) action, {
    KeyRunner? runner,
    Uint8List? accessKey,
    bool remember = false,
    String? device,
    bool unlock = true,
    bool touch = false,
  }) async {
    final generation = _generation;
    OathSelect? opened;
    String? seen() => opened?.device;
    String? plug;
    _running++;
    _setActivity(runner == null ? KeyCodesActivity.waiting : KeyCodesActivity.working);
    try {
      return await (runner ?? _oneShot)<KeyCodesResult>((connection) async {
        if (generation == _generation) _setActivity(KeyCodesActivity.working);
        plug = connection.device.id;
        final oath = await OathSession.open(connection);
        opened = oath.select;
        if (generation == _generation) _noteApp(connection.device.id, oath.select);
        if (device != null && device != seen()) return KeyCodesResult(KeyCodesOutcome.otherKey, device: seen());
        if (unlock) await _unlock(oath, accessKey, remember);
        if (touch && generation == _generation) _setActivity(KeyCodesActivity.touch);
        return action(oath, connection);
      });
    } on KeyCodesStop catch (stop) {
      return stop.result;
    } on SecurityKeyCancelled {
      return KeyCodesResult(KeyCodesOutcome.cancelled, device: seen());
    } on SecurityKeyNoApplication {
      _noteNoApp(generation, plug);
      return const KeyCodesResult(KeyCodesOutcome.unsupported);
    } on SecurityKeyNotDeclared {
      return const KeyCodesResult(KeyCodesOutcome.unsupported);
    } on SecurityKeyRemoved {
      return KeyCodesResult(KeyCodesOutcome.interrupted, device: seen());
    } on SecurityKeyTimeout {
      // A key that waits for a touch says nothing until it gives up; so may the link.
      return KeyCodesResult(touch ? KeyCodesOutcome.notTouched : KeyCodesOutcome.interrupted, device: seen());
    } on SecurityKeyUnavailable {
      return const KeyCodesResult(KeyCodesOutcome.unavailable);
    } on SecurityKeyNfcOff {
      return const KeyCodesResult(KeyCodesOutcome.nfcOff);
    } on OathError catch (error) {
      // An answer to the selection that does not parse: not the application Kemlock reads.
      if (opened == null && error.failure == OathFailure.malformed) _noteNoApp(generation, plug);
      return KeyCodesResult(
        switch (error.failure) {
          OathFailure.malformed => opened == null ? KeyCodesOutcome.unsupported : KeyCodesOutcome.failed,
          OathFailure.passwordNeeded => KeyCodesOutcome.passwordNeeded,
          OathFailure.wrongPassword => KeyCodesOutcome.wrongPassword,
          OathFailure.untrustedKey => KeyCodesOutcome.untrustedKey,
          OathFailure.notTouched => KeyCodesOutcome.notTouched,
          OathFailure.full => KeyCodesOutcome.full,
          OathFailure.noSuchAccount => KeyCodesOutcome.noSuchAccount,
          OathFailure.wrongSyntax || OathFailure.refused => KeyCodesOutcome.failed,
        },
        device: seen(),
        capacity: opened?.version.capacity,
      );
    } catch (_) {
      return KeyCodesResult(KeyCodesOutcome.failed, device: seen());
    } finally {
      _running--;
      if (generation == _generation && _running == 0) {
        _hub = null;
        _setActivity(KeyCodesActivity.idle);
      }
    }
  }

  /// Keeps what the code application of the key at [plug] said of itself.
  void _noteApp(String plug, OathSelect select) {
    final app = KeyCodesApp(device: select.device, password: select.hasPassword, version: select.version);
    final before = state.apps[plug];
    if (before != null && before.device == app.device && before.password == app.password && before.version == app.version) return;
    state = state.copyWith(apps: {...state.apps, plug: app});
  }

  void _noteNoApp(int generation, String? plug) {
    if (generation != _generation || plug == null || (state.apps.containsKey(plug) && state.apps[plug] == null)) return;
    state = state.copyWith(apps: {...state.apps, plug: null});
  }

  /// Looks whether the key on [connection] has a code application Kemlock
  /// reads, and notes what it said in [KeyCodesState.apps], so the
  /// Security key sheet's "Codes" row shows its count, or that it keeps no
  /// codes, before it is tapped. It only selects the application: nothing
  /// is listed, no password is asked for, and nothing goes wrong for the
  /// sheet's own read, so every error is let go.
  Future<void> peek(SecurityKeyConnection connection) async {
    final generation = _generation;
    final plug = connection.device.id;
    try {
      final oath = await OathSession.open(connection);
      if (generation == _generation) _noteApp(plug, oath.select);
    } on SecurityKeyNoApplication {
      _noteNoApp(generation, plug);
    } on OathError catch (error) {
      // An answer to the selection that does not parse: not the application Kemlock reads.
      if (error.failure == OathFailure.malformed) _noteNoApp(generation, plug);
    } catch (_) {
      // The key left or would not say: the row stays as it was, and a tap asks again.
    }
  }

  /// Reads the key: its accounts, and the codes of the current period and
  /// the next for every time-based account that needs no touch (decision
  /// 5). What the vault remembers of that key is then made equal to what
  /// it listed.
  ///
  /// A key that leaves while it lists changes nothing. One that leaves
  /// after the list still has its names remembered, with no codes, and
  /// the result says [KeyCodesResult.partial].
  Future<KeyCodesResult> read({KeyRunner? runner, Uint8List? accessKey, bool remember = false}) {
    final generation = _generation;
    return onKey(runner: runner, accessKey: accessKey, remember: remember, (oath, connection) async {
      final device = oath.select.device;
      final listed = await oath.list();
      final nowSec = _nowSec;
      final names = <String, OathListed>{};
      for (final entry in listed) {
        // A name that is not text cannot be remembered, nor shown.
        final String name;
        try {
          name = utf8.decode(entry.name);
        } on FormatException {
          continue;
        }
        if (!isHiddenOathName(name)) names[name] = entry;
      }

      final codes = <String, List<KeyCode>>{};
      Map<String, bool>? touch = {};
      var complete = false;
      try {
        final step = nowSec ~/ oathDefaultPeriod;
        for (final at in [step, step + 1]) {
          for (final entry in await oath.calculateAll(oathChallenge(at))) {
            final name = utf8.decode(entry.name, allowMalformed: true);
            if (!names.containsKey(name)) continue;
            touch[name] = entry.touch;
            final code = entry.code;
            if (code == null) continue;
            final period = parseOathName(name, timeBased: true).period;
            // The key worked this one out for a 30-second step it does not have: it is asked on its own below.
            if (period != oathDefaultPeriod) continue;
            (codes[name] ??= []).add(KeyCode(code.text, at * oathDefaultPeriod, (at + 1) * oathDefaultPeriod));
          }
        }
        for (final MapEntry(key: name, value: entry) in names.entries) {
          if (entry.type != OathType.totp || touch[name] == true) continue;
          final period = parseOathName(name, timeBased: true).period;
          if (period == oathDefaultPeriod) continue;
          final own = nowSec ~/ period;
          for (final at in [own, own + 1]) {
            final code = await oath.calculate(entry.name, oathChallenge(at));
            (codes[name] ??= []).add(KeyCode(code.text, at * period, (at + 1) * period));
          }
        }
        complete = true;
      } on SecurityKeyError {
        codes.clear();
        touch = null;
      } on OathError {
        codes.clear();
        touch = null;
      }

      if (generation != _generation) return KeyCodesResult(KeyCodesOutcome.cancelled, device: device);
      await _vault.reconcileKey(device, connection.device.productName, [
        for (final MapEntry(key: name, value: entry) in names.entries)
          KeyAccountSeen(
            name: name,
            type: entry.type == OathType.hotp ? KeyAccountType.hotp : KeyAccountType.totp,
            algorithm: entry.algorithm.label,
            touch: touch?[name],
          ),
      ]);
      if (generation != _generation) return KeyCodesResult(KeyCodesOutcome.cancelled, device: device);

      final remembered = ref.read(vaultControllerProvider).keyAccounts.where((account) => account.device == device).toList();
      final ids = {for (final account in remembered) account.id};
      final plugged = complete && !connection.isNfc;
      _pluggedId = plugged ? connection.device.id : null;
      state = state.copyWith(
        codes: {
          for (final MapEntry(key: id, :value) in state.codes.entries)
            if (!ids.contains(id)) id: value,
          for (final account in remembered) account.id: ?codes[account.name],
        },
        counterCodes: {
          for (final MapEntry(key: id, :value) in state.counterCodes.entries)
            if (!ids.contains(id) || remembered.any((account) => account.id == id)) id: value,
        },
        readAt: complete ? nowSec : null,
        plugged: plugged ? device : null,
      );
      if (plugged) _schedule(nowSec);
      if (!complete) return KeyCodesResult(KeyCodesOutcome.interrupted, device: device, partial: true);
      return KeyCodesResult(KeyCodesOutcome.done, device: device);
    });
  }

  /// The Codes tab came on screen, or left it. While it is there, a key
  /// that stays plugged in is read again by itself (decision 6). Leaving
  /// drops the counter codes that were asked for.
  void listening(bool on) {
    if (_listening == on) return;
    _listening = on;
    if (!on) {
      _repeat?.cancel();
      _repeat = null;
      if (!ref.mounted) return;
      if (state.counterCodes.isNotEmpty) state = state.copyWith(counterCodes: const {});
    } else if (state.plugged != null && state.readAt != null) {
      _schedule(state.readAt!);
    }
  }

  /// Reads the plugged-in key again when the second of the two periods
  /// read at [readAt] begins.
  void _schedule(int readAt) {
    _repeat?.cancel();
    _repeat = null;
    if (!_listening) return;
    final secondBegins = (readAt ~/ oathDefaultPeriod + 1) * oathDefaultPeriod;
    final wait = secondBegins - _nowSec;
    _repeat = Timer(Duration(seconds: wait < 0 ? 0 : wait), () => unawaited(_readAgain()));
  }

  Future<void> _readAgain() async {
    final id = _pluggedId;
    final device = state.plugged;
    if (!_listening || id == null || device == null || _running > 0) return;
    final generation = _generation;
    // Only a key that is still plugged in: nothing is ever asked of the person here.
    final List<SecurityKeyDevice> present;
    try {
      present = await ref.read(securityKeysProvider).present();
    } on SecurityKeyError {
      return _unplugged(generation);
    }
    if (generation != _generation || !_listening) return;
    if (!present.any((found) => found.id == id && !found.needsPermission)) return _unplugged(generation);
    final result = await read();
    if (generation != _generation) return;
    if (!result.ok || result.device != device) _unplugged(generation);
  }

  void _unplugged(int generation) {
    if (generation != _generation) return;
    _pluggedId = null;
    if (state.plugged != null) state = state.copyWith(plugged: null);
  }

  /// Asks the key for the one code of [account]: an account that needs a
  /// touch, or a counter-based one, whose counter moves on by one each
  /// time (decision 7). The code is in the result and in the state.
  Future<KeyCodesResult> calculate(KeyAccount account, {KeyRunner? runner, Uint8List? accessKey, bool remember = false}) {
    final generation = _generation;
    return onKey(runner: runner, accessKey: accessKey, remember: remember, device: account.device, touch: account.touch, (
      oath,
      connection,
    ) async {
      final name = oathNameBytes(account.name);
      if (!account.isTimeBased) {
        final code = (await oath.calculate(name)).text;
        if (generation == _generation) state = state.copyWith(counterCodes: {...state.counterCodes, account.id: code});
        return KeyCodesResult(KeyCodesOutcome.done, device: account.device, code: code);
      }
      final period = account.period < 1 ? oathDefaultPeriod : account.period;
      final step = _nowSec ~/ period;
      final code = (await oath.calculate(name, oathChallenge(step))).text;
      if (generation == _generation) {
        state = state.copyWith(
          codes: {
            ...state.codes,
            account.id: [KeyCode(code, step * period, (step + 1) * period)],
          },
        );
      }
      return KeyCodesResult(KeyCodesOutcome.done, device: account.device, code: code);
    });
  }

  void _dropCodes(Iterable<String> ids) {
    final gone = ids.toSet();
    state = state.copyWith(
      codes: {
        for (final MapEntry(key: id, :value) in state.codes.entries)
          if (!gone.contains(id)) id: value,
      },
      counterCodes: {
        for (final MapEntry(key: id, :value) in state.counterCodes.entries)
          if (!gone.contains(id)) id: value,
      },
    );
  }

  /// Deletes [account] from its key, then from what the vault remembers.
  Future<KeyCodesResult> delete(KeyAccount account, {KeyRunner? runner, Uint8List? accessKey, bool remember = false}) =>
      onKey(runner: runner, accessKey: accessKey, remember: remember, device: account.device, (oath, connection) async {
        try {
          await oath.delete(oathNameBytes(account.name));
        } on OathError catch (error) {
          // Already gone from the key: the vault's entry goes too.
          if (error.failure != OathFailure.noSuchAccount) rethrow;
        }
        await _vault.removeKeyAccount(account.id);
        _dropCodes([account.id]);
        return KeyCodesResult(KeyCodesOutcome.done, device: account.device);
      });

  /// Sets or changes the password of the key's code application to
  /// [password], or removes it when null. The current password, when there
  /// is one, is proved first, with [accessKey] or what the vault remembers.
  /// Whatever was remembered for the key is dropped.
  Future<KeyCodesResult> setPassword(String? password, {KeyRunner? runner, Uint8List? accessKey, String? device}) {
    final generation = _generation;
    return onKey(runner: runner, accessKey: accessKey, device: device, (oath, connection) async {
      final id = oath.select.device;
      if (password == null) {
        await oath.clearCode();
      } else {
        await oath.setCode(oathAccessKey(password, oath.select.id));
      }
      await _vault.forgetKeyAccess(id);
      final app = state.apps[connection.device.id];
      if (generation == _generation && app != null) {
        state = state.copyWith(
          apps: {
            ...state.apps,
            connection.device.id: KeyCodesApp(device: app.device, password: password != null, version: app.version),
          },
        );
      }
      return KeyCodesResult(KeyCodesOutcome.done, device: id);
    });
  }

  /// Erases the key's code application: every account and its password.
  /// What the vault remembers of the key goes in the same step, since the
  /// application has a new id afterwards.
  Future<KeyCodesResult> erase({KeyRunner? runner, String? device}) {
    final generation = _generation;
    return onKey(runner: runner, device: device, unlock: false, (oath, connection) async {
      final old = oath.select.device;
      await oath.reset();
      await forget(old);
      if (generation == _generation) _noteApp(connection.device.id, oath.select);
      return KeyCodesResult(KeyCodesOutcome.done, device: oath.select.device);
    });
  }

  /// Forgets the key [device] in this vault. Nothing is sent to the key.
  Future<bool> forget(String device) async {
    final ids = [
      for (final account in ref.read(vaultControllerProvider).keyAccounts)
        if (account.device == device) account.id,
    ];
    final done = await _vault.forgetKey(device);
    _dropCodes(ids);
    if (state.plugged == device) {
      _pluggedId = null;
      _repeat?.cancel();
      state = state.copyWith(plugged: null);
    }
    return done;
  }
}
