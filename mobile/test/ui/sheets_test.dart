import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

/// Pumps a page with one button that runs [open] with the page's context.
Future<void> _pumpOpener(WidgetTester tester, void Function(BuildContext context) open, {Brightness brightness = Brightness.dark}) =>
    pumpOnPage(
      tester,
      brightness: brightness,
      Builder(
        builder: (context) => TextButton(onPressed: () => open(context), child: const Text('Open')),
      ),
    );

void main() {
  group('showAppBottomSheet', () {
    testWidgets('shows the content under a grab handle, named for screen readers', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(showAppBottomSheet<void>(context, label: 'GitHub', builder: (_) => const Text('492 018'))),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('492 018'), findsOneWidget);
      expect(find.byType(SheetHandle), findsOneWidget);
      expect(find.bySemanticsLabel('GitHub'), findsOneWidget);
    });

    testWidgets('opens over the whole app from a page in a nested navigator, as the tabs are', (tester) async {
      final tabs = GlobalKey<NavigatorState>();
      await pumpOnPage(
        tester,
        center: false,
        Navigator(
          key: tabs,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => unawaited(showAppBottomSheet<void>(context, label: 'GitHub', builder: (_) => const Text('Inside'))),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Inside'), findsOneWidget);
      expect(find.descendant(of: find.byKey(tabs), matching: find.text('Inside')), findsNothing);
    });

    testWidgets('resolves to what the sheet pops with', (tester) async {
      String? result;
      await _pumpOpener(tester, (context) async {
        result = await showAppBottomSheet<String>(
          context,
          label: 'Pick',
          builder: (context) => TextButton(onPressed: () => Navigator.pop(context, 'qr'), child: const Text('Show QR')),
        );
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show QR'));
      await tester.pumpAndSettle();

      expect(result, 'qr');
      expect(find.byType(AppBottomSheet), findsNothing);
    });

    testWidgets('closes on a tap outside', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(showAppBottomSheet<void>(context, label: 'GitHub', builder: (_) => const Text('Inside'))),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Inside'), findsNothing);
    });

    testWidgets('closes when dragged down', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(
          showAppBottomSheet<void>(
            context,
            label: 'GitHub',
            builder: (_) => const SizedBox(height: 300, child: Text('Inside')),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('Inside'), const Offset(0, 400));
      await tester.pumpAndSettle();

      expect(find.text('Inside'), findsNothing);
    });

    testWidgets('stays put on a tap outside when it is not dismissible', (tester) async {
      await _pumpOpener(
        tester,
        (context) =>
            unawaited(showAppBottomSheet<void>(context, label: 'GitHub', isDismissible: false, builder: (_) => const Text('Inside'))),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Inside'), findsOneWidget);
    });

    testWidgets('blurs the page behind the scrim', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(showAppBottomSheet<void>(context, label: 'GitHub', builder: (_) => const Text('Inside'))),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final blur = tester.widget<BackdropFilter>(find.descendant(of: find.byType(BlurredBarrier), matching: find.byType(BackdropFilter)));
      expect(blur.enabled, isTrue);
    });

    testWidgets('keeps 40px of the screen clear above it', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(
          showAppBottomSheet<void>(
            context,
            label: 'Long',
            builder: (_) => ListView(children: [for (var i = 0; i < 60; i++) Text('Row $i')]),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final top = tester.getTopLeft(find.byType(AppBottomSheet)).dy;
      expect(top, greaterThanOrEqualTo(40));
      expect(tester.getSize(find.byType(AppBottomSheet)).height, lessThanOrEqualTo(screen.height - 40));
    });
  });

  group('showConfirmDialog', () {
    Future<bool?> open(WidgetTester tester, {bool danger = true, Widget? icon}) async {
      bool? result;
      await _pumpOpener(tester, (context) async {
        result = await showConfirmDialog(
          context,
          icon: icon,
          title: 'Delete GitHub?',
          body: const Text('Its codes stop on this phone.'),
          confirmLabel: 'Delete',
          cancelLabel: 'Cancel',
          danger: danger,
        );
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('resolves to true when confirmed', (tester) async {
      bool? result;
      await _pumpOpener(tester, (context) async {
        result = await showConfirmDialog(
          context,
          title: 'Delete GitHub?',
          body: const Text('Its codes stop on this phone.'),
          confirmLabel: 'Delete',
          cancelLabel: 'Cancel',
        );
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Its codes stop on this phone.'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byType(ConfirmDialog), findsNothing);
    });

    testWidgets('resolves to false when cancelled or dismissed', (tester) async {
      final results = <bool>[];
      await _pumpOpener(tester, (context) async {
        results.add(
          await showConfirmDialog(context, title: 'Delete?', body: const Text('Gone.'), confirmLabel: 'Delete', cancelLabel: 'Cancel'),
        );
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(results, [false, false]);
    });

    testWidgets('is named by its title and marks the title as a heading', (tester) async {
      await open(tester);
      expect(find.bySemanticsLabel('Delete GitHub?'), findsWidgets);
      expect(tester.getSemantics(find.text('Delete GitHub?')), isSemantics(label: 'Delete GitHub?', isHeader: true));
    });

    testWidgets('paints the confirm button red when it is dangerous', (tester) async {
      await open(tester);
      final button = find.widgetWithText(FilledButton, 'Delete');
      final material = tester.widget<Material>(find.descendant(of: button, matching: find.byType(Material)).first);
      expect(material.color, AppPalette.dark.error);
    });

    testWidgets('paints the confirm button Azure when it is not', (tester) async {
      await open(tester, danger: false);
      final button = find.widgetWithText(FilledButton, 'Delete');
      final material = tester.widget<Material>(find.descendant(of: button, matching: find.byType(Material)).first);
      expect(material.color, AppPalette.dark.primary);
    });

    testWidgets('puts the icon in a red tile when dangerous', (tester) async {
      await open(tester, icon: const Icon(Icons.delete_outline_rounded));
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      expect(IconTheme.of(tester.element(find.byIcon(Icons.delete_outline_rounded))).color, AppPalette.dark.error);
    });
  });

  group('AppDialog', () {
    testWidgets('scrolls long content and keeps its actions in view', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(
          showAppDialog<void>(
            context,
            builder: (_) => AppDialog(
              heading: const DialogHeading(title: 'Terms'),
              content: Column(children: [for (var i = 0; i < 80; i++) Text('Clause $i')]),
              actions: [TextButton(onPressed: () {}, child: const Text('Agree'))],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Agree').hitTestable(), findsOneWidget);
      expect(find.text('Clause 79').hitTestable(), findsNothing);
    });

    testWidgets('is at most 444 wide with 32 around it', (tester) async {
      await _pumpOpener(
        tester,
        (context) => unawaited(showAppDialog<void>(context, builder: (_) => const AppDialog(content: Text('Hello')))),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final width = tester.getSize(find.descendant(of: find.byType(AppDialog), matching: find.byType(DecoratedBox)).first).width;
      expect(width, screen.width > 444 + 64 ? 444 : screen.width - 64);
    });
  });

  group('DialogHeading', () {
    testWidgets('shows the title alone without an icon', (tester) async {
      await pumpOnPage(tester, const DialogHeading(title: 'Export'));
      expect(find.text('Export'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('the sheet'
      's ambient light', () {
    Finder light() => find.descendant(of: find.byType(AppBottomSheet), matching: find.byType(AmbientLight));

    Future<void> open(WidgetTester tester, {bool reducedMotion = true, EffectsMode effects = EffectsMode.pinned, Widget? page}) async {
      await pumpOnPage(
        tester,
        reducedMotion: reducedMotion,
        effects: effects,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?page,
            Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  showAppBottomSheet<void>(
                    context,
                    label: 'GitHub',
                    builder: (_) => const SizedBox(height: 300, child: Center(child: Text('492 018'))),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ],
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('is one light that fills the sheet under its content, inside the clip of its rounded top', (tester) async {
      await open(tester);
      expect(light(), findsOneWidget);
      expect(tester.widget<AmbientLight>(light()).lights, 1);
      expect(tester.getRect(light()), tester.getRect(find.byType(AppBottomSheet)));

      final clip = tester.widget<ClipRRect>(find.ancestor(of: light(), matching: find.byType(ClipRRect)).first);
      expect(clip.borderRadius, const BorderRadius.vertical(top: Radius.circular(sheetRadius)));
      expect(find.descendant(of: find.byType(AppBottomSheet), matching: find.byType(ClipRRect)), findsOneWidget);

      // Built before the content, which is painted over it.
      final order = <String>[];
      void visit(Element element) {
        if (element.widget is AmbientLight) order.add('light');
        if (element.widget is SheetHandle) order.add('content');
        element.visitChildren(visit);
      }

      tester.element(find.byType(AppBottomSheet)).visitChildren(visit);
      expect(order, ['light', 'content']);
    });

    testWidgets('leaves the sheet as tall as its content, under its name', (tester) async {
      await open(tester);
      expect(tester.getSize(find.byType(AppBottomSheet)).height, 300 + 15);
    });

    testWidgets('runs while the sheet is open, and the loops of the page under it stop until it closes', (tester) async {
      await open(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        page: const Breathe(child: SizedBox(width: 40, height: 40)),
      );
      double? phase(Finder finder) => tester.state<LoopState>(finder).phase.value;
      final sheetLight = find.descendant(
        of: light(),
        matching: find.byElementPredicate((element) => element is StatefulElement && element.state is LoopState),
      );

      final before = (phase(sheetLight), phase(find.byType(Breathe)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(phase(sheetLight), isNot(before.$1));
      expect(phase(find.byType(Breathe)), before.$2);

      Navigator.of(tester.element(find.byType(AppBottomSheet)), rootNavigator: true).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(phase(find.byType(Breathe)), isNot(before.$2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('holds still under reduced motion', (tester) async {
      await open(tester, effects: EffectsMode.running);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
