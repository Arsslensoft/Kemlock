import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/platform/mail_requests.dart';

/// Stands in for the mail provider's service and request screen: a test
/// sends calls as a mail app would, brings a request screen to the front,
/// and reads how each screen was finished.
class FakeMailRequests implements MailRequests {
  Future<MailAnswer> Function(MailCall call)? _answer;
  void Function(MailFront? front)? _front;
  void Function(String requestId)? _left;

  Override get asOverride => mailRequestsProvider.overrideWithValue(this);

  /// Each screen finished, in order: its id, whether OK, and what was added.
  final finished = <({String requestId, bool ok, Map<String, Object?> extras})>[];

  bool get serving => _answer != null;

  /// A mail app's `execute`.
  Future<MailAnswer> send(MailCall call) => _answer!(call);

  /// The request screen [requestId] attaches, for [caller]; null for the app's own screen.
  void bringToFront(String? requestId, [MailCaller? caller]) => _front!(requestId == null ? null : MailFront(requestId, caller!));

  /// The request screen [requestId] went away unfinished.
  void leave(String requestId) => _left!(requestId);

  @override
  void serve({
    required Future<MailAnswer> Function(MailCall call) answer,
    required void Function(MailFront? front) front,
    required void Function(String requestId) left,
  }) {
    _answer = answer;
    _front = front;
    _left = left;
  }

  @override
  Future<void> finish(String requestId, {required bool ok, Map<String, Object?> extras = const {}}) async =>
      finished.add((requestId: requestId, ok: ok, extras: extras));
}
