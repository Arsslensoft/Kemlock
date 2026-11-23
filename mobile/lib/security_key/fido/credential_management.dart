/// The passkeys on a key (`authenticatorCredentialManagement`, CTAP 2.1
/// section 6.8): how many places are used, the list, and deleting one.
/// The standard command (`0x0A`) and the preview one older keys have
/// (`0x41`) take the same subcommands and maps, so one implementation
/// serves both, given the command byte.
library;

import 'dart:typed_data';

import '../cbor.dart';
import '../connection.dart';
import 'client_pin.dart';
import 'ctap.dart';

/// How full a key is.
class PasskeyStorage {
  const PasskeyStorage({required this.used, required this.remaining});

  /// Passkeys on the key.
  final int used;

  /// How many more the key says it can hold, at most.
  final int remaining;

  int get total => used + remaining;
}

/// One passkey on a key: the site it signs in to and the account.
class KeyPasskey {
  const KeyPasskey({
    required this.rpId,
    this.rpName,
    required this.userId,
    this.userName,
    this.userDisplayName,
    required this.credentialId,
  });

  /// The site, as its domain.
  final String rpId;
  final String? rpName;
  final Uint8List userId;
  final String? userName;
  final String? userDisplayName;

  /// The credential's descriptor as the key gave it, which deleting sends back.
  final Map<String, Object?> credentialId;
}

/// The most sites, and the most passkeys in all, a key may say it holds:
/// the keys made today hold a few hundred at most. A key that names more
/// would have the list asked for one by one, and grow, as long as it liked.
const keyPasskeysMost = 1000;

/// The credential management commands of one key.
class CredentialManagement {
  CredentialManagement(this.session, this.command, this.token);

  final CtapSession session;

  /// [CtapCommand.credentialManagement] or [CtapCommand.credentialManagementPreview].
  final int command;

  /// A token with [PinPermission.credentialManagement].
  final PinToken token;

  Future<Map<int, Object?>> _signed(int subCommand, [Map<int, Object?>? parameters]) => session.request(command, {
    1: subCommand,
    2: ?parameters,
    3: token.protocol.number,
    4: token.authenticate([subCommand, if (parameters != null) ...cborEncode(parameters)]),
  });

  /// How many passkeys the key holds and has room for.
  Future<PasskeyStorage> metadata() async {
    final answer = await _signed(1);
    final used = answer[1];
    final remaining = answer[2];
    if (used is! int || remaining is! int) throw const CtapError(CtapStatus.invalidParameter);
    return PasskeyStorage(used: used, remaining: remaining);
  }

  /// Every passkey on the key, site by site. It is the whole list or an
  /// error: a key that leaves half-way gives nothing, and one that names
  /// more than [keyPasskeysMost] sites or passkeys is refused with
  /// [CtapError] before they are asked for.
  Future<List<KeyPasskey>> list() async {
    final sites = <(String, String?, Uint8List)>[];
    Map<int, Object?> answer;
    try {
      answer = await _signed(2);
    } on CtapError catch (error) {
      if (error.status == CtapStatus.noCredentials) return const [];
      rethrow;
    }
    final totalSites = answer[5];
    if (totalSites is! int || totalSites == 0) return const [];
    if (totalSites > keyPasskeysMost) throw const CtapError(CtapStatus.invalidParameter);
    for (var i = 0; i < totalSites; i++) {
      if (i > 0) answer = await session.request(command, {1: 3});
      final rp = cborTextMap(answer[3]);
      final hash = answer[4];
      final id = rp['id'];
      if (id is! String || hash is! Uint8List) throw const CtapError(CtapStatus.invalidParameter);
      final name = rp['name'];
      sites.add((id, name is String ? name : null, hash));
    }

    final passkeys = <KeyPasskey>[];
    for (final (rpId, rpName, hash) in sites) {
      answer = await _signed(4, {1: hash});
      final total = answer[9];
      final count = total is int ? total : 1;
      if (count > keyPasskeysMost - passkeys.length) throw const CtapError(CtapStatus.invalidParameter);
      for (var i = 0; i < count; i++) {
        if (i > 0) answer = await session.request(command, {1: 5});
        final user = cborTextMap(answer[6]);
        final userId = user['id'];
        final userName = user['name'];
        final displayName = user['displayName'];
        final credential = cborTextMap(answer[7]);
        if (credential['id'] is! Uint8List) throw const CtapError(CtapStatus.invalidParameter);
        passkeys.add(
          KeyPasskey(
            rpId: rpId,
            rpName: rpName,
            userId: userId is Uint8List ? userId : Uint8List(0),
            userName: userName is String ? userName : null,
            userDisplayName: displayName is String ? displayName : null,
            credentialId: credential,
          ),
        );
      }
    }
    return passkeys;
  }

  /// Deletes [passkey] from the key.
  Future<void> delete(KeyPasskey passkey) async {
    await _signed(6, {2: passkey.credentialId});
  }
}
