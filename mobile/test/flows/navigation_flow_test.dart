import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

/// The flows of `e2e/navigation.spec.ts`. The phone app has no address
/// bar: where the spec went to a URL, these send the app's router there,
/// and the tab bar marks the selected tab for screen readers as the web
/// app's links had `aria-current="page"`.
void main() {
  Future<TestApp> openVault(WidgetTester tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    return app;
  }

  testWidgets('sends the root and the old codes path to their tabs', (tester) async {
    final app = await openVault(tester);
    expect(location(app), '/accounts');
    expect(tester.getSemantics(tab('nav.codes')), selected);

    await goTo(tester, app, '/settings');
    await goTo(tester, app, '/');
    expect(location(app), '/accounts');
    expect(find.text(t('app.empty.otp.title')), findsOneWidget);

    await goTo(tester, app, '/codes');
    expect(location(app), '/backup');
    expect(find.text(t('app.empty.backup.title')), findsOneWidget);
    expect(tester.getSemantics(tab('nav.backup')), selected);
  });

  testWidgets('opens a tab from its location and moves between tabs', (tester) async {
    final app = await openVault(tester);

    await goTo(tester, app, '/settings');
    expect(tester.getSemantics(tab('nav.settings')), selected);
    expect(tester.getSemantics(tab('nav.codes')), isNot(selected));

    await tapOn(tester, tab('nav.backup'));
    expect(location(app), '/backup');
    expect(tester.getSemantics(tab('nav.backup')), selected);
    expect(tester.getSemantics(tab('nav.settings')), isNot(selected));

    // There is no going back: a tab replaces the location, so Settings is chosen again.
    await tapOn(tester, tab('nav.settings'));
    expect(location(app), '/settings');
    expect(tester.getSemantics(tab('nav.settings')), selected);
    expect(tester.getSemantics(tab('nav.backup')), isNot(selected));
  });
}
