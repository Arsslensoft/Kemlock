/// The interfaces the app reads its replaceable parts through (openspec:
/// add-fdroid-release, design decision 1). The store build's parts, which
/// use closed libraries, and the free build's both implement them, in two
/// packages named `kemlock_parts`; the app imports this and never those
/// libraries.
library;

export 'src/build_kind.dart';
export 'src/code_readers.dart';
export 'src/credential_transfer.dart';
export 'src/files.dart';
export 'src/push.dart';
export 'src/scanner.dart';
