/// Scheduled local notifications, for the reminders before a PGP key
/// expires (openspec: add-key-expiry-warnings). This is the only file that
/// imports the notification plugin: everything else asks [Reminders], which
/// tests replace with a fake.
///
/// It covers scheduled notifications in one channel, and the one fixed-text
/// notification a sign-in request raises ([ApprovalNotice]): no network, no
/// actions. Tapping one launches the app, which shows its lock screen as any
/// launch does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../i18n/messages.dart';

/// The plugin, set up once for both [PluginReminders] and [PluginApprovalNotice], with the one tap callback.
class _Notifications {
  final plugin = FlutterLocalNotificationsPlugin();
  final taps = StreamController<void>.broadcast();
  Future<void>? _ready;

  /// Sets the plugin up once, asking for nothing: iOS would otherwise show its permission prompt here, at the
  /// first notification.
  Future<void> ready() => _ready ??= plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_key'),
      iOS: DarwinInitializationSettings(requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
    ),
    onDidReceiveNotificationResponse: (_) => taps.add(null),
  );
}

final _notifications = _Notifications();

/// The phone's scheduled notifications.
abstract interface class Reminders {
  /// Asks the phone for permission to notify, showing its prompt the first
  /// time. False when the person refused, now or before, and where the
  /// phone has no notifications.
  Future<bool> requestPermission();

  /// Shows a notification with [title] and [body] at [when], with the app
  /// closed. One already scheduled under [id] is replaced.
  Future<void> schedule({required int id, required DateTime when, required String title, required String body});

  /// Takes back the notification scheduled under [id], if there is one.
  Future<void> cancel(int id);

  /// The ids of the notifications scheduled and not yet shown.
  Future<Set<int>> pending();
}

/// [Reminders] over `flutter_local_notifications`.
///
/// Notifications are scheduled inexactly, so Android asks for no
/// exact-alarm permission: a reminder a few minutes late is fine. A time is
/// handed over as its instant in UTC, which needs no time zone database:
/// whoever schedules has already worked out the local time it means.
class PluginReminders implements Reminders {
  PluginReminders({required this.channelName});

  /// The Android channel's id, which the phone's settings keep the person's choices under.
  static const channelId = 'key_reminders';

  /// The name the phone's settings show for the channel, in the app's language now.
  final String Function() channelName;

  FlutterLocalNotificationsPlugin get _plugin => _notifications.plugin;

  Future<void> _init() => _notifications.ready();

  @override
  Future<bool> requestPermission() async {
    await _init();
    return switch (defaultTargetPlatform) {
      TargetPlatform.android =>
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission() ??
            false,
      TargetPlatform.iOS =>
        await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
              alert: true,
              sound: true,
            ) ??
            false,
      _ => false,
    };
  }

  @override
  Future<void> schedule({required int id, required DateTime when, required String title, required String body}) async {
    await _init();
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(channelId, channelName()),
        iOS: const DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> cancel(int id) async {
    await _init();
    await _plugin.cancel(id: id);
  }

  @override
  Future<Set<int>> pending() async {
    await _init();
    return {for (final request in await _plugin.pendingNotificationRequests()) request.id};
  }
}

/// The phone's scheduled notifications. Tests override it with a fake.
final remindersProvider = Provider<Reminders>(
  (ref) => PluginReminders(channelName: () => ref.read(messagesProvider).t('reminders.channel')),
);

/// The notification a sign-in request raises while the vault is locked or the app is behind
/// (add-kemlock-server-sync, design 13). Its text is fixed and names no device and no account. Tapping it opens
/// Kemlock, which shows its lock screen as any launch does and the request after the unlock; while the vault is
/// open, [taps] says it was tapped, so the requests are read again.
abstract interface class ApprovalNotice {
  /// Asks the phone for permission to notify where it asks (Android 13 and later), showing its prompt the first
  /// time. iOS asked when the push token was; true there. False when the person refused.
  Future<bool> requestPermission();

  /// Shows the notice, replacing one already shown. Nothing is shown without permission.
  Future<void> show();

  /// Takes the notice back, once the request is shown or answered.
  Future<void> clear();

  /// Each tap on the notice, while the app runs.
  Stream<void> get taps;
}

/// [ApprovalNotice] over `flutter_local_notifications`: one channel and one notification id.
class PluginApprovalNotice implements ApprovalNotice {
  PluginApprovalNotice({required this.channelName, required this.title, required this.body});

  /// The Android channel's id.
  static const channelId = 'approval_requests';

  /// The notification's id.
  static const id = 0x4B01;

  final String Function() channelName;
  final String Function() title;
  final String Function() body;

  @override
  Future<bool> requestPermission() async {
    await _notifications.ready();
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    return await _notifications.plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission() ??
        false;
  }

  @override
  Future<void> show() async {
    await _notifications.ready();
    await _notifications.plugin.show(
      id: id,
      title: title(),
      body: body(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName(),
          importance: Importance.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  @override
  Future<void> clear() async {
    await _notifications.ready();
    await _notifications.plugin.cancel(id: id);
  }

  @override
  Stream<void> get taps => _notifications.taps.stream;
}

/// The notice a sign-in request raises. Tests override it with a fake.
final approvalNoticeProvider = Provider<ApprovalNotice>((ref) {
  String t(String key) => ref.read(messagesProvider).t(key);
  return PluginApprovalNotice(
    channelName: () => t('kemlock.approval.notice.channel'),
    title: () => t('kemlock.approval.notice.title'),
    body: () => t('kemlock.approval.notice.body'),
  );
});
