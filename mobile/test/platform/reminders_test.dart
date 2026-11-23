import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/reminders.dart';

import '../fakes/fake_reminders.dart';

void main() {
  final at = DateTime.utc(2026, 12, 1, 9);

  test('the fake keeps what is scheduled, replaces by id, and forgets what is cancelled', () async {
    final fake = FakeReminders();
    final container = ProviderContainer(overrides: [fake.asOverride]);
    addTearDown(container.dispose);
    final reminders = container.read(remindersProvider);

    expect(await reminders.pending(), isEmpty);
    await reminders.schedule(id: 7, when: at, title: 'Title', body: 'First');
    await reminders.schedule(id: 9, when: at.add(const Duration(days: 1)), title: 'Title', body: 'Second');
    expect(await reminders.pending(), {7, 9});
    expect(fake.scheduled[7], (id: 7, when: at, title: 'Title', body: 'First'));

    await reminders.schedule(id: 7, when: at, title: 'Title', body: 'Again');
    expect(await reminders.pending(), {7, 9});
    expect(fake.scheduled[7]!.body, 'Again');

    await reminders.cancel(7);
    await reminders.cancel(123);
    expect(await reminders.pending(), {9});
    expect(fake.calls, ['schedule 7', 'schedule 9', 'schedule 7', 'cancel 7', 'cancel 123']);
    expect([for (final reminder in fake.inOrder) reminder.id], [9]);
  });

  test('the fake answers the permission prompt as the test says, and counts the asking', () async {
    final fake = FakeReminders(granted: false);

    expect(await fake.requestPermission(), isFalse);
    fake.granted = true;
    expect(await fake.requestPermission(), isTrue);
    expect(fake.permissionRequests, 2);
  });

  test('no other file of the app imports the notification plugin or the time zone package', () {
    final plugin = RegExp('import\\s+[\'"]package:(flutter_local_notifications|timezone)');
    final importing = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && file.readAsStringSync().contains(plugin)) file.path.replaceAll(r'\', '/'),
    ];

    expect(importing, ['lib/platform/reminders.dart']);
  });

  test('the channel has one id, which the phone keeps the choices of its settings under', () {
    expect(PluginReminders.channelId, 'key_reminders');
  });
}
