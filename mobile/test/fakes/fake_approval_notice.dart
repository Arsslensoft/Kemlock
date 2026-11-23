import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/reminders.dart';

/// The sign-in request notification, kept in memory: whether it is showing, how often it was shown, and a tap
/// the test makes.
class FakeApprovalNotice implements ApprovalNotice {
  FakeApprovalNotice({this.granted = true});

  /// What the phone answers when asked for permission to notify.
  bool granted;

  /// How often the app asked for permission.
  int permissionRequests = 0;

  /// Whether the notice is showing now.
  bool showing = false;

  /// How often the notice was shown.
  int shown = 0;

  final _taps = StreamController<void>.broadcast();

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<void> show() async {
    if (!granted) {
      return;
    }
    showing = true;
    shown++;
  }

  @override
  Future<void> clear() async {
    showing = false;
  }

  @override
  Stream<void> get taps => _taps.stream;

  /// The person taps the notice.
  void tap() => _taps.add(null);

  Override get asOverride => approvalNoticeProvider.overrideWithValue(this);
}
