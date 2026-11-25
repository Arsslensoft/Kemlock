import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart';

export 'package:kemlock_ports/kemlock_ports.dart'
    show PushDistributor, PushDistributors, PushNudge, PushToken, PushTokens, pushKindApns, pushKindUnifiedPush;

/// This phone's push token and the nudges from other devices: APNs on iOS in the store build, UnifiedPush on Android in
/// both builds, and none elsewhere (add-kemlock-server-sync, design 13; plan add-unifiedpush). Tests override it.
final pushTokensProvider = Provider<PushTokens>((ref) => parts.newPushTokens());
