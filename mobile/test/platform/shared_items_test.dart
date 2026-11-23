// What other apps share to Kemlock: what the channel hands over, and the
// item that waits for a vault to be opened (openspec: add-share-extension).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/keys/pgp.dart' show maxPgpTextLength;
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/platform/shared_items.dart';

import '../fakes/fake_shared_items.dart';
import '../helpers/test_app.dart';

const _channel = MethodChannel('com.kemlock.app/share');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('from the channel', () {
    test('a text', () {
      final item = SharedArrival.fromChannel({'text': 'Meet me at nine.'});
      expect(item, isA<SharedText>().having((t) => t.text, 'text', 'Meet me at nine.').having((t) => t.sharedAt, 'at', isNull));
    });

    test('a file: its path, name, size and media type', () {
      final item = SharedArrival.fromChannel({
        'path': '/cache/share/ab12/contract.pdf',
        'name': 'contract.pdf',
        'size': 52344,
        'type': 'application/pdf',
        'at': 1794889044000,
      });
      expect(
        item,
        isA<SharedFile>()
            .having((f) => f.path, 'path', '/cache/share/ab12/contract.pdf')
            .having((f) => f.name, 'name', 'contract.pdf')
            .having((f) => f.size, 'size', 52344)
            .having((f) => f.type, 'type', 'application/pdf')
            .having((f) => f.sharedAt, 'at', DateTime.fromMillisecondsSinceEpoch(1794889044000, isUtc: true)),
      );
    });

    test('a file without a name is named after its path', () {
      final item = SharedArrival.fromChannel({'path': '/cache/share/ab12/download.bin', 'size': 3});
      expect(item, isA<SharedFile>().having((f) => f.name, 'name', 'download.bin').having((f) => f.type, 'type', isNull));
    });

    test('a share the native side refused', () {
      expect(
        SharedArrival.fromChannel({'error': 'unreadable'}),
        isA<SharedRefused>().having((r) => r.problem, 'problem', SharedProblem.unreadable),
      );
      expect(
        SharedArrival.fromChannel({'error': 'noRoom'}),
        isA<SharedRefused>().having((r) => r.problem, 'problem', SharedProblem.noRoom),
      );
    });

    test('a map with neither a text nor a file is dropped', () {
      expect(SharedArrival.fromChannel(<String, Object?>{}), isNull);
      expect(SharedArrival.fromChannel({'name': 'contract.pdf', 'size': 3}), isNull);
      expect(SharedArrival.fromChannel({'text': ''}), isNull);
      expect(SharedArrival.fromChannel({'text': 42}), isNull);
      expect(SharedArrival.fromChannel('Meet me at nine.'), isNull);
      expect(SharedArrival.fromChannel(null), isNull);
    });

    test('a build without the native side gives no item and clears nothing', () async {
      final items = ChannelSharedItems();
      expect(await items.initial(), isNull);
      await items.clear();
    });

    test('the item the app was opened with, and one that arrives while it runs', () async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_channel, (call) async => call.method == 'initial' ? {'text': 'opened with'} : null);
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      final items = ChannelSharedItems();
      expect(await items.initial(), isA<SharedText>().having((t) => t.text, 'text', 'opened with'));

      final next = items.incoming.first;
      await messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(const MethodCall('item', {'text': 'while it runs'})),
        (_) {},
      );
      expect(await next, isA<SharedText>().having((t) => t.text, 'text', 'while it runs'));
    });
  });

  group('the waiting item', () {
    late Directory root;
    late FakeSharedItems shared;
    late DateTime now;
    late ProviderContainer container;

    setUp(() {
      root = Directory.systemTemp.createTempSync('share-test');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      shared = FakeSharedItems();
      now = testNow;
    });

    /// A test in fake time, so the ten minutes pass with `tester.pump`. Its
    /// container goes before the test ends, with the timer of an item still
    /// waiting, which flutter_test would otherwise find left behind.
    void testWaiting(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      container = ProviderContainer(
        overrides: [
          messageCatalogProvider.overrideWithValue(testCatalog),
          keyValueStoreProvider.overrideWithValue(KeyValueStore.memory()),
          clockProvider.overrideWithValue(() => now),
          shareTempRootProvider.overrideWithValue(() async => root),
          shared.asOverride,
        ],
      );
      try {
        await body(tester);
      } finally {
        container.dispose();
      }
    });

    /// Builds the waiting item, as the app does at start.
    void start() => container.listen(pendingShareProvider, (_, _) {});

    PendingShare pending() => container.read(pendingShareProvider.notifier);
    SharedItem? waiting() => container.read(pendingShareProvider);

    /// A file the native side copied into the share directory, written [age] ago.
    File copied(String name, {Duration age = Duration.zero, String content = 'shared'}) {
      final directory = Directory('${root.path}${Platform.pathSeparator}${name.hashCode.toRadixString(16)}')..createSync(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}$name')..writeAsStringSync(content);
      file.setLastModifiedSync(now.subtract(age));
      return file;
    }

    SharedFile itemOf(File file) => SharedFile(path: file.path, name: file.uri.pathSegments.last, size: file.lengthSync());

    Future<void> arrive(WidgetTester tester, SharedArrival arrival) async {
      shared.send(arrival);
      await tester.pump();
    }

    testWaiting('the item the app was opened with waits', (tester) async {
      shared.opening = const SharedText('opened with');
      start();
      await tester.pump();
      expect(waiting(), isA<SharedText>().having((t) => t.text, 'text', 'opened with'));
    });

    testWaiting('an item taken once is gone the second time', (tester) async {
      start();
      await arrive(tester, const SharedText('Meet me at nine.'));

      expect(pending().take(), isA<SharedText>().having((t) => t.text, 'text', 'Meet me at nine.'));
      expect(pending().take(), isNull);
      expect(waiting(), isNull);
    });

    testWaiting('a second item replaces the first, whose file is deleted', (tester) async {
      start();
      final first = copied('first.pdf');
      await arrive(tester, itemOf(first));
      await arrive(tester, const SharedText('the second'));

      expect(waiting(), isA<SharedText>().having((t) => t.text, 'text', 'the second'));
      expect(first.existsSync(), isFalse);
      expect(pending().take(), isA<SharedText>());
      expect(pending().take(), isNull);
    });

    testWaiting('an item is still there after nine minutes and gone after ten, with its file', (tester) async {
      start();
      final file = copied('contract.pdf');
      await arrive(tester, itemOf(file));

      await tester.pump(const Duration(minutes: 9));
      expect(waiting(), isA<SharedFile>());
      expect(file.existsSync(), isTrue);

      await tester.pump(const Duration(minutes: 1));
      expect(waiting(), isNull);
      expect(file.existsSync(), isFalse);
    });

    testWaiting('an item shared on the phone some minutes before it reached the app waits only what is left', (tester) async {
      start();
      await arrive(tester, SharedText('from the share screen', sharedAt: now.subtract(const Duration(minutes: 8))));

      await tester.pump(const Duration(minutes: 1, seconds: 59));
      expect(waiting(), isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(waiting(), isNull);

      // And one shared longer ago than that is never offered
      await arrive(tester, SharedText('an hour ago', sharedAt: now.subtract(const Duration(hours: 1))));
      expect(waiting(), isNull);
    });

    testWaiting('dropping a file item deletes its file; taking it does not', (tester) async {
      start();
      final dropped = copied('dropped.pdf');
      await arrive(tester, itemOf(dropped));
      pending().drop();
      expect(waiting(), isNull);
      expect(dropped.existsSync(), isFalse);

      final taken = copied('taken.pdf');
      await arrive(tester, itemOf(taken));
      final item = pending().take();
      expect(item, isA<SharedFile>().having((f) => f.path, 'path', taken.path));
      expect(taken.existsSync(), isTrue);

      // Nor does the ten minutes, once it is taken
      await tester.pump(const Duration(minutes: 11));
      expect(taken.existsSync(), isTrue);
    });

    testWaiting('a text longer than the sheets show becomes a file named shared.txt', (tester) async {
      start();
      final text = 'x' * (maxPgpTextLength + 1);
      await arrive(tester, SharedText(text));

      final item = waiting();
      expect(item, isA<SharedFile>().having((f) => f.name, 'name', 'shared.txt').having((f) => f.size, 'size', text.length));
      final file = File((item! as SharedFile).path);
      expect(file.readAsStringSync(), text);
      expect(file.parent.parent.path, root.path);

      // A text at the cap stays a text
      await arrive(tester, SharedText('y' * maxPgpTextLength));
      expect(waiting(), isA<SharedText>());
      expect(file.existsSync(), isFalse);
    });

    testWaiting('a refused share says why and leaves nothing waiting', (tester) async {
      start();
      final file = copied('contract.pdf');
      await arrive(tester, itemOf(file));
      await arrive(tester, const SharedRefused(SharedProblem.unreadable));

      expect(waiting(), isNull);
      expect(file.existsSync(), isFalse);
      expect(container.read(toastsProvider)?.message, t('share.unreadable'));

      await arrive(tester, const SharedRefused(SharedProblem.noRoom));
      expect(container.read(toastsProvider)?.message, t('share.noRoom'));
    });

    testWaiting('at start, files eleven minutes old are deleted and those nine minutes old are kept', (tester) async {
      final old = copied('old.pdf', age: const Duration(minutes: 11));
      final young = copied('young.pdf', age: const Duration(minutes: 9));
      start();
      await tester.pump();

      expect(old.existsSync(), isFalse);
      expect(old.parent.existsSync(), isTrue, reason: 'its directory was made just now');
      expect(young.existsSync(), isTrue);
    });

    testWaiting('on return to the front, the same; and the waiting file and one in use stay', (tester) async {
      start();
      await tester.pump();
      final old = copied('old.pdf', age: const Duration(minutes: 11));
      final young = copied('young.pdf', age: const Duration(minutes: 9));
      final inUse = copied('in-use.pdf', age: const Duration(minutes: 30));
      pending().inUse(inUse.path);
      final waitingFile = copied('waiting.pdf', age: const Duration(minutes: 30));
      await arrive(tester, itemOf(waitingFile));

      await pending().resumed();

      expect(old.existsSync(), isFalse);
      expect(young.existsSync(), isTrue);
      expect(inUse.existsSync(), isTrue);
      expect(waitingFile.existsSync(), isTrue);
      expect(waiting(), isNotNull);
    });

    testWaiting('on return to the front after the phone slept, an item shared ten minutes ago is forgotten', (tester) async {
      start();
      final file = copied('contract.pdf');
      await arrive(tester, itemOf(file));
      // The clock moved on while no timer ran
      now = now.add(const Duration(minutes: 10));

      await pending().resumed();
      expect(waiting(), isNull);
      expect(file.existsSync(), isFalse);
    });

    testWaiting('the sweep leaves an empty directory younger than ten minutes, and takes an old one', (tester) async {
      final fresh = Directory('${root.path}${Platform.pathSeparator}fresh')..createSync();
      sweepSharedFiles(root, DateTime.now());
      expect(fresh.existsSync(), isTrue);
      sweepSharedFiles(root, DateTime.now().add(const Duration(minutes: 11)));
      expect(fresh.existsSync(), isFalse);
    });

    testWaiting('wiping forgets the item, empties the directory and clears the native side once', (tester) async {
      start();
      final file = copied('contract.pdf');
      final other = copied('left.pdf');
      await arrive(tester, itemOf(file));

      await pending().wipe();

      expect(waiting(), isNull);
      expect(file.existsSync(), isFalse);
      expect(other.existsSync(), isFalse);
      expect(root.existsSync(), isFalse);
      expect(shared.clears, 1);
    });
  });
}
