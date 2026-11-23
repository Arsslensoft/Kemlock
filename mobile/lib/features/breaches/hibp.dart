/// Have I Been Pwned, the one outside service the breach checks talk to: its
/// list of breaches (`breach_refresh.dart`) and Pwned Passwords
/// (`pwned_passwords.dart`). Neither takes a key, and both are off until the
/// person turns them on.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../platform/network.dart';
import '../settings/app_version.dart';

/// Where the breach data comes from, and where its credit links to.
const hibpSite = 'https://haveibeenpwned.com';

/// The client every request to Have I Been Pwned goes through: a gated one, which makes
/// no request while offline mode is on. Tests override it with a `MockClient`, so none
/// reaches the network.
final hibpClientProvider = Provider<http.Client>((ref) => ref.watch(gatedClientProvider));

/// The `User-Agent` of those requests, which Have I Been Pwned refuses to
/// answer without: the app's name and, when it can be read, its version.
final hibpUserAgentProvider = FutureProvider<String>((ref) async {
  try {
    return hibpUserAgent(await ref.watch(appVersionProvider.future));
  } catch (_) {
    return hibpUserAgent(null);
  }
});

/// `Kemlock/1.1.0`, or `Kemlock` without a [version].
String hibpUserAgent(String? version) => version == null || version.isEmpty ? 'Kemlock' : 'Kemlock/$version';
