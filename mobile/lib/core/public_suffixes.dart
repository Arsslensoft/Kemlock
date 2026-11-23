// The Public Suffix List (publicsuffix.org, MPL 2.0), bundled as
// assets/data/public_suffix_list.dat and refreshed before each release by
// tool/autofill/update_public_suffix_list.sh. It tells which part of a host
// a site owns: accounts.example.com and mail.example.com are both
// example.com's, while alice.herokuapp.com and bob.herokuapp.com are two
// sites, since anyone can open one under herokuapp.com.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'public_suffix_list.dart';

export 'public_suffix_list.dart';

const publicSuffixListAsset = 'assets/data/public_suffix_list.dat';

/// The bundled list, read once and parsed in the background. Null when it
/// can't be read, so that AutoFill fills each host on itself and the hosts
/// under it rather than failing.
final publicSuffixListProvider = FutureProvider<PublicSuffixList?>((ref) async {
  try {
    return await compute(PublicSuffixList.parse, await rootBundle.loadString(publicSuffixListAsset));
  } catch (_) {
    return null;
  }
});
