import 'service_names.dart';

/// Stable hue (0–359) for a service name, so each service keeps its colour: the same
/// hash of the trimmed, lowercased name's UTF-16 code units as the web app's.
int serviceHue(String name) {
  var h = 7;
  for (final unit in jsLowerCase(jsTrim(name)).codeUnits) {
    h = (h * 31 + unit) & 0xffffffff;
  }
  return h % 360;
}
