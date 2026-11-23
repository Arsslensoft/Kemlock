import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/now.dart';
import 'package:kemlock/core/providers.dart';

void main() {
  testWidgets('ticks on the second boundary and stops when nobody watches', (tester) async {
    var now = DateTime.fromMillisecondsSinceEpoch(1700000000400);
    final container = ProviderContainer(overrides: [clockProvider.overrideWithValue(() => now)]);
    addTearDown(container.dispose);
    final seen = <int>[];
    final sub = container.listen(nowSecondsProvider, (_, next) => seen.add(next), fireImmediately: true);

    // 600 ms to the boundary, plus the 5 ms margin
    now = DateTime.fromMillisecondsSinceEpoch(1700000001005);
    await tester.pump(const Duration(milliseconds: 604));
    expect(seen, [1700000000]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(seen, [1700000000, 1700000001]);

    sub.close();
    await tester.pump(const Duration(seconds: 2));
    expect(seen, hasLength(2));
  });

  test('counts the seconds left in a window, from the period down to 1', () {
    expect(remainingIn(59, 30), 1);
    expect(remainingIn(60, 30), 30);
    expect(remainingIn(61, 30), 29);
    // A period that is no period, as a file from elsewhere can give, never divides by zero
    expect(remainingIn(59, 0), 1);
    expect(remainingIn(59, -30), 1);
  });

  testWidgets('flashes on, and off after its time, starting over when triggered again', (tester) async {
    final flash = Flash(const Duration(seconds: 2));
    addTearDown(flash.dispose);

    flash.trigger();
    expect(flash.value, isTrue);
    await tester.pump(const Duration(milliseconds: 1500));
    flash.trigger();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(flash.value, isTrue);
    await tester.pump(const Duration(milliseconds: 500));

    expect(flash.value, isFalse);
  });
}
