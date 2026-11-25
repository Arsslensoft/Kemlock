/// Nudges from other devices (add-kemlock-server-sync, design 13; plan add-unifiedpush). The server
/// pushes to the phone itself: APNs on iOS, in the store build, and UnifiedPush on Android, in both builds,
/// through the distributor the person chose (ntfy, NextPush, ...). A nudge carries only its type; it never
/// carries a name, an account or an item. Where there is no push (the free build on iOS, an Android phone
/// with no distributor), the phone syncs on its schedule and over the live socket while the app is open.
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

/// How the server reaches this phone: the push service that [kind] names and the address [token] it gives. The
/// shape of the server's `PushTokenRequest`.
typedef PushToken = ({String kind, String token});

/// The `kind` of an iPhone's token: the hex of its APNs device token.
const pushKindApns = 'apns';

/// The `kind` of an Android phone's token: the URL of its UnifiedPush endpoint.
const pushKindUnifiedPush = 'unifiedpush';

/// An app on the phone that delivers pushes (a UnifiedPush distributor): [id] is its package name, [name] is what the
/// phone calls it.
class PushDistributor {
  const PushDistributor({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is PushDistributor && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The distributors this phone has and the one in use, for the push switch.
class PushDistributors {
  const PushDistributors({this.installed = const [], this.inUse});

  /// Nothing installed.
  static const none = PushDistributors();

  final List<PushDistributor> installed;

  /// The one the phone uses, null before a choice.
  final PushDistributor? inUse;
}

/// This phone's push token and the nudges that arrive through it.
abstract interface class PushTokens {
  /// Whether this build and platform have a push service at all: iOS in the store build, and Android in both builds
  /// (through a distributor the person installs). Whether a distributor is there is [distributors]'s answer.
  bool get available;

  /// Whether the person picks the app that delivers the pushes (UnifiedPush on Android), and so [distributors],
  /// [start] and [change] mean something. False for APNs and where there is no push.
  bool get choosesDistributor;

  /// The token the server is given for this phone, or null when there is none: no push here, the person refused
  /// notifications, no distributor chosen, or the phone has not been given one yet.
  Future<PushToken?> pushToken();

  /// Nudges as they arrive, while the app runs. Empty where there is no push.
  Stream<PushNudge> get onMessage;

  /// Emits when the phone's token changed or went (a new UnifiedPush endpoint, a lost registration): ask
  /// [pushToken] for what it is now. Empty where the token never changes.
  Stream<void> get onTokenChanged;

  /// The distributors installed and the one in use. [PushDistributors.none] where [choosesDistributor] is false.
  Future<PushDistributors> distributors();

  /// Makes ready to receive pushes: registers with the distributor in use, or with the system's default, which asks
  /// the person to pick on the system's own screen when there are several. True when the phone is ready; false when
  /// there is no distributor or the person went back. Where [choosesDistributor] is false, whether [available].
  Future<bool> start();

  /// Lets the person pick another distributor, then registers with it. False when none could be picked.
  Future<bool> change();

  /// Gives the registration back, as the push switch turned off does: the phone stops receiving pushes. The server is
  /// asked to forget the token separately.
  Future<void> stop();
}
