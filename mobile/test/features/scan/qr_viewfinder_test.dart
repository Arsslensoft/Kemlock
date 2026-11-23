import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/scan/qr_viewfinder.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/platform/scanner_source.dart';

import '../../fakes/fake_scanner.dart';
import '../../helpers/test_app.dart';

void main() {
  testWidgets('starts the camera once it is shown and says what to point it at', (tester) async {
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);

    expect(scanner.current.starts, 1);
    expect(scanner.isScanning, isTrue);
    expect(find.text(t('qrScanner.scanning')), findsOneWidget);
  });

  testWidgets('says the camera is starting until it is live, holding auto-lock for the permission prompt', (tester) async {
    final source = _SlowSource();
    final container = await pumpOnPage(
      tester,
      QrViewfinder(onScan: (_) {}),
      overrides: [scannerSourceProvider.overrideWithValue(() => source)],
    );

    expect(find.text(t('qrScanner.starting')), findsOneWidget);
    expect(container.read(autoLockHoldsProvider).isHeld, isTrue);
    expect(find.byIcon(Icons.flip_camera_ios_rounded), findsNothing);

    source.finishStarting();
    await tester.pump();

    expect(find.text(t('qrScanner.scanning')), findsOneWidget);
    expect(container.read(autoLockHoldsProvider).isHeld, isFalse);
  });

  testWidgets('says the camera was refused', (tester) async {
    final scanner = FakeScanner()..deny();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);

    expect(find.text(t('qrScanner.error.denied')), findsOneWidget);
    expect(find.byIcon(Icons.flip_camera_ios_rounded), findsNothing);
    expect(find.byIcon(Icons.flashlight_on_rounded), findsNothing);
  });

  testWidgets('reports each code it reads once', (tester) async {
    final scanner = FakeScanner();
    final scanned = <String>[];
    await pumpOnPage(tester, QrViewfinder(onScan: scanned.add), overrides: [scanner.asOverride]);

    await scanner.emitScan(tester, 'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP');
    await scanner.emitScan(tester, 'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP');
    await scanner.emitScan(tester, 'not a code we want');

    expect(scanned, ['otpauth://totp/A?secret=JBSWY3DPEHPK3PXP', 'not a code we want']);
  });

  testWidgets('freezes once a code is found, and scans again when it is cleared', (tester) async {
    final scanner = FakeScanner();
    final found = ValueNotifier(false);
    addTearDown(found.dispose);
    final scanned = <String>[];
    await pumpOnPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: found,
        builder: (context, value, _) => QrViewfinder(onScan: scanned.add, found: value),
      ),
      overrides: [scanner.asOverride],
    );

    await scanner.emitScan(tester, 'first');
    found.value = true;
    await tester.pumpAndSettle();

    expect(scanner.current.stops, 1);
    expect(scanner.isScanning, isFalse);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.text(t('qrScanner.scanning')), findsNothing);
    expect(find.byIcon(Icons.flip_camera_ios_rounded), findsNothing);

    await scanner.emitScan(tester, 'second');
    expect(scanned, ['first']);

    found.value = false;
    await tester.pumpAndSettle();

    expect(scanner.current.starts, 2);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(find.text(t('qrScanner.scanning')), findsOneWidget);
    // The camera started again, so the same code counts again.
    await scanner.emitScan(tester, 'first');
    expect(scanned, ['first', 'first']);
  });

  testWidgets('switches the torch on and off', (tester) async {
    final semantics = tester.ensureSemantics();
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);

    final torch = find.bySemanticsLabel(t('qrScanner.torch'));
    expect(tester.getSemantics(torch), isSemantics(isButton: true, hasToggledState: true, isToggled: false));

    await tester.tap(torch);
    await tester.pump();
    expect(tester.getSemantics(torch), isSemantics(isToggled: true));
    expect(find.byIcon(Icons.flashlight_off_rounded), findsOneWidget);

    await tester.tap(torch);
    await tester.pump();
    expect(scanner.current.torchCalls, [true, false]);
    expect(tester.getSemantics(torch), isSemantics(isToggled: false));
    semantics.dispose();
  });

  testWidgets('has no torch button for a camera without one', (tester) async {
    final semantics = tester.ensureSemantics();
    final scanner = FakeScanner(torch: false);
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);

    expect(find.bySemanticsLabel(t('qrScanner.torch')), findsNothing);
    expect(find.bySemanticsLabel(t('qrScanner.flip')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('flips the camera, and has no flip button with one camera', (tester) async {
    final semantics = tester.ensureSemantics();
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);

    await tester.tap(find.bySemanticsLabel(t('qrScanner.flip')));
    await tester.pump();
    expect(scanner.current.switches, 1);

    final single = FakeScanner(cameras: 1);
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [single.asOverride]);
    expect(find.bySemanticsLabel(t('qrScanner.flip')), findsNothing);
    semantics.dispose();
  });

  testWidgets('stops the camera while the app is in the background', (tester) async {
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);

    // The permission prompt makes the app inactive, which leaves the camera alone.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(scanner.current.stops, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(scanner.current.stops, 1);
    expect(scanner.isScanning, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(scanner.current.starts, 2);
    expect(scanner.isScanning, isTrue);
  });

  testWidgets('stops the camera while a page covers it', (tester) async {
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);
    final navigator = Navigator.of(tester.element(find.byType(QrViewfinder)));

    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Over')))));
    await tester.pumpAndSettle();
    expect(scanner.current.stops, 1);
    expect(scanner.isScanning, isFalse);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(scanner.current.starts, 2);
    expect(scanner.isScanning, isTrue);
  });

  testWidgets('lets go of the camera when it goes', (tester) async {
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride]);
    final source = scanner.current;

    await tester.pumpWidget(const SizedBox());

    expect(source.disposed, isTrue);
  });

  testWidgets('sweeps and breathes on a phone, and holds still once a code is found', (tester) async {
    final scanner = FakeScanner(animated: true);
    final found = ValueNotifier(false);
    addTearDown(found.dispose);
    await pumpOnPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: found,
        builder: (context, value, _) => QrViewfinder(onScan: (_) {}, found: value),
      ),
      overrides: [scanner.asOverride],
      reducedMotion: false,
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);

    found.value = true;
    // Settles: the ring, the check and the frame closing in run once, then nothing moves.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('holds still for a source that says not to animate', (tester) async {
    final scanner = FakeScanner();
    await pumpOnPage(tester, QrViewfinder(onScan: (_) {}), overrides: [scanner.asOverride], reducedMotion: false);

    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });
}

/// A camera that is still starting until the test says it is live.
class _SlowSource extends ScannerSource {
  final ValueNotifier<ScannerState> _state = ValueNotifier(const ScannerState(cameraCount: 2, torchAvailable: true));
  final StreamController<String> _codes = StreamController.broadcast();
  final Completer<void> _started = Completer();

  void finishStarting() {
    _state.value = _state.value.copyWith(phase: ScannerPhase.live);
    _started.complete();
  }

  @override
  ValueListenable<ScannerState> get state => _state;

  @override
  Stream<String> get codes => _codes.stream;

  @override
  bool get animated => false;

  @override
  Future<void> start() {
    _state.value = _state.value.copyWith(phase: ScannerPhase.starting);
    return _started.future;
  }

  @override
  Future<void> stop() async => _state.value = _state.value.copyWith(phase: ScannerPhase.stopped);

  @override
  Future<void> setTorch(bool on) async {}

  @override
  Future<void> switchCamera() async {}

  @override
  Widget buildPreview(BuildContext context) => const FakeCameraPreview();

  @override
  Future<void> dispose() => _codes.close();
}
