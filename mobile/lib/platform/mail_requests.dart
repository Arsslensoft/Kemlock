import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/mail/mail_caller.dart';

/// The extras of a mail app's request that Kemlock reads (openspec:
/// add-pgp-mail-provider, decision 9). Anything else is dropped, on the
/// native side and again here; `passphrase` is never among them.
const mailExtras = {
  'api_version',
  'ascii_armor',
  'user_ids',
  'key_ids',
  'sign_key_id',
  'user_id',
  'key_id',
  'detached_signature',
  'opportunistic',
  'sender_address',
  'preselect_key_id',
};

/// One `execute` of a mail app, as the service hands it to Dart.
@immutable
class MailCall {
  const MailCall({
    required this.requestId,
    this.resentFrom,
    required this.action,
    this.extras = const {},
    required this.caller,
    this.input,
    this.inputTooLarge = false,
    this.dry = false,
  });

  factory MailCall.fromMap(Map<Object?, Object?> map) {
    final extras = map['extras'];
    final caller = map['caller'];
    final input = map['input'];
    return MailCall(
      requestId: map['requestId'] is String ? map['requestId']! as String : '',
      resentFrom: map['resentFrom'] is String ? map['resentFrom']! as String : null,
      action: map['action'] is String ? map['action']! as String : '',
      extras: {
        if (extras is Map)
          for (final MapEntry(:key, :value) in extras.entries)
            if (key is String && mailExtras.contains(key)) key: value,
      },
      caller: caller is Map ? MailCaller.fromMap(caller) : const MailCaller(package: '', cert: '', refusal: MailCallerRefusal.noPackage),
      input: input is Uint8List ? input : null,
      inputTooLarge: map['inputTooLarge'] == true,
      dry: map['dry'] == true,
    );
  }

  /// The id the service made for this call: the request screen's, if the
  /// person is needed.
  final String requestId;

  /// The id of the request screen whose Intent this is, when the mail app
  /// sends again what that screen returned.
  final String? resentFrom;

  /// `org.openintents.openpgp.action.DECRYPT_VERIFY`, and the rest.
  final String action;
  final Map<String, Object?> extras;
  final MailCaller caller;

  /// What the input pipe held, whole; null without one.
  final Uint8List? input;

  /// The input was over the service's limit and was not read.
  final bool inputTooLarge;

  /// The service holds an input pipe it has not read: it reads it only when
  /// the answer is [MailAnswer.sendInput], and then sends the call again
  /// with [input], so an app never approved gets no byte of it read.
  final bool dry;

  /// The same request without its input: what is kept while the person is
  /// asked.
  MailCall withoutInput() =>
      MailCall(requestId: requestId, resentFrom: resentFrom, action: action, extras: extras, caller: caller, inputTooLarge: inputTooLarge);
}

/// What Dart answers a call with: the result Intent's extras, as the
/// service turns them into the API's parcelables, and the output pipe's
/// bytes.
@immutable
class MailAnswer {
  const MailAnswer(this.result, {this.output}) : wantsInput = false;

  const MailAnswer._sendInput() : result = const {}, output = null, wantsInput = true;

  /// What a [MailCall.dry] call gets when the work on its input is all that
  /// is left: no answer for the mail app yet, the service sends the input.
  static const sendInput = MailAnswer._sendInput();

  final Map<String, Object?> result;
  final Uint8List? output;

  /// This is [sendInput], which has no [result] and no [resultCode].
  final bool wantsInput;

  int get resultCode => result['result_code']! as int;

  Map<String, Object?> toMap() => wantsInput ? const {'sendInput': true} : {'result': result, 'output': output};
}

/// The request screen that came to the front, with the app it is for.
@immutable
class MailFront {
  const MailFront(this.requestId, this.caller);

  final String requestId;
  final MailCaller caller;

  @override
  bool operator ==(Object other) => other is MailFront && other.requestId == requestId && other.caller == caller;

  @override
  int get hashCode => Object.hash(requestId, caller);
}

/// The Dart side of `com.kemlock.app/mail`, the channel the mail provider's
/// service and request screen speak (decisions 1 and 3).
abstract interface class MailRequests {
  /// Answers each call with [answer], and says through [front] which
  /// request screen is in front: a [MailFront] when the request screen
  /// attaches, null when the app's own screen does, and [left] when a
  /// request screen went away without being finished.
  void serve({
    required Future<MailAnswer> Function(MailCall call) answer,
    required void Function(MailFront? front) front,
    required void Function(String requestId) left,
  });

  /// Closes the request screen [requestId]: with [ok], the mail app gets its
  /// request back with [extras] added, to send again; without, it is
  /// told the request was cancelled.
  Future<void> finish(String requestId, {required bool ok, Map<String, Object?> extras = const {}});
}

/// [MailRequests] over the app's method channel, on Android.
class ChannelMailRequests implements MailRequests {
  static const _channel = MethodChannel('com.kemlock.app/mail');

  @override
  void serve({
    required Future<MailAnswer> Function(MailCall call) answer,
    required void Function(MailFront? front) front,
    required void Function(String requestId) left,
  }) {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'execute' when args is Map:
          return (await answer(MailCall.fromMap(args))).toMap();
        case 'front' when args is Map:
          final id = args['requestId'];
          final caller = args['caller'];
          front(id is String && caller is Map ? MailFront(id, MailCaller.fromMap(caller)) : null);
        case 'left' when args is Map && args['requestId'] is String:
          left(args['requestId']! as String);
      }
      return null;
    });
    // The service waits for this before its first call
    unawaited(_channel.invokeMethod<void>('ready').catchError((Object _) {}));
  }

  @override
  Future<void> finish(String requestId, {required bool ok, Map<String, Object?> extras = const {}}) async {
    try {
      await _channel.invokeMethod<void>('finish', {'requestId': requestId, 'ok': ok, 'extras': extras});
    } on MissingPluginException {
      // No request screen to close
    } on PlatformException {
      // Gone already
    }
  }
}

/// Where there is no mail provider: iOS, and builds without the native side.
class NoMailRequests implements MailRequests {
  const NoMailRequests();

  @override
  void serve({
    required Future<MailAnswer> Function(MailCall call) answer,
    required void Function(MailFront? front) front,
    required void Function(String requestId) left,
  }) {}

  @override
  Future<void> finish(String requestId, {required bool ok, Map<String, Object?> extras = const {}}) async {}
}

/// The mail provider's channel: Android's, or none; tests put a fake.
final mailRequestsProvider = Provider<MailRequests>(
  (ref) => defaultTargetPlatform == TargetPlatform.android ? ChannelMailRequests() : const NoMailRequests(),
);
