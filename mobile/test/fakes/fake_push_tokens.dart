import 'dart:async';

import 'package:kemlock/platform/push.dart';

/// The phone's push, kept in memory: the token it gives (null for none), the distributors it has, the nudges and
/// token changes a test makes arrive, and what the app asked of it.
class FakePushTokens implements PushTokens {
  FakePushTokens({
    this.token,
    this.available = true,
    this.choosesDistributor = false,
    this.installed = const [],
    this.inUse,
    this.startAnswer = true,
    this.silent = false,
  });

  /// A phone with no push service. The real push asks a platform channel for its token, and a widget test never gets
  /// that answer, so a sheet would wait on it for ever with its progress bar spinning.
  FakePushTokens.none() : this(available: false, startAnswer: false);

  /// An iPhone's push: a token of kind `apns`, and no distributor to choose.
  FakePushTokens.apns([String token = 'relay-token']) : this(token: (kind: pushKindApns, token: token));

  /// An Android phone's push: UnifiedPush through the [installed] distributors.
  FakePushTokens.unifiedPush({PushToken? token, List<PushDistributor> installed = const [], PushDistributor? inUse})
    : this(choosesDistributor: true, token: token, installed: installed, inUse: inUse);

  @override
  bool available;

  @override
  bool choosesDistributor;

  /// The token [pushToken] gives now.
  PushToken? token;

  /// A push service that never answers for its token.
  bool silent;

  List<PushDistributor> installed;
  PushDistributor? inUse;

  /// What [start] and [change] answer.
  bool startAnswer;

  /// What was asked, in order: `pushToken`, `start`, `change`, `stop`.
  final calls = <String>[];

  /// Nudges as a test makes them arrive.
  final nudges = StreamController<PushNudge>.broadcast();

  /// A change of token, as a test makes it arrive.
  final changes = StreamController<void>.broadcast();

  @override
  Future<PushToken?> pushToken() {
    calls.add('pushToken');
    return silent ? Completer<PushToken?>().future : Future.value(token);
  }

  @override
  Stream<PushNudge> get onMessage => nudges.stream;

  @override
  Stream<void> get onTokenChanged => changes.stream;

  @override
  Future<PushDistributors> distributors() async => PushDistributors(installed: installed, inUse: inUse);

  @override
  Future<bool> start() async {
    calls.add('start');
    if (startAnswer && installed.isNotEmpty) inUse ??= installed.first;
    return startAnswer;
  }

  @override
  Future<bool> change() async {
    calls.add('change');
    return startAnswer;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  /// Closes the streams; a test calls it in a tear-down.
  Future<void> close() async {
    await nudges.close();
    await changes.close();
  }
}
