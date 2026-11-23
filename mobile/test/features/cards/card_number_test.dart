import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/cards/card_number.dart';

void main() {
  test('offers each brand from the test numbers of its range', () {
    const numbers = {
      '4111111111111111': 'Visa',
      '4012888888881881': 'Visa',
      '5555555555554444': 'Mastercard',
      '2223003122003222': 'Mastercard',
      '378282246310005': 'Amex',
      '341111111111111': 'Amex',
      '6011111111111117': 'Discover',
      '6445644564456445': 'Discover',
      '6500000000000002': 'Discover',
      '30569309025904': 'Diners Club',
      '38520000023237': 'Diners Club',
      '3530111333300000': 'JCB',
      '6200000000000005': 'UnionPay',
      '6759649826438453': 'Maestro',
    };
    numbers.forEach((number, brand) => expect(cardBrandOf(number), brand, reason: number));
  });

  test('offers a brand from the leading digits typed so far, and none for an unknown range', () {
    expect(cardBrandOf('4'), 'Visa');
    expect(cardBrandOf('37'), 'Amex');
    expect(cardBrandOf('5'), isNull);
    expect(cardBrandOf(''), isNull);
    expect(cardBrandOf('9999999999999999'), isNull);
    for (final brand in ['Visa', 'Mastercard', 'Amex', 'Discover', 'Diners Club', 'JCB', 'UnionPay', 'Maestro']) {
      expect(cardBrands, contains(brand));
    }
  });

  test('checks the Luhn digit', () {
    expect(luhnValid('4111111111111111'), isTrue);
    expect(luhnValid('378282246310005'), isTrue);
    expect(luhnValid('4111111111111112'), isFalse);
    expect(luhnValid('4111 1111'), isFalse);
    expect(luhnValid(''), isFalse);
  });

  test('groups and masks a number', () {
    expect(groupedCardNumber('4111111111111111'), '4111 1111 1111 1111');
    expect(groupedCardNumber('378282246310005'), '3782 822463 10005');
    expect(groupedCardNumber('411111111'), '4111 1111 1');
    expect(maskedCardNumber('4111111111111111'), '•••• 1111');
    expect(maskedCardNumber('123'), '123');
  });
}
