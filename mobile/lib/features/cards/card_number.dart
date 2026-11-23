/// The brands the card sheet offers, as stored on a card. They are the names
/// Bitwarden writes, so a brand crosses between the two unchanged.
const cardBrands = ['Visa', 'Mastercard', 'Amex', 'Discover', 'Diners Club', 'JCB', 'UnionPay', 'Maestro'];

/// The first [length] digits of [digits] as a number, or null when there are fewer.
int? _prefix(String digits, int length) => digits.length < length ? null : int.parse(digits.substring(0, length));

bool _in(int? value, int low, int high) => value != null && value >= low && value <= high;

/// The brand offered for a card number from its leading digits (the IIN
/// ranges), or null when none of [cardBrands] fits. [digits] is digits only.
/// It is an offer: the person may change it, and a co-branded card may differ.
String? cardBrandOf(String digits) {
  if (digits.isEmpty) return null;
  final two = _prefix(digits, 2);
  final three = _prefix(digits, 3);
  final four = _prefix(digits, 4);
  final six = _prefix(digits, 6);
  if (two == 34 || two == 37) return 'Amex';
  if (digits.startsWith('4')) return 'Visa';
  if (_in(two, 51, 55) || _in(four, 2221, 2720)) return 'Mastercard';
  if (four == 6011 || _in(three, 644, 649) || two == 65 || _in(six, 622126, 622925)) return 'Discover';
  if (two == 62) return 'UnionPay';
  if (_in(three, 300, 305) || four == 3095 || two == 36 || two == 38 || two == 39) return 'Diners Club';
  if (_in(four, 3528, 3589)) return 'JCB';
  const maestro = {5018, 5020, 5038, 5893, 6304, 6759, 6761, 6762, 6763};
  if (four != null && maestro.contains(four)) return 'Maestro';
  return null;
}

/// Whether [digits] pass the Luhn check. Anything but digits fails.
bool luhnValid(String digits) {
  if (digits.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(digits)) return false;
  var sum = 0;
  var doubled = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var digit = digits.codeUnitAt(i) - 0x30;
    if (doubled) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    doubled = !doubled;
  }
  return sum % 10 == 0;
}

/// The fewest and the most digits a card number may have.
const cardNumberMinDigits = 8;
const cardNumberMaxDigits = 19;

/// [digits] in groups: 4-6-5 for an Amex, fours for the rest.
String groupedCardNumber(String digits) {
  if (digits.length == 15 && (digits.startsWith('34') || digits.startsWith('37'))) {
    return '${digits.substring(0, 4)} ${digits.substring(4, 10)} ${digits.substring(10)}';
  }
  return [for (var i = 0; i < digits.length; i += 4) digits.substring(i, i + 4 > digits.length ? digits.length : i + 4)].join(' ');
}

/// The number as shown until revealed: "•••• 1111".
String maskedCardNumber(String digits) => digits.length <= 4 ? digits : '•••• ${digits.substring(digits.length - 4)}';

/// An expiry or "valid from" date as shown and typed: "05/2029", "2029" for a
/// year alone, "05" for a month alone, and null for neither.
String? monthYearText(int? month, int? year) {
  if (month == null && year == null) return null;
  final mm = month?.toString().padLeft(2, '0');
  return [?mm, ?year?.toString()].join('/');
}
