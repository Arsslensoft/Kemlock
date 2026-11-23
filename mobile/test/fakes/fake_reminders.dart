import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/reminders.dart';

/// One notification the app scheduled.
typedef ScheduledReminder = ({int id, DateTime when, String title, String body});

/// The phone's scheduled notifications, kept in memory: what is pending,
/// and every call the app made, in order.
class FakeReminders implements Reminders {
  FakeReminders({this.granted = true});

  /// What the phone answers when asked for permission to notify.
  bool granted;

  /// How often the app asked for permission.
  int permissionRequests = 0;

  /// The notifications scheduled and not cancelled, by id.
  final Map<int, ScheduledReminder> scheduled = {};

  /// Every `schedule` and `cancel` the app made, as `schedule <id>` and `cancel <id>`.
  final List<String> calls = [];

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<void> schedule({required int id, required DateTime when, required String title, required String body}) async {
    calls.add('schedule $id');
    scheduled[id] = (id: id, when: when, title: title, body: body);
  }

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel $id');
    scheduled.remove(id);
  }

  @override
  Future<Set<int>> pending() async => scheduled.keys.toSet();

  /// The pending notifications, soonest first.
  List<ScheduledReminder> get inOrder => scheduled.values.toList()..sort((a, b) => a.when.compareTo(b.when));

  Override get asOverride => remindersProvider.overrideWithValue(this);
}
