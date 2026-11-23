import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

const _box = SizedBox(key: ValueKey('box'), width: 40, height: 40);

/// The phase of the loop [finder] finds, or null while it holds still.
double? _phase(WidgetTester tester, Finder finder) => tester.state<LoopState>(finder).phase.value;

/// The scale the nearest [Transform] above [finder] gives it.
double _scale(WidgetTester tester, Finder finder) =>
    tester.widget<Transform>(find.ancestor(of: finder, matching: find.byType(Transform)).first).transform.getMaxScaleOnAxis();

/// A column of [count] loops.
Widget _loops(int count) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [for (var i = 0; i < count; i++) const Breathe(child: SizedBox(width: 10, height: 10))],
);

/// A loop that goes there and back over 12 seconds each way, as the ambient light does.
class _Swing extends StatefulWidget {
  const _Swing();

  @override
  State<_Swing> createState() => _SwingState();
}

class _SwingState extends LoopState<_Swing> {
  @override
  Duration get period => const Duration(seconds: 12);

  @override
  bool get alternate => true;

  @override
  Widget build(BuildContext context) => _box;
}

/// A painter that counts how often it is painted.
class _CountingPainter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_CountingPainter old) => false;
}

/// Lets [seconds] pass a second at a time, as frames would.
Future<void> _wait(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  group('EffectsScope', () {
    testWidgets('pinned, gives every loop its phase with no ticker running', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const EffectsScope(
          pinned: 0.25,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Spin(child: SizedBox(key: ValueKey('spin'), width: 10, height: 10)),
              Breathe(
                curve: Curves.linear,
                child: SizedBox(key: ValueKey('breathe'), width: 10, height: 10),
              ),
              Halo(
                curve: Curves.linear,
                delay: Duration(seconds: 1),
                child: SizedBox(key: ValueKey('halo'), width: 10, height: 10),
              ),
            ],
          ),
        ),
      );
      for (final type in [Spin, Breathe, Halo]) {
        expect(_phase(tester, find.byType(type)), 0.25);
      }
      expect(_scale(tester, find.byKey(const ValueKey('breathe'))), closeTo(1.0175, 1e-9));
      expect(_scale(tester, find.byKey(const ValueKey('halo'))), closeTo(1.225, 1e-9));
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pump(const Duration(seconds: 3));
      expect(_phase(tester, find.byType(Breathe)), 0.25);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('lets the loops run again when the pin is taken away', (tester) async {
      Widget page(double? pinned) => MaterialApp(
        home: EffectsScope(
          pinned: pinned,
          child: const Center(
            child: Breathe(period: Duration(seconds: 2), curve: Curves.linear, child: _box),
          ),
        ),
      );
      await tester.pumpWidget(page(0.5));
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(page(null));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_phase(tester, find.byType(Breathe)), closeTo(0.25, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lets one route run six loops', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(child: _loops(6)));
      expect(tester.takeException(), isNull);
      final scope = tester.state<EffectsScopeState>(find.byType(EffectsScope).last);
      expect(scope.liveOn(ModalRoute.of(tester.element(find.byType(Breathe).first))), 6);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reports a seventh loop on one route as an error', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(child: _loops(7)));
      final error = tester.takeException();
      expect(error, isFlutterError);
      expect('$error', contains('more than 6 loops'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('counts the loops the pin holds, and none under reduced motion', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(pinned: 0.5, child: _loops(7)));
      expect(tester.takeException(), isFlutterError);

      await pumpOnPage(tester, EffectsScope(child: _loops(7)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('stops counting a loop that leaves the screen', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(child: _loops(6)));
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(child: _loops(3)));
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(child: _loops(6)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('absent, leaves the loops unpinned and never reports one too many', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              for (var i = 0; i < 8; i++)
                const Breathe(period: Duration(seconds: 2), curve: Curves.linear, child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      expect(find.byType(EffectsScope), findsNothing);
      expect(tester.takeException(), isNull);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_phase(tester, find.byType(Breathe).first), closeTo(0.5, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('a loop runs only while it can be seen', () {
    /// Whether the Breathe moves over the next 300ms.
    Future<bool> moves(WidgetTester tester) async {
      final before = _phase(tester, find.byType(Breathe));
      await tester.pump(const Duration(milliseconds: 300));
      return _phase(tester, find.byType(Breathe)) != before;
    }

    testWidgets('a sheet opened over its page stops it, and closing the sheet restarts it', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        EffectsScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Breathe(child: _box),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppBottomSheet<void>(context, label: 'Sheet', builder: (_) => const SizedBox(height: 200)),
                  child: const Text('Open'),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(await moves(tester), isTrue);

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await moves(tester), isFalse);
      final scope = tester.state<EffectsScopeState>(find.byType(EffectsScope).last);
      expect(scope.liveOn(ModalRoute.of(tester.element(find.byType(Breathe)))), 0);

      Navigator.of(tester.element(find.bySemanticsLabel('Sheet')), rootNavigator: true).pop();
      await tester.pump();
      await tester.pump();
      expect(await moves(tester), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(await moves(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('picks up where it stopped', (tester) async {
      Widget page({required bool open}) => MaterialApp(
        home: LoopGate(
          open: open,
          child: const Center(
            child: Breathe(period: Duration(seconds: 4), child: _box),
          ),
        ),
      );
      await tester.pumpWidget(page(open: true));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_phase(tester, find.byType(Breathe)), closeTo(0.25, 1e-9));

      await tester.pumpWidget(page(open: false));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(_phase(tester, find.byType(Breathe)), closeTo(0.25, 1e-9));

      await tester.pumpWidget(page(open: true));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_phase(tester, find.byType(Breathe)), closeTo(0.5, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a gate with no word of its own shuts when a sheet covers the route it is on', (tester) async {
      // As the tabs are: a page of a navigator of its own, which stays that navigator's current page under a sheet.
      await pumpScreen(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        EffectsScope(
          child: LoopGate(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Breathe(child: _box),
                        TextButton(
                          onPressed: () => showAppBottomSheet<void>(context, label: 'Sheet', builder: (_) => const SizedBox(height: 200)),
                          child: const Text('Open'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(await moves(tester), isTrue);

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await moves(tester), isFalse);

      Navigator.of(tester.element(find.bySemanticsLabel('Sheet')), rootNavigator: true).pop();
      await tester.pump();
      await tester.pump();
      expect(await moves(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the app leaving the front stops it, and coming back restarts it', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const EffectsScope(child: Breathe(child: _box)),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      for (final away in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(away);
        expect(tester.hasRunningAnimations, isFalse, reason: '$away');
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump();
      expect(await moves(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('scrolled out of a scroll view it stops, and back in view it runs', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        center: false,
        EffectsScope(
          child: SingleChildScrollView(
            controller: controller,
            child: const Column(
              children: [
                Breathe(child: _box),
                SizedBox(height: 3000),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      controller.jumpTo(1000);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(await moves(tester), isFalse);

      // Its last pixel row back in view is enough.
      controller.jumpTo(39);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump();
      expect(await moves(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('built out of view, it does not start until it is scrolled to', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        center: false,
        EffectsScope(
          child: SingleChildScrollView(
            controller: controller,
            child: const Column(
              children: [
                SizedBox(height: 3000),
                Breathe(child: _box),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('a decorative loop rests when the screen is left alone', () {
    testWidgets('a Breathe eases to rest 30 seconds after the last touch, and a tap restarts it', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const EffectsScope(
          child: Breathe(curve: Curves.linear, child: _box),
        ),
      );
      await tester.pump();
      await _wait(tester, 29);
      expect(tester.hasRunningAnimations, isTrue);
      expect(_phase(tester, find.byType(Breathe)), closeTo(0.25, 1e-9));

      // At 30 seconds it is half way through a period, which it finishes instead of jumping to its rest.
      await _wait(tester, 1);
      expect(_scale(tester, find.byKey(const ValueKey('box'))), closeTo(1.035, 1e-9));
      await _wait(tester, 1);
      expect(_scale(tester, find.byKey(const ValueKey('box'))), closeTo(1.0175, 1e-9));
      expect(tester.hasRunningAnimations, isTrue);
      await _wait(tester, 1);
      expect(_scale(tester, find.byKey(const ValueKey('box'))), 1);
      expect(_phase(tester, find.byType(Breathe)), 0);
      expect(tester.hasRunningAnimations, isFalse);

      await _wait(tester, 300);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.tap(find.byKey(const ValueKey('box')), warnIfMissed: false);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump();
      await _wait(tester, 1);
      expect(_phase(tester, find.byType(Breathe)), closeTo(0.25, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a touch before the 30 seconds are up puts the rest off', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const EffectsScope(child: Breathe(child: _box)),
      );
      await tester.pump();
      await _wait(tester, 20);
      await tester.tap(find.byKey(const ValueKey('box')), warnIfMissed: false);
      await _wait(tester, 29);
      expect(tester.hasRunningAnimations, isTrue);
      await _wait(tester, 5);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a loop that goes there and back turns round where it is and rests within a period', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const EffectsScope(child: _Swing()));
      await tester.pump();
      await _wait(tester, 30);
      // 6 seconds into its second way out.
      expect(_phase(tester, find.byType(_Swing)), closeTo(0.5, 1e-9));
      await _wait(tester, 3);
      expect(_phase(tester, find.byType(_Swing)), closeTo(0.25, 1e-9));
      expect(tester.hasRunningAnimations, isTrue);
      await _wait(tester, 3);
      expect(_phase(tester, find.byType(_Swing)), 0);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.tap(find.byKey(const ValueKey('box')), warnIfMissed: false);
      await tester.pump();
      await _wait(tester, 3);
      expect(_phase(tester, find.byType(_Swing)), closeTo(0.25, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a Spin is still turning after two minutes', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const EffectsScope(
          child: Spin(period: Duration(seconds: 4), child: _box),
        ),
      );
      await tester.pump();
      await _wait(tester, 121);
      expect(tester.hasRunningAnimations, isTrue);
      expect(_phase(tester, find.byType(Spin)), closeTo(0.25, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a Halo rests like the others, and a loop with no scope above it never does', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const EffectsScope(child: Halo(child: _box)),
      );
      await tester.pump();
      await _wait(tester, 34);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: Breathe(child: _box)),
        ),
      );
      await tester.pump();
      await _wait(tester, 120);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the test helpers hold the effects', () {
    testWidgets('a page with motion on, a Breathe and a Rise settles', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Breathe(curve: Curves.linear, child: _box),
            Rise(child: SizedBox(key: ValueKey('risen'), width: 40, height: 40)),
          ],
        ),
      );
      expect(tester.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('risen')), matching: find.byType(Opacity))).opacity, 0);

      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('risen')), matching: find.byType(Opacity))).opacity, 1);
      expect(_phase(tester, find.byType(Breathe)), 0.5);
      expect(_scale(tester, find.byKey(const ValueKey('box'))), closeTo(1.035, 1e-9));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('through a scope of the page'
        's own, as the app has one', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const EffectsScope(child: Breathe(child: _box)));
      await tester.pumpAndSettle();
      expect(_phase(tester, find.byType(Breathe)), 0.5);
    });

    testWidgets('and let them run when a test asks', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Breathe(child: _box));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('AmbientLight', () {
    const surface = Size(390, 844);

    /// The painters of the lights on the page, first light first.
    List<AmbientLightPainter> painters(WidgetTester tester) => [
      for (final paint in tester.widgetList<CustomPaint>(
        find.descendant(of: find.byType(AmbientLight), matching: find.byType(CustomPaint)),
      ))
        paint.painter! as AmbientLightPainter,
    ];

    test('puts the first light off the top right corner, and k-drift moves it 70 left and 50 down at 1.3 times the size', () {
      final start = AmbientLight.lightAt(0, surface, 0);
      // A 340 box 110 off the top and the right, fading out at 66% of the way to its corner.
      expect(start.center, const Offset(330, 60));
      expect(start.radius, closeTo(158.67, 0.01));

      final end = AmbientLight.lightAt(0, surface, 1);
      expect(end.center - start.center, const Offset(-70, 50));
      expect(end.radius / start.radius, closeTo(1.3, 1e-9));

      // Eased in and out: half way there at half its period, and less than a quarter of the way at a quarter.
      expect(AmbientLight.lightAt(0, surface, 0.5).center, const Offset(295, 85));
      expect(AmbientLight.lightAt(0, surface, 0.25).center.dx, greaterThan(330 - 70 / 4));
    });

    test('puts the second light at the bottom left, starting from the far end of the same drift', () {
      final rest = AmbientLight.lightAt(1, surface, null);
      expect(rest.center, const Offset(20, 624));
      expect(rest.radius, closeTo(149.34, 0.01));
      expect(AmbientLight.lightAt(1, surface, 0).center, const Offset(-50, 674));
      expect(AmbientLight.lightAt(1, surface, 1).center, rest.center);
    });

    testWidgets('paints one light or two in the scheme'
        's ambient colours, at the phase of its loop', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpOnPage(
          tester,
          reducedMotion: false,
          brightness: brightness,
          const EffectsScope(pinned: 1, child: SizedBox(width: 300, height: 400, child: AmbientLight(lights: 2))),
        );
        final lights = painters(tester);
        expect(lights.map((light) => light.color), [BmcTokens.of(brightness).ambient, BmcTokens.of(brightness).ambient2]);
        expect(lights.map((light) => light.phase.value), [1, 1]);
        expect(tester.hasRunningAnimations, isFalse);
      }

      await pumpOnPage(tester, const SizedBox(width: 300, height: 400, child: AmbientLight()));
      expect(painters(tester), hasLength(1));
    });

    testWidgets('drifts over 12 and 16 seconds, there and back', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const SizedBox(width: 300, height: 400, child: AmbientLight(lights: 2)),
      );
      await tester.pump();
      expect(painters(tester).map((light) => light.phase.value), [0, 0]);
      await _wait(tester, 6);
      expect(painters(tester).map((light) => light.phase.value), [closeTo(0.5, 1e-9), closeTo(0.375, 1e-9)]);
      await _wait(tester, 12);
      // The first is half way back; the second is at the end of its way out and about to turn.
      expect(painters(tester).map((light) => light.phase.value), [closeTo(0.5, 1e-9), closeTo(0.875, 1e-9)]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('holds both lights at their start under reduced motion, with nothing running', (tester) async {
      await pumpOnPage(tester, const SizedBox(width: 300, height: 400, child: AmbientLight(lights: 2)));
      await tester.pump(const Duration(seconds: 3));
      expect(painters(tester).map((light) => light.phase.value), [null, null]);
      expect(AmbientLight.lightAt(0, surface, null).center, AmbientLight.lightAt(0, surface, 0).center);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('has no semantics and lets a tap through, under a button and over one', (tester) async {
      var taps = 0;
      for (final lightOnTop in [false, true]) {
        final button = Center(
          child: TextButton(onPressed: () => taps++, child: const Text('Add')),
        );
        const light = Positioned.fill(child: AmbientLight(lights: 2));
        await pumpOnPage(tester, SizedBox(width: 300, height: 400, child: Stack(children: lightOnTop ? [button, light] : [light, button])));
        await tester.tap(find.text('Add'), warnIfMissed: false);
        expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['Add'], reason: 'only the button is read');
      }
      expect(taps, 2);
    });

    testWidgets('repaints only its own layer: a painter beside it is painted once while it runs for a second', (tester) async {
      final beside = _CountingPainter();
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        SizedBox(
          width: 300,
          height: 400,
          child: Stack(
            children: [
              const Positioned.fill(child: AmbientLight(lights: 2)),
              Positioned.fill(child: CustomPaint(painter: beside)),
            ],
          ),
        ),
      );
      final layers = tester.renderObjectList<RenderRepaintBoundary>(
        find.descendant(of: find.byType(AmbientLight), matching: find.byType(RepaintBoundary)),
      );
      for (final layer in layers) {
        layer.debugResetMetrics();
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(beside.paints, 1);
      // Each light was painted alone ten times, never with what is round it.
      expect(layers.map((layer) => layer.debugAsymmetricPaintCount), [10, 10]);
      expect(layers.map((layer) => layer.debugSymmetricPaintCount), [0, 0]);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Sheen', () {
    Finder band() => find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is SheenPainter);
    SheenPainter painter(WidgetTester tester) => tester.widget<CustomPaint>(band()).painter! as SheenPainter;
    List<BoxShadow>? shadow(WidgetTester tester) =>
        (tester.widget<DecoratedBox>(find.descendant(of: find.byType(Sheen), matching: find.byType(DecoratedBox)).first).decoration
                as BoxDecoration)
            .boxShadow;

    /// A main button 300 wide under a sheen held at [phase].
    Widget button({double? phase = 0.5, bool enabled = true, VoidCallback? onPressed}) => EffectsScope(
      pinned: phase,
      child: SizedBox(
        width: 300,
        child: Sheen(
          enabled: enabled,
          child: FilledButton(style: largeButtonStyle, onPressed: onPressed ?? () {}, child: const Text('Encrypt and share')),
        ),
      ),
    );

    test('keeps the band off the left edge until 62 hundredths of the period, and has it off the right edge at the end', () {
      const width = 300.0;
      final bandWidth = Sheen.bandWidth(width);
      expect(bandWidth, closeTo(114, 1e-9));
      for (final phase in [0.0, 0.3, 0.62]) {
        expect(Sheen.bandLeft(phase, width) + bandWidth, lessThan(0), reason: 'at $phase');
      }
      expect(Sheen.bandLeft(0.7, width), greaterThan(Sheen.bandLeft(0.62, width)));
      expect(Sheen.bandLeft(1, width), greaterThan(width));
      // 1.4 band widths off the left, and 3.4 from it at the end.
      expect(Sheen.bandLeft(0, width), closeTo(-1.4 * bandWidth, 1e-9));
      expect(Sheen.bandLeft(1, width), closeTo(3.4 * bandWidth, 1e-9));
    });

    test('is fainter and wider on a chip, and still starts and ends off it', () {
      const width = 100.0;
      final bandWidth = Sheen.bandWidth(width, faint: true);
      expect(bandWidth, closeTo(40, 1e-9));
      expect(Sheen.bandLeft(0.62, width, faint: true) + bandWidth, lessThan(0));
      expect(Sheen.bandLeft(1, width, faint: true), greaterThan(width));
    });

    testWidgets('paints nothing while the band waits, and a band while it crosses', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, button(phase: 0.3));
      expect(band(), paintsNothing);

      await pumpOnPage(tester, reducedMotion: false, button(phase: 0.8));
      expect(band(), paints..rect());
      expect(shadow(tester), StandingGlow.button(BmcTokens.dark));
    });

    testWidgets('crosses once every 4.5 seconds, the first time after 1.2, and a chip'
        's every 5.5 after 2', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Sheen(child: SizedBox(width: 300, height: 56)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(painter(tester).phase.value, 0);
      // Five seconds after it was shown the band has crossed once (spec: the main button of a sheet).
      await tester.pump(const Duration(milliseconds: 2800));
      expect(band(), paints..rect());
      await tester.pump(const Duration(milliseconds: 1700));
      expect(painter(tester).phase.value, 0);

      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Sheen(faint: true, child: SizedBox(width: 100, height: 32)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2000 + 2750));
      expect(painter(tester).phase.value, closeTo(0.5, 1e-9));
      expect(painter(tester).faint, isTrue);
      expect(shadow(tester), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('disabled, paints neither band nor shadow and runs nothing', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, button(phase: null, enabled: false));
      await tester.pump(const Duration(seconds: 4));
      expect(band(), paintsNothing);
      expect(painter(tester).phase.value, isNull);
      expect(shadow(tester), isNull);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('leaves the child the size it has without it', (tester) async {
      Widget row(Widget Function(Widget) wrap) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          wrap(FilledButton(style: largeButtonStyle, onPressed: () {}, child: const Text('Generate'))),
          const Text('after'),
        ],
      );
      await pumpOnPage(tester, row((child) => child));
      final plain = (tester.getRect(find.byType(FilledButton)), tester.getTopLeft(find.text('after')));
      await pumpOnPage(tester, row((child) => Sheen(child: child)));
      expect((tester.getRect(find.byType(FilledButton)), tester.getTopLeft(find.text('after'))), plain);

      await pumpOnPage(
        tester,
        Center(
          child: FilledButton(onPressed: () {}, child: const Text('Generate')),
        ),
      );
      final loose = tester.getSize(find.byType(FilledButton));
      await pumpOnPage(
        tester,
        Center(
          child: Sheen(
            child: FilledButton(onPressed: () {}, child: const Text('Generate')),
          ),
        ),
      );
      expect(tester.getSize(find.byType(FilledButton)), loose);
    });

    testWidgets('lets a tap through to the button while the band crosses it, and adds nothing for a screen reader', (tester) async {
      var presses = 0;
      await pumpOnPage(tester, reducedMotion: false, button(phase: 0.8, onPressed: () => presses++));
      expect(band(), paints..rect());
      await tester.tap(find.byType(FilledButton));
      expect(presses, 1);
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['Encrypt and share']);
    });

    for (final brightness in Brightness.values) {
      testWidgets('paints the band of a large filled button in the ${brightness.name} scheme'
          's sheen', (tester) async {
        await pumpOnPage(tester, reducedMotion: false, brightness: brightness, button(phase: 0.8));
        expect(painter(tester).color, BmcTokens.of(brightness).sheen);
        expect(band(), paints..rect());
        expect(shadow(tester), StandingGlow.button(BmcTokens.of(brightness)));
        // Clipped to the button's own corners.
        final clip = tester.widget<ClipRRect>(find.descendant(of: find.byType(Sheen), matching: find.byType(ClipRRect)).first);
        expect(clip.borderRadius, BorderRadius.circular(18));
      });
    }

    testWidgets('keeps the shadow and paints no band under reduced motion', (tester) async {
      await pumpOnPage(tester, effects: EffectsMode.running, button(phase: null));
      await tester.pump(const Duration(seconds: 4));
      expect(band(), paintsNothing);
      expect(shadow(tester), StandingGlow.button(BmcTokens.dark));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('Glow', () {
    /// How strong the glow round [child] is drawn, from 0 to 1.
    double strength(WidgetTester tester, Finder child) => tester
        .widget<Opacity>(
          find
              .descendant(
                of: find.ancestor(of: child, matching: find.byType(Glow)),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    GlowPainter painter(WidgetTester tester) =>
        tester
                .widget<CustomPaint>(find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is GlowPainter).first)
                .painter!
            as GlowPainter;

    const first = ValueKey('first');
    const second = ValueKey('second');

    /// Two option cards, each in a glow, with [selected] glowing.
    Widget options(Key selected) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final key in [first, second])
          Padding(
            padding: const EdgeInsets.all(8),
            child: Glow(
              active: key == selected,
              period: const Duration(seconds: 2),
              child: SizedBox(key: key, width: 200, height: 60),
            ),
          ),
      ],
    );

    test('is nothing at the start and the end of a period and full half way', () {
      expect(Glow.strengthAt(0), 0);
      expect(Glow.strengthAt(0.5), 1);
      expect(Glow.strengthAt(1), 0);
      expect(Glow.strengthAt(0.25), closeTo(0.5, 1e-9));
      expect(Glow.strengthAt(0.2), Glow.strengthAt(0.8));
      expect(Glow.strengthAt(null), 0);
    });

    testWidgets('swells to the glow token and back every 3.2 seconds, with a blur that stays 24', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpOnPage(
          tester,
          reducedMotion: false,
          effects: EffectsMode.running,
          brightness: brightness,
          const Glow(child: _box),
        );
        await tester.pump();
        expect(strength(tester, find.byKey(const ValueKey('box'))), 0);
        await tester.pump(const Duration(milliseconds: 1600));
        expect(strength(tester, find.byKey(const ValueKey('box'))), 1);
        expect(painter(tester).color, BmcTokens.of(brightness).glow);
        expect(painter(tester).blur, 24);
        await tester.pump(const Duration(milliseconds: 1600));
        expect(strength(tester, find.byKey(const ValueKey('box'))), 0);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('paints its shadow in a layer of its own, which a frame does not paint again', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Glow(child: _box));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final shadow = tester.renderObject<RenderRepaintBoundary>(
        find
            .ancestor(
              of: find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is GlowPainter),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      shadow.debugResetMetrics();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(shadow.debugSymmetricPaintCount + shadow.debugAsymmetricPaintCount, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('inactive, paints nothing and starts no ticker', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Glow(active: false, child: _box));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(strength(tester, find.byKey(const ValueKey('box'))), 0);
      expect(find.byType(Glow), paintsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('moves from one of two options to the other in the next frame', (tester) async {
      Widget page(Key selected) => MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Center(child: options(selected)),
      );
      await tester.pumpWidget(page(first));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(strength(tester, find.byKey(first)), 1);
      expect(strength(tester, find.byKey(second)), 0);

      await tester.pumpWidget(page(second));
      expect(strength(tester, find.byKey(first)), 0);
      expect(_phase(tester, find.ancestor(of: find.byKey(first), matching: find.byType(Glow))), isNull);
      expect(_phase(tester, find.ancestor(of: find.byKey(second), matching: find.byType(Glow))), 0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(strength(tester, find.byKey(first)), 0);
      expect(strength(tester, find.byKey(second)), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('paints no glow under reduced motion', (tester) async {
      await pumpOnPage(tester, effects: EffectsMode.running, const Glow(child: _box));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(strength(tester, find.byKey(const ValueKey('box'))), 0);
      expect(find.byType(Glow), paintsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('leaves its child where it was, takes no touch and has no semantics', (tester) async {
      var taps = 0;
      Widget page(Widget Function(Widget) wrap) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          wrap(TextButton(onPressed: () => taps++, child: const Text('Curve25519'))),
          const Text('after'),
        ],
      );
      await pumpOnPage(tester, page((child) => child));
      final plain = (tester.getRect(find.byType(TextButton)), tester.getTopLeft(find.text('after')));
      await pumpOnPage(tester, reducedMotion: false, page((child) => Glow(child: child)));
      expect((tester.getRect(find.byType(TextButton)), tester.getTopLeft(find.text('after'))), plain);

      await tester.tap(find.text('Curve25519'));
      expect(taps, 1);
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['Curve25519', 'after']);
    });
  });

  group('NeonBorder', () {
    Finder ring() => find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is NeonBorderPainter);
    NeonBorderPainter painter(WidgetTester tester) => tester.widget<CustomPaint>(ring()).painter! as NeonBorderPainter;

    const card = SizedBox(key: ValueKey('card'), width: 300, height: 120);

    test('has its bright point at the middle of the top edge at phase 0, and a quarter of the way round at a quarter', () {
      const size = Size(300, 120);
      expect(NeonBorder.hotAngle(0), 0);
      expect(NeonBorder.hotAngle(0.25), closeTo(math.pi / 2, 1e-9));
      Matcher at(double x, double y) =>
          isA<Offset>().having((o) => o.dx, 'dx', closeTo(x, 1e-6)).having((o) => o.dy, 'dy', closeTo(y, 1e-6));
      expect(NeonBorder.hotPoint(size, 0), at(150, 0));
      expect(NeonBorder.hotPoint(size, 0.25), at(300, 60));
      expect(NeonBorder.hotPoint(size, 0.5), at(150, 120));
      expect(NeonBorder.hotPoint(size, 0.75), at(0, 60));
    });

    testWidgets('travels the border once every 3.2 seconds, in the scheme'
        's accent up to its neonHot', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpOnPage(
          tester,
          reducedMotion: false,
          effects: EffectsMode.running,
          brightness: brightness,
          const NeonBorder(child: card),
        );
        await tester.pump();
        expect(painter(tester).phase.value, 0);
        await tester.pump(const Duration(milliseconds: 800));
        expect(painter(tester).phase.value, closeTo(0.25, 1e-9));
        await tester.pump(const Duration(milliseconds: 2400));
        expect(painter(tester).phase.value, closeTo(0, 1e-9));
        expect(painter(tester).body, AppPalette.of(brightness).primary);
        expect(painter(tester).hot, BmcTokens.of(brightness).neonHot);
        expect(
          ring(),
          paints
            ..drrect()
            ..drrect(),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lays its child out as a plain 1.5 padding does, and what comes after it too', (tester) async {
      Widget page(Widget Function(Widget) wrap) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          wrap(const SizedBox(key: ValueKey('card'), height: 120)),
          const Text('after'),
        ],
      );
      await pumpOnPage(tester, page((child) => Padding(padding: const EdgeInsets.all(1.5), child: child)));
      final plain = (tester.getRect(find.byKey(const ValueKey('card'))), tester.getTopLeft(find.text('after')));
      await pumpOnPage(tester, page((child) => NeonBorder(child: child)));
      expect((tester.getRect(find.byKey(const ValueKey('card'))), tester.getTopLeft(find.text('after'))), plain);
      expect(tester.getRect(ring()), tester.getRect(find.byKey(const ValueKey('card'))).inflate(1.5));
    });

    testWidgets('is an even accent line with the standing glow under reduced motion, and starts nothing', (tester) async {
      await pumpOnPage(tester, effects: EffectsMode.running, const NeonBorder(child: card));
      await tester.pump(const Duration(seconds: 1));
      expect(painter(tester).phase.value, isNull);
      expect(painter(tester).rest, BmcTokens.dark.accentLine);
      // One ring in one colour: no sweep over it.
      expect(ring(), paints..drrect(color: BmcTokens.dark.accentLine));
      expect(
        ring(),
        isNot(
          paints
            ..drrect()
            ..drrect(),
        ),
      );
      final glow = tester.widget<DecoratedBox>(find.descendant(of: find.byType(NeonBorder), matching: find.byType(DecoratedBox)).first);
      expect((glow.decoration as BoxDecoration).boxShadow, StandingGlow.card(BmcTokens.dark));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('takes no touch and has no semantics', (tester) async {
      var taps = 0;
      await pumpOnPage(
        tester,
        reducedMotion: false,
        NeonBorder(
          child: TextButton(onPressed: () => taps++, child: const Text('YubiKey 5C NFC, connected over USB')),
        ),
      );
      await tester.tap(find.byType(TextButton));
      expect(taps, 1);
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['YubiKey 5C NFC, connected over USB']);
    });
  });

  group('ScanLine', () {
    Finder band() => find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is ScanLinePainter);
    ScanLinePainter painter(WidgetTester tester) => tester.widget<CustomPaint>(band()).painter! as ScanLinePainter;

    const fingerprint = '7A3F 91C2 0B5E D418 66AF\n2C90 E1B7 5D03 F8A4 19CE';

    Widget scanned({double? phase}) => EffectsScope(
      pinned: phase,
      child: const ScanLine(child: SelectableText(fingerprint)),
    );

    test('has its band wholly above the child at phase 0 and wholly below it at 1', () {
      const height = 100.0;
      expect(ScanLine.bandHeight(height), closeTo(42, 1e-9));
      expect(ScanLine.bandTop(0, height) + ScanLine.bandHeight(height), lessThan(0));
      expect(ScanLine.bandTop(1, height), greaterThan(height));
      // 110% of its height above the top, and 290% below it at the end, half way between at half the period.
      expect(ScanLine.bandTop(0, height), closeTo(-46.2, 1e-9));
      expect(ScanLine.bandTop(1, height), closeTo(121.8, 1e-9));
      expect(ScanLine.bandTop(0.5, height), closeTo(37.8, 1e-9));
    });

    testWidgets('paints nothing at each end of its pass and the band with its edge in between, clipped to the child', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, scanned(phase: 0));
      expect(band(), paintsNothing);
      await pumpOnPage(tester, reducedMotion: false, scanned(phase: 1));
      expect(band(), paintsNothing);

      await pumpOnPage(tester, reducedMotion: false, scanned(phase: 0.5));
      expect(
        band(),
        paints
          ..rect()
          ..rect(color: BmcTokens.dark.accentText.withValues(alpha: 0.55)),
      );
      expect(painter(tester).color, BmcTokens.dark.accentSoft);
      expect(find.ancestor(of: band(), matching: find.byType(ClipRect)), findsOneWidget);
      expect(tester.getRect(band()), tester.getRect(find.byType(SelectableText)));
    });

    testWidgets('passes every 3.2 seconds, the first time after 1', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, scanned());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(painter(tester).phase.value, 0);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(painter(tester).phase.value, closeTo(0.5, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('paints no band under reduced motion', (tester) async {
      await pumpOnPage(tester, effects: EffectsMode.running, scanned());
      await tester.pump(const Duration(seconds: 3));
      expect(painter(tester).phase.value, isNull);
      expect(band(), paintsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('leaves the text under it selectable while the band lies over it', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, scanned(phase: 0.5));
      // A long press on the first group, under the band, selects it.
      await tester.longPressAt(tester.getTopLeft(find.byType(SelectableText)) + const Offset(20, 8));
      await tester.pump();
      final selection = tester.widget<EditableText>(find.byType(EditableText)).controller.selection;
      expect(selection.isCollapsed, isFalse);
      expect(selection.textInside(fingerprint), '7A3F');
    });

    testWidgets('leaves the child'
        's size and semantics as they are without it', (tester) async {
      await pumpOnPage(tester, const SelectableText(fingerprint));
      final size = tester.getSize(find.byType(SelectableText));
      final labels = tester.semantics.simulatedAccessibilityTraversal().map((node) => (node.label, node.value)).toList();

      await pumpOnPage(tester, reducedMotion: false, scanned(phase: 0.5));
      expect(tester.getSize(find.byType(SelectableText)), size);
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => (node.label, node.value)).toList(), labels);
    });
  });

  group('Reveal', () {
    const message = 'Meet at the north gate at nine.';

    RevealClip clip(WidgetTester tester) => tester.widget<RevealClip>(find.byType(RevealClip));
    double sigma(WidgetTester tester) {
      // The filter says its sigmas in its description: "ImageFilter.blur(3.0, 3.0, decal)".
      final text = '${tester.widget<ImageFiltered>(find.byType(ImageFiltered)).imageFilter}';
      return double.parse(RegExp(r'blur\(([\d.]+)').firstMatch(text)!.group(1)!);
    }

    testWidgets('uncovers the text from its start while a blur of 6 and an opacity of .3 go to none, over 1.4 seconds after .8', (
      tester,
    ) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Reveal(child: Text(message)));
      final size = tester.getSize(find.text(message));
      expect(clip(tester).revealed, 0);
      expect(sigma(tester), 6);
      expect(tester.widget<Opacity>(find.ancestor(of: find.text(message), matching: find.byType(Opacity))).opacity, closeTo(0.3, 1e-9));

      await tester.pump(const Duration(milliseconds: 800));
      expect(clip(tester).revealed, 0, reason: 'still waiting');

      // Half way through: part of the text is covered and it is still blurred.
      await tester.pump(const Duration(milliseconds: 700));
      final half = Ease.out.transform(0.5);
      expect(clip(tester).revealed, closeTo(half, 1e-6));
      expect(clip(tester).revealed, inExclusiveRange(0, 1));
      expect(
        RevealClip.rectFor(size, clip(tester).revealed, TextDirection.ltr),
        Rect.fromLTWH(0, 0, size.width * clip(tester).revealed, size.height),
      );
      expect(sigma(tester), closeTo(6 * (1 - half), 0.05));
      expect(
        tester.widget<Opacity>(find.ancestor(of: find.text(message), matching: find.byType(Opacity))).opacity,
        closeTo(0.3 + 0.7 * half, 1e-6),
      );
      expect(tester.getSize(find.text(message)), size);

      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(RevealClip), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.ancestor(of: find.text(message), matching: find.byType(Opacity)), findsNothing);
      expect(tester.getSize(find.text(message)), size);
      // The controller ends on the first frame past its duration.
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('gives a screen reader the whole text from the first frame', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Reveal(child: Text(message)));
      expect(clip(tester).revealed, 0);
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), [message]);
      await tester.pumpAndSettle();
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), [message]);
    });

    testWidgets('does not play again on a rebuild after it has ended, and keeps its child'
        's state through the reveal', (tester) async {
      late StateSetter rebuild;
      var builds = 0;
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            builds++;
            return const Reveal(
              child: SizedBox(width: 200, child: TextField(key: ValueKey('field'))),
            );
          },
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('field')), 'typed during the reveal');
      await tester.pumpAndSettle();
      expect(find.text('typed during the reveal'), findsOneWidget);
      expect(find.byType(RevealClip), findsNothing);

      rebuild(() {});
      await tester.pump();
      expect(builds, 2);
      expect(find.byType(RevealClip), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.text('typed during the reveal'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('shows the whole text at once under reduced motion, and under the pin', (tester) async {
      await pumpOnPage(tester, effects: EffectsMode.running, const Reveal(child: Text(message)));
      expect(find.byType(RevealClip), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);

      await pumpOnPage(tester, reducedMotion: false, const Reveal(child: Text(message)));
      expect(find.text(message), findsOneWidget);
      expect(find.byType(RevealClip), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('goes to its end when reduced motion comes while it plays', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const Reveal(child: Text(message)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RevealClip), findsOneWidget);
      useReducedMotion(tester);
      await tester.pump();
      await tester.pump();
      expect(find.byType(RevealClip), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('uncovers from the right where text runs right to left', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Directionality(
          textDirection: TextDirection.rtl,
          child: Reveal(child: Text('نلتقي عند البوابة الشمالية في التاسعة.')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      expect(clip(tester).textDirection, TextDirection.rtl);
      const size = Size(200, 20);
      final shown = RevealClip.rectFor(size, 0.25, TextDirection.rtl);
      expect(shown, const Rect.fromLTWH(150, 0, 50, 20));
      expect(RevealClip.rectFor(size, 0.25, TextDirection.ltr), const Rect.fromLTWH(0, 0, 50, 20));
      await tester.pumpAndSettle();
    });
  });

  group('the count of a route'
      's loops', () {
    testWidgets('leaves out spinners, which say the app is working: the lock screen'
        's dial alone turns five', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        EffectsScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 8; i++) const Spin(child: SizedBox(width: 10, height: 10)),
              for (var i = 0; i < 6; i++) const Halo(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final scope = tester.state<EffectsScopeState>(find.byType(EffectsScope).last);
      expect(scope.liveOn(ModalRoute.of(tester.element(find.byType(Spin).first))), 6);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('can be raised by a scope, for a board that shows every effect at once', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(loopLimit: 8, child: _loops(8)));
      expect(tester.takeException(), isNull);
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, EffectsScope(loopLimit: 8, child: _loops(9)));
      expect('${tester.takeException()}', contains('more than 8 loops'));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
