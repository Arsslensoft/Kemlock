import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/i18n/messages.dart';

// Vaultwarden doesn't carry File items, so they stay on this phone; Kemlock Server is another place and not what this says
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the Vaultwarden note on File items says they stay on this phone, in both languages', () async {
    final catalog = await MessageCatalog.load();
    for (final locale in AppLocale.values) {
      final messages = catalog.of(locale);
      for (final count in [1, 3]) {
        expect(messages.t('files.vaultwarden.stay', {'count': count}), isNot(contains('Kemlock Server')), reason: '${locale.name} $count');
      }
    }
  });
}
