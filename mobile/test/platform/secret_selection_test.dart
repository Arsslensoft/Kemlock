import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/secret_clipboard.dart';
import 'package:kemlock/platform/secret_selection.dart';

import '../fakes/fake_clipboard.dart';

void main() {
  late FakeSensitiveClipboard phone;

  /// What reached Flutter's plain clipboard.
  late List<String?> plain;

  setUp(() {
    phone = FakeSensitiveClipboard();
    plain = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') plain.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
      if (call.method == 'Clipboard.hasStrings') return {'value': false};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  });

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    ProviderScope(
      overrides: [secretClipboardProvider.overrideWithValue(SecretClipboard(() => null, channel: phone))],
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );

  testWidgets("the toolbar's Copy of a secret goes through the secret clipboard, with nothing that hands it on", (tester) async {
    await pump(tester, const SecretSelection(child: SelectableText('Secretword', contextMenuBuilder: secretTextMenu)));

    await tester.longPress(find.text('Secretword'));
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
    expect(find.text('Search Web'), findsNothing);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(phone.copies.map((copy) => copy.text), ['Secretword']);
    expect(plain, isEmpty);
  });

  testWidgets("a keyboard's copy of a secret goes through it too", (tester) async {
    await pump(tester, const SecretSelection(child: SelectableText('Secretword', contextMenuBuilder: secretTextMenu)));
    await tester.tap(find.text('Secretword'));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(phone.copies.map((copy) => copy.text), ['Secretword']);
    expect(plain, isEmpty);
  });

  testWidgets('a password shown in a field is copied and cut through it, and an obscured one not at all', (tester) async {
    final controller = TextEditingController(text: 'hunter2hunter2');
    addTearDown(controller.dispose);
    var obscured = false;
    late StateSetter setState;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          setState = set;
          return SecretSelection(
            child: TextField(controller: controller, obscureText: obscured, contextMenuBuilder: secretTextMenu),
          );
        },
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(phone.copies.map((copy) => copy.text), ['hunter2hunter2']);
    expect(controller.text, isEmpty);

    controller.text = 'hunter3hunter3';
    setState(() => obscured = true);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(phone.copies, hasLength(1));
    expect(plain, isEmpty);
  });

  testWidgets('text outside a view of secrets copies as before', (tester) async {
    await pump(tester, const SelectableText('Plainword'));

    await tester.longPress(find.text('Plainword'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(plain, ['Plainword']);
    expect(phone.copies, isEmpty);
  });
}
