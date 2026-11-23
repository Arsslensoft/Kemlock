import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart';

export 'package:kemlock_ports/kemlock_ports.dart' show PushNudge, PushTokens;

/// This phone's push token and the nudges from other devices: APNs on iOS in the store build, none on Android
/// and none in the free build (add-kemlock-server-sync, design 13). Tests override it.
final pushTokensProvider = Provider<PushTokens>((ref) => parts.newPushTokens());
