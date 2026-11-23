import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/service_icons.dart';
import 'package:kemlock/features/accounts/service_tile.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets("draws a bundled service's logo once the logos load", (tester) async {
    await tester.runAsync(() => ServiceIcons.load());
    await pumpOnPage(tester, const ServiceTile(name: 'GitHub'));
    // The catalogue was read in a real zone, so it completes on the real event loop.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('draws a monogram for a service without a logo', (tester) async {
    await tester.runAsync(() => ServiceIcons.load());
    await pumpOnPage(tester, const ServiceTile(name: '  zzz corp'));
    await tester.pumpAndSettle();

    expect(find.text('Z'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('draws a question mark for an empty name', (tester) async {
    await pumpOnPage(tester, const ServiceTile(name: ' '));

    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('takes a whole emoji as the monogram', (tester) async {
    await pumpOnPage(tester, const ServiceTile(name: '🔐 Vault'));

    expect(find.text('🔐'), findsOneWidget);
  });

  testWidgets('is hidden from screen readers, which read the name beside it', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpOnPage(tester, const ServiceTile(name: 'Acme'));

    expect(find.bySemanticsLabel('A'), findsNothing);
    semantics.dispose();
  });
}
