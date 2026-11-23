/// Nudges from other devices (add-kemlock-server-sync, design 13). The server
/// tells Kemlock's push relay and the relay tells the phone: APNs, on iOS in the
/// store build. A nudge carries only its type; it never carries a name, an
/// account or an item. Android and the free build have no push: they sync on
/// their schedule and over the live socket while the app is open.
library;

/// What a nudge asks for.
enum PushNudge {
  /// Another device changed the vault: sync now, if the vault is open.
  sync,

  /// Another device asks to sign in: show the request, once the vault is open.
  approval;

  /// The nudge a message of [type] is, or null for a type this version doesn't know.
  static PushNudge? parse(Object? type) {
    for (final nudge in values) {
      if (nudge.name == type) return nudge;
    }
    return null;
  }
}

/// This phone's push token and the nudges that arrive through it.
abstract interface class PushTokens {
  /// Whether this build can receive pushes at all: the store build can on iOS, and Android and the free build have none.
  bool get available;

  /// The token the relay is given for this phone, or null when there is none: no push in this build, the
  /// person refused notifications, or the phone has not been given one yet.
  Future<String?> token();

  /// Nudges as they arrive, while the app runs. Empty where there is no push.
  Stream<PushNudge> get onMessage;
}
