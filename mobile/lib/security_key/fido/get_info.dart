/// What a key says of itself (`authenticatorGetInfo`, CTAP 2.1 section
/// 6.4). Every feature the app offers for a key is decided from this
/// answer, read each time the key is connected, never from its brand.
library;

import 'dart:typed_data';

import '../cbor.dart';
import '../connection.dart';
import 'ctap.dart';

/// Whether a key has a PIN.
enum KeyPinState {
  /// The key has no notion of a PIN.
  unsupported,

  /// The key can have a PIN and has none.
  notSet,

  /// The key has a PIN.
  set,
}

/// A key's answer to `authenticatorGetInfo`. Members the app does not use,
/// and members it does not know, are ignored.
class AuthenticatorInfo {
  const AuthenticatorInfo({
    required this.versions,
    required this.aaguid,
    this.options = const {},
    this.extensions = const [],
    this.pinUvAuthProtocols = const [],
    this.forcePinChange = false,
    this.minPinLength = 4,
    this.firmwareVersion,
    this.remainingDiscoverableCredentials,
  });

  /// Reads the answer's members.
  factory AuthenticatorInfo.parse(Map<int, Object?> map) {
    final options = cborTextMap(map[4]);
    final aaguid = map[3];
    final minPin = map[13];
    final firmware = map[14];
    final remaining = map[20];
    return AuthenticatorInfo(
      versions: [
        for (final version in _list(map[1]))
          if (version is String) version,
      ],
      aaguid: aaguid is Uint8List ? aaguid : Uint8List(0),
      extensions: [
        for (final extension in _list(map[2]))
          if (extension is String) extension,
      ],
      options: {
        for (final MapEntry(:key, :value) in options.entries)
          if (value is bool) key: value,
      },
      pinUvAuthProtocols: [
        for (final protocol in _list(map[6]))
          if (protocol is int) protocol,
      ],
      forcePinChange: map[12] == true,
      minPinLength: minPin is int && minPin > 0 ? minPin : 4,
      firmwareVersion: firmware is int ? firmware : null,
      remainingDiscoverableCredentials: remaining is int ? remaining : null,
    );
  }

  static List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];

  /// The protocol versions the key speaks, such as `U2F_V2`, `FIDO_2_0`, `FIDO_2_1`.
  final List<String> versions;

  /// The identifier of the key's model, 16 bytes.
  final Uint8List aaguid;

  /// The extensions the key lists, such as `hmac-secret` and `credProtect`.
  final List<String> extensions;

  /// The key's options: present and true, present and false, or absent.
  final Map<String, bool> options;

  /// The PIN protocols the key offers, in its order of preference.
  final List<int> pinUvAuthProtocols;

  /// The key wants its PIN changed before the PIN is used for anything.
  final bool forcePinChange;

  /// The fewest characters the key takes for a PIN; 4 when it does not say.
  final int minPinLength;

  /// The firmware version as the key packs it, when it reports one.
  final int? firmwareVersion;

  /// How many more passkeys the key says it can hold, when it says.
  final int? remainingDiscoverableCredentials;

  /// Whether the key speaks FIDO2 at all, and not only the older U2F.
  bool get fido2 => versions.any((version) => version.startsWith('FIDO_2'));

  KeyPinState get pin => switch (options['clientPin']) {
    null => KeyPinState.unsupported,
    false => KeyPinState.notSet,
    true => KeyPinState.set,
  };

  /// The command that lists and deletes passkeys on this key: the
  /// standard one, the preview one, or null when the key has neither.
  int? get credentialManagementCommand {
    if (options['credMgmt'] ?? false) return CtapCommand.credentialManagement;
    if (options['credentialMgmtPreview'] ?? false) return CtapCommand.credentialManagementPreview;
    return null;
  }

  /// The command that manages fingerprints on this key: the standard one,
  /// the preview one, or null when the key has no reader.
  int? get bioEnrollmentCommand {
    if (options.containsKey('bioEnroll')) return CtapCommand.bioEnrollment;
    if (options.containsKey('userVerificationMgmtPreview')) return CtapCommand.bioEnrollmentPreview;
    return null;
  }

  /// Whether the key hands out tokens limited to what an action needs.
  bool get pinUvAuthToken => options['pinUvAuthToken'] ?? false;

  /// Whether [other] is the same model of key, as far as a key says.
  bool sameModelAs(AuthenticatorInfo other) {
    if (aaguid.length != other.aaguid.length) return false;
    for (var i = 0; i < aaguid.length; i++) {
      if (aaguid[i] != other.aaguid[i]) return false;
    }
    return true;
  }
}

/// Asks the key what it is and what it supports.
Future<AuthenticatorInfo> getInfo(CtapSession session) async => AuthenticatorInfo.parse(await session.request(CtapCommand.getInfo));
