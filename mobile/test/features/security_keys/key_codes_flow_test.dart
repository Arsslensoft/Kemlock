// What a person sees while Kemlock talks to a key's code application
// (openspec: add-security-key-codes).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/features/security_keys/key_codes_flow.dart';

import '../../helpers/test_app.dart';
import '../accounts/codes_fakes.dart';

void main() {
  testCodes('the prompt is closed by the time an exchange returns, so the caller can close its own route', (tester) async {
    bool? onTop;
    await pumpAt(
      tester,
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () async {
              await runKeyCodes(context, ref, (_, _) async => const KeyCodesResult(KeyCodesOutcome.done));
              if (context.mounted) onTop = ModalRoute.of(context)!.isCurrent;
            },
            child: const Text('go'),
          ),
        ),
      ),
      atMs: testNow.millisecondsSinceEpoch,
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(onTop, isTrue);
    expect(find.text(t('keyCodes.prompt.title')), findsNothing);
  });
}
