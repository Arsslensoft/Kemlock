import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

/// Pumps a page with a button that runs [onPressed] with the page's context.
Future<void> _pumpPage(WidgetTester tester, void Function(BuildContext context) onPressed, {bool reducedMotion = true}) => pumpOnPage(
  tester,
  reducedMotion: reducedMotion,
  Builder(
    builder: (context) => TextButton(onPressed: () => onPressed(context), child: const Text('Go')),
  ),
);

void main() {
  testWidgets('shows the message, then goes after three seconds', (tester) async {
    await _pumpPage(tester, (context) => showToast(context, 'Code copied'));
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(find.text('Code copied'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.text('Code copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Code copied'), findsNothing);
  });

  testWidgets('stays five seconds with an action, which runs and closes it', (tester) async {
    var undone = 0;
    await _pumpPage(
      tester,
      (context) => showToast(
        context,
        'GitHub deleted',
        action: ToastAction(label: 'Undo', onPressed: () => undone++),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('GitHub deleted'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undone, 1);
    expect(find.text('GitHub deleted'), findsNothing);
  });

  testWidgets('goes after five seconds when the action is not taken', (tester) async {
    await _pumpPage(
      tester,
      (context) => showToast(
        context,
        'GitHub deleted',
        action: ToastAction(label: 'Undo', onPressed: () {}),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('GitHub deleted'), findsNothing);
  });

  testWidgets('a new toast replaces the last one and gets its own time', (tester) async {
    var count = 0;
    await _pumpPage(tester, (context) => showToast(context, 'Toast ${++count}'));
    await tester.tap(find.text('Go'));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(find.text('Toast 1'), findsNothing);
    expect(find.text('Toast 2'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Toast 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Toast 2'), findsNothing);
  });

  testWidgets('leaves taps elsewhere to the page', (tester) async {
    var taps = 0;
    await _pumpPage(tester, (context) {
      taps++;
      showToast(context, 'Saved');
    });
    await tester.tap(find.text('Go'));
    await tester.pump();
    await tester.tap(find.text('Go'));
    expect(taps, 2);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('marks each severity with its own dot', (tester) async {
    for (final (severity, glyph, dot) in [
      (ToastSeverity.success, Icons.check_rounded, AppPalette.dark.primary),
      (ToastSeverity.error, Icons.priority_high_rounded, AppPalette.dark.error),
      (ToastSeverity.info, Icons.lock_rounded, BmcTokens.dark.line2),
    ]) {
      await _pumpPage(tester, (context) => showToast(context, 'Message', severity: severity));
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(find.byIcon(glyph), findsOneWidget, reason: severity.name);
      final circle = tester.widget<Container>(find.ancestor(of: find.byIcon(glyph), matching: find.byType(Container)).first);
      expect((circle.decoration! as BoxDecoration).color, dot, reason: severity.name);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('is announced as it appears', (tester) async {
    await _pumpPage(tester, (context) => showToast(context, 'Vault locked', severity: ToastSeverity.info));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('Vault locked')), isSemantics(label: 'Vault locked', isLiveRegion: true));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('floats 98 points above the home bar, centred', (tester) async {
    await _pumpPage(tester, (context) => showToast(context, 'Saved'));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final bottomInset = tester.view.padding.bottom / tester.view.devicePixelRatio;
    final pill = find.ancestor(of: find.text('Saved'), matching: find.byType(Container)).last;
    expect(tester.getBottomLeft(pill).dy, closeTo(screen.height - bottomInset - 98, 0.5));
    expect(tester.getCenter(pill).dx, closeTo(screen.width / 2, 0.5));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('shows over an open dialog', (tester) async {
    await _pumpPage(tester, (context) {
      unawaited(
        showAppDialog<void>(
          context,
          builder: (context) => AppDialog(
            content: TextButton(onPressed: () => showToast(context, 'From the dialog'), child: const Text('Copy')),
          ),
        ),
      );
    });
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('From the dialog').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('shrinks and fades out as it goes', (tester) async {
    await _pumpPage(tester, reducedMotion: false, (context) => showToast(context, 'Saved'));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));
    final opacities = tester.widgetList<Opacity>(find.ancestor(of: find.text('Saved'), matching: find.byType(Opacity)));
    expect(opacities.fold(1.0, (value, o) => value * o.opacity), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);
  });

  test('stays three seconds, or five with an action', () {
    expect(toastDuration(hasAction: false), const Duration(seconds: 3));
    expect(toastDuration(hasAction: true), const Duration(seconds: 5));
  });
}
