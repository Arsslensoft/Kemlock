import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

const _box = SizedBox(key: ValueKey('box'), width: 40, height: 40);

/// The opacity painted over the box, or 1 when nothing fades it.
double _opacity(WidgetTester tester) {
  final opacities = tester.widgetList<Opacity>(find.ancestor(of: find.byKey(const ValueKey('box')), matching: find.byType(Opacity)));
  return opacities.fold(1.0, (value, o) => value * o.opacity);
}

/// The transform applied to the box by the nearest [Transform] above it.
Matrix4 _transform(WidgetTester tester) =>
    tester.widget<Transform>(find.ancestor(of: find.byKey(const ValueKey('box')), matching: find.byType(Transform)).first).transform;

void main() {
  group('Ease', () {
    test('carries the curves of theme.ts', () {
      expect(Ease.standard, const Cubic(.2, 0, 0, 1));
      expect(Ease.sheet, const Cubic(.32, .72, 0, 1));
      expect(Ease.roll, const Cubic(.2, .9, .1, 1));
      expect(Ease.out, const Cubic(.2, .8, .2, 1));
    });
  });

  group('Rise', () {
    testWidgets('fades in while rising 12px, after its delay', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const Rise(delay: Duration(milliseconds: 100), child: _box));
      expect(_opacity(tester), 0);
      expect(_transform(tester).getTranslation().y, 12);

      await tester.pump(const Duration(milliseconds: 80));
      expect(_opacity(tester), 0, reason: 'still waiting for its delay');

      await tester.pump(const Duration(milliseconds: 250));
      expect(_opacity(tester), inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
      expect(_transform(tester).getTranslation().y, 0);
    });

    testWidgets('keeps the child'
        's state once it has risen', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const Rise(child: TextField(key: ValueKey('field'))));
      await tester.enterText(find.byKey(const ValueKey('field')), 'halfway');
      await tester.pumpAndSettle();
      expect(find.text('halfway'), findsOneWidget);
    });

    testWidgets('shows the child at once under reduced motion', (tester) async {
      await pumpOnPage(tester, const Rise(child: _box));
      expect(_opacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('FadeIn', () {
    testWidgets('fades the child in', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const FadeIn(child: _box));
      expect(_opacity(tester), 0);
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
    });
  });

  group('PopIn', () {
    test('grows from 30% past full size and settles, curving each step', () {
      expect(PopIn.frameAt(0, Curves.linear), (scale: 0.3, opacity: 0.0));
      final peak = PopIn.frameAt(0.6, Curves.linear);
      expect(peak.scale, closeTo(1.18, 1e-9));
      expect(peak.opacity, 1);
      expect(PopIn.frameAt(1, Curves.linear).scale, closeTo(1, 1e-9));
      // Half way through the first step, on the curve.
      expect(PopIn.frameAt(0.3, Ease.roll).opacity, closeTo(Ease.roll.transform(0.5), 1e-9));
    });

    testWidgets('pops the child in and leaves it at full size', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const PopIn(child: _box));
      expect(_opacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 270));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.18, 0.01));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
      expect(_transform(tester).entry(0, 0), 1);
    });
  });

  group('ToastIn', () {
    testWidgets('rises 18px from 96% while fading in', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const ToastIn(child: _box));
      expect(_opacity(tester), 0);
      final start = tester.widgetList<Transform>(find.ancestor(of: find.byKey(const ValueKey('box')), matching: find.byType(Transform)));
      expect(start.map((t) => t.transform.getTranslation().y), contains(18));
      expect(start.map((t) => t.transform.entry(0, 0)), contains(closeTo(0.96, 1e-9)));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
    });
  });

  group('loops', () {
    testWidgets('Spin turns once per period, and back with reverse', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Spin(
              period: Duration(seconds: 1),
              child: SizedBox(key: ValueKey('on'), width: 10, height: 10),
            ),
            Spin(
              period: Duration(seconds: 1),
              reverse: true,
              child: SizedBox(key: ValueKey('back'), width: 10, height: 10),
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      double angle(String key) {
        final m = tester.widget<Transform>(find.ancestor(of: find.byKey(ValueKey(key)), matching: find.byType(Transform)).first).transform;
        return math.atan2(m.entry(1, 0), m.entry(0, 0));
      }

      expect(angle('on'), closeTo(math.pi / 2, 0.05));
      expect(angle('back'), closeTo(-math.pi / 2, 0.05));
      // Loops never settle; take the page down so the test can end.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Breathe swells to its scale half way through', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Breathe(period: Duration(seconds: 2), curve: Curves.linear, child: _box),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.035, 0.002));
      await tester.pump(const Duration(seconds: 1));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1, 0.002));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Halo waits its delay, then grows and fades', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Halo(delay: Duration(milliseconds: 500), curve: Curves.linear, child: _box),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1, 1e-6));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.45, 0.02));
      expect(_opacity(tester), closeTo(0.45, 0.02));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Spin is a quarter turn round at a quarter of its period and half a turn at a half', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Spin(period: Duration(seconds: 2), child: _box),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(_transform(tester).entry(0, 0), closeTo(0, 1e-6));
      expect(_transform(tester).entry(1, 0), closeTo(1, 1e-6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_transform(tester).entry(0, 0), closeTo(-1, 1e-6));
      expect(_transform(tester).entry(1, 0), closeTo(0, 1e-6));
      expect(_opacity(tester), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Breathe is half way to its scale at a quarter of its period and there at a half', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Breathe(period: Duration(seconds: 2), curve: Curves.linear, child: _box),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.0175, 1e-6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.035, 1e-6));
      expect(_opacity(tester), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Halo has grown and faded a quarter at a quarter of its period and a half at a half', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const Halo(period: Duration(seconds: 2), curve: Curves.linear, child: _box),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.225, 1e-6));
      expect(_opacity(tester), closeTo(0.675, 1e-6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_transform(tester).getMaxScaleOnAxis(), closeTo(1.45, 1e-6));
      expect(_opacity(tester), closeTo(0.45, 1e-6));
      await tester.pumpWidget(const SizedBox());
    });

    for (final (name, wrap) in <(String, Widget Function(Widget))>[
      ('Spin', (child) => Spin(child: child)),
      ('Breathe', (child) => Breathe(child: child)),
      ('Halo', (child) => Halo(child: child)),
    ]) {
      testWidgets('$name holds still under reduced motion', (tester) async {
        await pumpOnPage(tester, wrap(_box));
        await tester.pump(const Duration(milliseconds: 700));
        expect(_transform(tester).isIdentity(), isTrue);
        expect(_opacity(tester), 1);
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('$name keeps its child'
          's state while it runs and when motion is reduced', (tester) async {
        await pumpOnPage(
          tester,
          reducedMotion: false,
          effects: EffectsMode.running,
          wrap(const SizedBox(width: 200, child: TextField(key: ValueKey('field')))),
        );
        await tester.enterText(find.byKey(const ValueKey('field')), 'kept');
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('kept'), findsOneWidget);
        expect(tester.hasRunningAnimations, isTrue);

        useReducedMotion(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('kept'), findsOneWidget);
        expect(tester.hasRunningAnimations, isFalse);
      });
    }

    testWidgets('hold still under reduced motion', (tester) async {
      await pumpOnPage(
        tester,
        const Spin(
          child: Breathe(child: Halo(child: _box)),
        ),
      );
      await tester.pumpAndSettle();
      final transforms = tester.widgetList<Transform>(
        find.ancestor(of: find.byKey(const ValueKey('box')), matching: find.byType(Transform)),
      );
      expect(transforms.every((t) => t.transform.isIdentity()), isTrue);
      expect(_opacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('PressScale', () {
    testWidgets('shrinks while pressed and lets the child take the tap', (tester) async {
      var taps = 0;
      await pumpOnPage(
        tester,
        PressScale(
          child: TextButton(onPressed: () => taps++, child: const Text('Unlock')),
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.text('Unlock')));
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 0.97);
      await gesture.up();
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      expect(taps, 1);
    });
  });
}
