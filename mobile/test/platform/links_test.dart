// A link asks before the browser opens while offline mode is on (openspec: add-offline-mode,
// "A link asks before the browser opens").
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/links.dart';
import 'package:kemlock/platform/network.dart';

import '../helpers/test_app.dart';

/// Stands in for the browser: keeps the links opened.
class _Browser implements LinkLauncher {
  final opened = <Uri>[];

  @override
  Future<bool> launch(Uri url) async {
    opened.add(url);
    return true;
  }
}

final _link = Uri.parse('https://example.org/account/security?tab=2fa');

/// A page with a link, the fake browser behind it, and what tapping the link resolved to.
class _Page {
  final browser = _Browser();
  final results = <bool>[];
  late final ProviderContainer container;

  Future<void> pump(WidgetTester tester, {required bool offline, Uri? link}) async {
    container = await pumpOnPage(
      tester,
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () async => results.add(await ref.read(linkOpenerProvider).open(context, link ?? _link)),
          child: const Text('Security settings'),
        ),
      ),
      overrides: [linkLauncherProvider.overrideWithValue(browser)],
    );
    if (offline) container.read(offlineProvider.notifier).set(true);
    await tester.tap(find.text('Security settings'));
    await tester.pumpAndSettle();
  }
}

void main() {
  /// What the phone's clipboard was last given.
  String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

  testWidgets('opens at once while offline mode is off', (tester) async {
    final page = _Page();
    await page.pump(tester, offline: false);

    expect(page.browser.opened, [_link]);
    expect(page.results, [true]);
    expect(find.text(t('offline.link.title')), findsNothing);
  });

  testWidgets('shows the address and what will go online, and opens nothing by itself, while offline mode is on', (tester) async {
    final page = _Page();
    await page.pump(tester, offline: true);

    expect(find.text(t('offline.link.title')), findsOneWidget);
    expect(find.text(t('offline.link.body')), findsOneWidget);
    expect(find.text(_link.toString()), findsOneWidget);
    for (final action in ['offline.link.open', 'offline.link.copy', 'changePw.cancel']) {
      final button = find.ancestor(of: find.text(t(action)), matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
      expect(button, findsOneWidget, reason: action);
    }
    expect(page.browser.opened, isEmpty);
    expect(page.results, isEmpty);
  });

  testWidgets('"Open in browser" opens it', (tester) async {
    final page = _Page();
    await page.pump(tester, offline: true);

    await tester.tap(find.text(t('offline.link.open')));
    await tester.pumpAndSettle();

    expect(page.browser.opened, [_link]);
    expect(page.results, [true]);
    expect(find.text(t('offline.link.title')), findsNothing);
  });

  testWidgets('"Copy link" puts the address on the clipboard and opens nothing', (tester) async {
    final page = _Page();
    await page.pump(tester, offline: true);

    await tester.tap(find.text(t('offline.link.copy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(copied, _link.toString());
    expect(find.text(t('offline.link.copied')), findsOneWidget);
    expect(page.browser.opened, isEmpty);
    expect(page.results, [false]);
    // Past the toast, so no timer outlives the test
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('"Cancel" neither opens nor copies', (tester) async {
    final page = _Page();
    await page.pump(tester, offline: true);

    await tester.tap(find.text(t('changePw.cancel')));
    await tester.pumpAndSettle();

    expect(page.browser.opened, isEmpty);
    expect(copied, isNull);
    expect(page.results, [false]);
  });

  for (final offline in [false, true]) {
    testWidgets('opens nothing but a web page, and asks nothing, ${offline ? 'with' : 'without'} offline mode', (tester) async {
      for (final link in [
        'intent://scan/#Intent;scheme=zxing;package=com.example;end',
        'file:///data/data/com.kemlock.app/shared_prefs/vault.xml',
        'tel:+15555550100',
        'javascript:alert(1)',
        'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP',
      ]) {
        final page = _Page();
        await page.pump(tester, offline: offline, link: Uri.parse(link));

        expect(page.browser.opened, isEmpty, reason: link);
        expect(page.results, [false], reason: link);
        expect(find.text(t('offline.link.title')), findsNothing, reason: link);
      }

      final page = _Page();
      await page.pump(tester, offline: false, link: Uri.parse('HTTP://example.org/'));
      expect(page.browser.opened, [Uri.parse('http://example.org/')]);
    });
  }

  testWidgets('a tap outside the dialog neither opens nor copies', (tester) async {
    final page = _Page();
    await page.pump(tester, offline: true);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text(t('offline.link.title')), findsNothing);
    expect(page.browser.opened, isEmpty);
    expect(copied, isNull);
  });
}
