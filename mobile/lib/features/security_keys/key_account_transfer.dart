/// Putting an account on a security key: moving it from the vault, copying
/// it, or adding a new one straight to the key (openspec:
/// add-security-key-codes, decision 9). The account is written, the key's
/// code is checked against the vault's, and only then is anything changed
/// in the vault.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../../models/key_account.dart';
import '../../models/otp_account.dart';
import '../../platform/security_keys.dart';
import '../../security_key/oath/oath_messages.dart';
import '../../security_key/oath/oath_name.dart';
import '../../vault/vault_controller.dart';
import '../accounts/otp.dart';
import 'key_codes.dart';

/// What becomes of the vault's copy once the account is on the key.
enum KeyTransfer {
  /// It leaves the vault.
  move,

  /// It stays in the vault.
  copy,

  /// There is none: a scanned or typed account that was never saved.
  add,
}

/// The account's name on the key, `[period/]issuer:label`.
String keyNameOf(OtpAccount account) =>
    buildOathName(issuer: account.issuer, label: account.label, period: account.period, timeBased: isTimeBased(account));

OathAlgorithm? _algorithmOf(OtpAccount account) => OathAlgorithm.values.firstWhereOrNull((a) => a.label == account.algorithm.toUpperCase());

/// Why [account] cannot go to any key, found before a key is reached:
/// Steam Guard, a shared space's account, a name too long, or a secret,
/// number of digits or algorithm no key takes. Null when it can.
KeyCodesResult? keyTransferRefusal(OtpAccount account) {
  if (account.kind == OtpType.steam) return const KeyCodesResult(KeyCodesOutcome.refused, refusal: KeyRefusal.steam);
  if (account.spaceId != null) return const KeyCodesResult(KeyCodesOutcome.refused, refusal: KeyRefusal.space);
  final name = keyNameOf(account);
  if (!oathNameFits(name)) {
    return KeyCodesResult(KeyCodesOutcome.refused, refusal: KeyRefusal.name, nameBytes: utf8.encode(name).length);
  }
  final secretOk = isValidSecret(account.secret);
  final timeOk = !isTimeBased(account) || account.period > 0;
  if (!secretOk || _algorithmOf(account) == null || account.digits < 6 || account.digits > 8 || !timeOk) {
    return const KeyCodesResult(KeyCodesOutcome.refused, refusal: KeyRefusal.secret);
  }
  return null;
}

/// Puts [account] on the key [codes] reaches (the next one presented,
/// without [runner]), as [mode] says, asking the key for a touch on each
/// code when [touch].
///
/// Refused before anything is written: what [keyTransferRefusal] refuses,
/// SHA-512 or a touch on a firmware that cannot take them. A name the key
/// already holds is [KeyCodesOutcome.exists] unless [replace]. The account
/// is then written, and the key's code compared with the vault's for the
/// same step (for a counter-based account, the key's first code with the
/// vault's next). Equal: the key's list is remembered with the new entry,
/// which carries the account's tags and note, and a move deletes the
/// vault's copy. Not equal: the entry is taken off the key again and the
/// vault is left as it was. A key that leaves after the write leaves the
/// vault as it was too.
Future<KeyCodesResult> putOnKey(
  KeyCodesController codes,
  VaultController vault,
  OtpAccount account, {
  required KeyTransfer mode,
  required int Function() nowSec,
  bool touch = false,
  bool replace = false,
  KeyRunner? runner,
  Uint8List? accessKey,
  bool remember = false,
}) async {
  final refused = keyTransferRefusal(account);
  if (refused != null) return refused;
  final name = keyNameOf(account);
  final nameBytes = utf8.encode(name);
  final algorithm = _algorithmOf(account)!;
  final timeBased = isTimeBased(account);
  return codes.onKey(runner: runner, accessKey: accessKey, remember: remember, touch: touch, (oath, connection) async {
    final device = oath.select.device;
    final version = oath.select.version;
    if (algorithm == OathAlgorithm.sha512 && !version.takesSha512) {
      return KeyCodesResult(KeyCodesOutcome.refused, device: device, refusal: KeyRefusal.algorithm, version: version);
    }
    if (touch && !version.takesTouch) {
      return KeyCodesResult(KeyCodesOutcome.refused, device: device, refusal: KeyRefusal.touch, version: version);
    }
    final listed = await oath.list();
    final held = listed.any((entry) => const ListEquality<int>().equals(entry.name, nameBytes));
    if (held && !replace) return KeyCodesResult(KeyCodesOutcome.exists, device: device);

    await oath.put(
      name: nameBytes,
      type: timeBased ? OathType.totp : OathType.hotp,
      algorithm: algorithm,
      digits: account.digits,
      secret: base32Decode(account.secret),
      touch: touch,
      counter: timeBased ? 0 : account.counter ?? 0,
    );

    // The check: the key's code against the vault's own, for the same step.
    final String fromKey;
    final String fromVault;
    try {
      if (timeBased) {
        final step = nowSec() ~/ account.period;
        fromKey = (await oath.calculate(nameBytes, oathChallenge(step))).text;
        fromVault = codeAt(account, step * account.period);
      } else {
        fromKey = (await oath.calculate(nameBytes)).text;
        fromVault = codeAt(account, 0);
      }
    } on SecurityKeyError {
      return KeyCodesResult(KeyCodesOutcome.unchecked, device: device);
    }
    if (fromKey != fromVault) {
      try {
        await oath.delete(nameBytes);
      } on Object {
        // Taken away or refused: the entry stays on the key, and the vault keeps the account.
      }
      return KeyCodesResult(KeyCodesOutcome.mismatch, device: device);
    }

    final type = timeBased ? KeyAccountType.totp : KeyAccountType.hotp;
    await vault.reconcileKey(device, connection.device.productName, [
      for (final entry in listed)
        if (!const ListEquality<int>().equals(entry.name, nameBytes))
          if (_text(entry.name) case final other?)
            KeyAccountSeen(
              name: other,
              type: entry.type == OathType.hotp ? KeyAccountType.hotp : KeyAccountType.totp,
              algorithm: entry.algorithm.label,
            ),
      KeyAccountSeen(name: name, type: type, algorithm: algorithm.label, touch: touch, tags: account.tags, note: account.note),
    ]);
    if (mode == KeyTransfer.move) await vault.deleteAccount(account);
    return KeyCodesResult(KeyCodesOutcome.done, device: device);
  });
}

String? _text(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}
