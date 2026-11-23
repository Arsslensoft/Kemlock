// "Shared to Kemlock": what was shared, and Encrypt and Sign, each opening
// its sheet with the item in place (openspec: add-share-extension,
// decision 10).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/pgp/encrypt_sheet.dart';
import 'package:kemlock/features/pgp/sign_sheet.dart';
import 'package:kemlock/features/share/share_sheet.dart';
import 'package:kemlock/platform/shared_items.dart';

import '../../helpers/screenshots.dart' show loadAppFonts;
import '../../helpers/test_app.dart';
import '../pgp/pgp_kit.dart';
import 'share_kit.dart';

void main() {
  Future<ShareApp> open(WidgetTester tester, SharedItem item) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    unawaited(showShareSheet(share.shell, item));
    await share.settle();
    expect(find.byType(ShareSheet), findsOneWidget);
    return share;
  }

  /// The text field holding exactly [text].
  Finder fieldHolding(String text) => find.byWidgetPredicate((widget) => widget is TextField && widget.controller?.text == text);

  testWidgets('a text shows its first four lines and no more', (tester) async {
    await open(tester, const SharedText('First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line'));

    expect(find.text(t('share.title')), findsOneWidget);
    expect(inSheet<ShareSheet>(find.text('First line\nSecond line\nThird line\nFourth line…')), findsOneWidget);
    expect(find.textContaining('Fifth line'), findsNothing);
    expect(find.text(t('share.encrypt')), findsOneWidget);
    expect(find.text(t('share.encrypt.hint')), findsOneWidget);
    expect(find.text(t('share.sign')), findsOneWidget);
    expect(find.text(t('share.sign.hint')), findsOneWidget);
  });

  testWidgets('first lines that wrap show whole, and the ellipsis after them shows', (tester) async {
    // The app's own fonts, so lines wrap where they do on a phone
    await tester.runAsync(loadAppFonts);
    const long = 'The draft of the contract is ready. Could you read it before Friday and tell me what you think?';
    await open(tester, const SharedText('$long\n$long\n$long\n$long\nThe fifth line'));

    final shown = find.descendant(of: find.byType(ShareSheet), matching: find.textContaining('The draft'));
    expect(tester.widget<Text>(shown).data, endsWith('…'));
    expect(tester.widget<Text>(shown).data, isNot(contains('fifth')));
    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: shown, matching: find.byType(RichText)));
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('a short text shows whole, with no ellipsis', (tester) async {
    await open(tester, const SharedText('Meet me at nine.'));
    expect(inSheet<ShareSheet>(find.text('Meet me at nine.')), findsOneWidget);
  });

  testWidgets('a file shows its name and a readable size', (tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    final file = share.copied('contract.pdf', List.filled(52344, 0x25));
    unawaited(showShareSheet(share.shell, file));
    await share.settle();

    expect(inSheet<ShareSheet>(find.text('contract.pdf')), findsOneWidget);
    expect(inSheet<ShareSheet>(find.text(t('notes.file.kb', {'size': 51.1}))), findsOneWidget);
  });

  testWidgets('Encrypt opens the encrypt sheet holding the text, with the recipients still to choose', (tester) async {
    final share = await open(tester, const SharedText('Meet me at nine.'));

    await share.tap(find.text(t('share.encrypt')));

    expect(find.byType(ShareSheet), findsNothing);
    expect(find.byType(EncryptSheet), findsOneWidget);
    expect(inSheet<EncryptSheet>(fieldHolding('Meet me at nine.')), findsOneWidget);
    expect(share.requests, isEmpty);
  });

  testWidgets('Sign opens the sign sheet holding the file', (tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    final file = share.copied('contract.pdf', 'the contract'.codeUnits);
    unawaited(showShareSheet(share.shell, file));
    await share.settle();

    await share.tap(find.text(t('share.sign')));

    expect(find.byType(SignSheet), findsOneWidget);
    expect(inSheet<SignSheet>(find.text('contract.pdf')), findsOneWidget);
    expect(File(file.path).existsSync(), isTrue);
  });

  testWidgets('closing the sheet forgets the item and deletes its file', (tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    final file = share.copied('contract.pdf', 'the contract'.codeUnits);
    unawaited(showShareSheet(share.shell, file));
    await share.settle();

    await share.closeSheet();

    expect(find.byType(ShareSheet), findsNothing);
    expect(share.waiting, isNull);
    expect(File(file.path).existsSync(), isFalse);
  });

  testWidgets('after Encrypt the file is the encrypt sheet\'s: still there, and gone when that sheet closes', (tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    final file = share.copied('contract.pdf', 'the contract'.codeUnits);
    unawaited(showShareSheet(share.shell, file));
    await share.settle();

    await share.tap(find.text(t('share.encrypt')));
    expect(find.byType(EncryptSheet), findsOneWidget);
    expect(inSheet<EncryptSheet>(find.text('contract.pdf')), findsOneWidget);
    expect(File(file.path).existsSync(), isTrue);

    await share.closeSheet();
    expect(File(file.path).existsSync(), isFalse);
  });

  testWidgets('encrypting the shared file leaves no copy of it', (tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    final file = share.copied('contract.pdf', 'the contract'.codeUnits);
    unawaited(showShareSheet(share.shell, file));
    await share.settle();
    await share.tap(find.text(t('share.encrypt')));

    await share.tap(find.text(t('pgp.encrypt.button')));
    expect(share.files.fromPath, ['contract.pdf.gpg']);
    expect(File(file.path).existsSync(), isFalse);

    await share.closeSheet();
    expect([
      for (final entity in share.shareRoot.listSync(recursive: true))
        if (entity is File) entity.path,
    ], isEmpty);
  });

  testWidgets('locking the vault closes the sheet and deletes the file', (tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    final file = share.copied('contract.pdf', 'the contract'.codeUnits);
    unawaited(showShareSheet(share.shell, file));
    await share.settle();

    share.app.controller.lock();
    await share.settle();

    expect(find.byType(ShareSheet), findsNothing);
    expect(File(file.path).existsSync(), isFalse);
  });
}
