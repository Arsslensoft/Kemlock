import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../models/custom_field.dart';
import '../../../models/otp_account.dart';
import '../otp.dart';

/// The algorithms and code lengths the manual form offers.
const manualAlgorithms = ['SHA1', 'SHA256', 'SHA512'];
const manualDigits = [6, 8];

/// How a type is named in the form and on a scanned account's chips; the names aren't translated.
String otpTypeName(OtpType type) => switch (type) {
  OtpType.totp => 'TOTP',
  OtpType.hotp => 'HOTP',
  OtpType.steam => 'Steam',
};

/// "SHA1" → "SHA-1".
String algorithmName(String algorithm) => algorithm.replaceFirst('SHA', 'SHA-');

/// What the person typed on the Manual tab of adding an account, kept while
/// they switch tabs: `defaultManual` and its state in `AddAccountDialog.tsx`.
/// The text fields' controllers live here; the sheet listens to it to keep
/// the live preview up to date.
class ManualForm extends ChangeNotifier {
  ManualForm() {
    for (final field in [issuer, label, secret, period, counter]) {
      field.addListener(notifyListeners);
    }
  }

  final issuer = TextEditingController();
  final label = TextEditingController();

  /// Kept as normalised Base32 as it is typed (see [SecretFormatter]).
  final secret = TextEditingController();

  /// TOTP only: seconds per code, as typed.
  final period = TextEditingController(text: '30');

  /// HOTP only: the counter to start from, as typed.
  final counter = TextEditingController(text: '0');

  /// The custom fields, as the editor last gave them. They are kept here, with the rest of the form, while the person
  /// switches tabs, and set without telling listeners: the editor keeps the rows.
  List<CustomField> fields = const [];

  OtpType _type = OtpType.totp;
  String _algorithm = 'SHA1';
  int _digits = 6;

  OtpType get type => _type;
  set type(OtpType value) {
    _type = value;
    notifyListeners();
  }

  String get algorithm => _algorithm;
  set algorithm(String value) {
    _algorithm = value;
    notifyListeners();
  }

  int get digits => _digits;
  set digits(int value) {
    _digits = value;
    notifyListeners();
  }

  /// A number field as `Number()` reads it: empty is 0, and anything else that isn't a number is null.
  static int? _number(String text) => text.trim().isEmpty ? 0 : int.tryParse(text.trim());

  bool get _periodOk {
    final value = _number(period.text);
    return value != null && value >= 15 && value <= 300;
  }

  bool get _counterOk {
    final value = _number(counter.text);
    return value != null && value >= 0;
  }

  /// Whether the period or counter its type uses is one a code can be made with.
  bool get paramsOk => switch (_type) {
    OtpType.totp => _periodOk,
    OtpType.hotp => _counterOk,
    OtpType.steam => true,
  };

  bool get secretOk => isValidSecret(secret.text);

  /// The message id of the first thing wrong with the form, or null when it can be added.
  String? get error {
    if (secret.text.isEmpty) return 'addAccount.manual.error.secret';
    if (!secretOk) return 'addAccount.manual.error.secretInvalid';
    if (issuer.text.trim().isEmpty && label.text.trim().isEmpty) return 'addAccount.manual.error.name';
    if (_type == OtpType.totp && !_periodOk) return 'addAccount.manual.error.period';
    if (_type == OtpType.hotp && !_counterOk) return 'addAccount.manual.error.counter';
    return null;
  }

  /// The form as a new account (id '' and addedAt 0, as [parseOtpUri] makes
  /// them), keeping only the fields its type uses: HOTP drops the period,
  /// Steam its algorithm and digits.
  OtpAccount toAccount() {
    final issuer = this.issuer.text.trim();
    final label = this.label.text.trim();
    return switch (_type) {
      OtpType.hotp => OtpAccount(
        id: '',
        type: OtpType.hotp,
        issuer: issuer,
        label: label,
        secret: secret.text,
        algorithm: _algorithm,
        digits: _digits,
        counter: _number(counter.text) ?? 0,
        fields: fields,
        addedAt: 0,
      ),
      OtpType.steam => OtpAccount(
        id: '',
        type: OtpType.steam,
        issuer: issuer,
        label: label,
        secret: secret.text,
        fields: fields,
        addedAt: 0,
      ),
      OtpType.totp => OtpAccount(
        id: '',
        type: OtpType.totp,
        issuer: issuer,
        label: label,
        secret: secret.text,
        algorithm: _algorithm,
        digits: _digits,
        period: _number(period.text) ?? 30,
        fields: fields,
        addedAt: 0,
      ),
    };
  }

  @override
  void dispose() {
    for (final field in [issuer, label, secret, period, counter]) {
      field.dispose();
    }
    super.dispose();
  }
}

/// Keeps a secret field in normalised Base32 as it is typed: upper case,
/// without spaces or dashes, with the cursor where it was.
class SecretFormatter extends TextInputFormatter {
  const SecretFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = normalizeSecret(newValue.text);
    if (text == newValue.text) return newValue;
    final end = newValue.selection.end;
    final cursor = end < 0 ? text.length : normalizeSecret(newValue.text.substring(0, end.clamp(0, newValue.text.length))).length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}
