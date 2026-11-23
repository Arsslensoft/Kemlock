import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/public_suffixes.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/ui/ui.dart';

/// The app's copy, read from the asset files once for every test.
final MessageCatalog testCatalog = MessageCatalog({
  for (final locale in AppLocale.values) locale: MessageCatalog.decode(File('assets/i18n/${locale.name}.json').readAsStringSync()),
});

/// The English message [id] with [args], to find copy by id as `t()` did in the Vitest tests.
String t(String id, [Map<String, Object?> args = const {}]) => testCatalog.of(AppLocale.en).t(id, args);

/// A fixed "now" for tests: Friday 16 October 2026, 09:00 UTC.
final testNow = DateTime.utc(2026, 10, 16, 9);

/// The overrides every screen test needs: the copy, storage in memory (holding
/// [store], or nothing) and a fixed clock, or [clock] for one the test moves.
List<Override> testOverrides({KeyValueStore? store, DateTime? now, DateTime Function()? clock}) => [
  messageCatalogProvider.overrideWithValue(testCatalog),
  keyValueStoreProvider.overrideWithValue(store ?? KeyValueStore.memory()),
  clockProvider.overrideWithValue(clock ?? () => now ?? testNow),
  // The asset bundle can't load it in fake time; the file is read once per test run
  publicSuffixListProvider.overrideWith((ref) => bundledSuffixes),
];

/// The bundled Public Suffix List, read from the repository once per test run.
final PublicSuffixList bundledSuffixes = PublicSuffixList.parse(File(publicSuffixListAsset).readAsStringSync());

/// Asks for less motion, as the phone's setting does, until the test ends:
/// entrances jump to their end and loops (the vault dial, spinners) hold
/// still, so `pumpAndSettle` finishes.
void useReducedMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Whether a test's effects and loops are held at one moment or run.
enum EffectsMode {
  /// Every loop is held half way through its period with no ticker, and
  /// every one-shot effect shows its end, so `pumpAndSettle` finishes even
  /// with motion on. The default.
  pinned(0.5),

  /// Loops run, for the tests of the loops and effects themselves, which
  /// step time with `pump`.
  running(null);

  const EffectsMode(this.phase);

  /// The phase an `EffectsScope` is pinned at, or null to let it run.
  final double? phase;
}

/// Pumps [child] as the app's home screen, in the app's theme for
/// [brightness] and inside a provider scope with storage in memory and a
/// fixed clock (see [testOverrides]); [overrides] come on top. Returns the
/// container, to read providers from. Motion is reduced unless
/// [reducedMotion] is false (see [useReducedMotion]), and the effects are
/// held still unless [effects] is [EffectsMode.running].
///
/// A [ToastHost] sits round the navigator, as in the app, so `showToast`
/// works. [child] is usually a screen with its own `Scaffold`; for a lone
/// widget use [pumpOnPage].
Future<ProviderContainer> pumpScreen(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.dark,
  AppLocale locale = AppLocale.en,
  KeyValueStore? store,
  DateTime? now,
  DateTime Function()? clock,
  List<Override> overrides = const [],
  bool reducedMotion = true,
  EffectsMode effects = EffectsMode.pinned,
}) async {
  if (reducedMotion) useReducedMotion(tester);
  final container = ProviderContainer(
    overrides: [
      ...testOverrides(store: store, now: now, clock: clock),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    // Keyed by its container, so pumping again in one test starts a fresh scope.
    UncontrolledProviderScope(
      key: ObjectKey(container),
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(brightness),
        debugShowCheckedModeBanner: false,
        localizationsDelegates: localizationsDelegates(testCatalog),
        supportedLocales: supportedLocales,
        locale: locale.locale,
        builder: (context, child) => EffectsScope(
          pinned: effects.phase,
          child: ToastHost(child: child!),
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Pumps a lone widget on a plain page of the app (a `Scaffold` with 16px
/// gutters), centred unless [center] is false. Takes what [pumpScreen] does.
Future<ProviderContainer> pumpOnPage(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.dark,
  List<Override> overrides = const [],
  bool reducedMotion = true,
  EffectsMode effects = EffectsMode.pinned,
  bool center = true,
}) => pumpScreen(
  tester,
  Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: center ? Center(child: child) : child,
      ),
    ),
  ),
  brightness: brightness,
  overrides: overrides,
  reducedMotion: reducedMotion,
  effects: effects,
);
