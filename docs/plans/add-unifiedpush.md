# Add UnifiedPush on Android

## Why

Kemlock Server now sends pushes itself (kemlock-server 05a71bb): APNs to iPhones, and an empty
Web Push (RFC 8030) `POST` to a UnifiedPush endpoint for Android. The owner ruled out Firebase on
2026-11-22, so Android has had no push at all: it syncs on its schedule and over `/kem/v1/live`
while the app is open. UnifiedPush lets a phone get "sync now" from the person's own distributor
(ntfy, NextPush, Sunup, ...) with no Google service.

## What changes

1. **A small Flutter plugin, `packages/unified_push`**, like `credential_transfer`: Kotlin on
   Android only, around the UnifiedPush Android connector (`org.unifiedpush.android:connector`,
   Apache-2.0, on Maven Central, no Google dependency). No pub.dev plugin: the app already keeps
   its own push channel on iOS (`ios/Runner/PushChannel.swift`), and this keeps the dependency to
   one audited library. It:
   - lists the installed distributors and registers with the one in use (the connector's saved
     choice, else the only one, else asks the person to pick, once);
   - reports the endpoint (`onNewEndpoint`), its loss (`onUnregistered`) and a failed registration;
   - turns any message into `PushNudge.sync`, but only while the app's process runs: the service
     (`KemlockPushService`) forwards it to Dart when the Flutter engine is attached and drops it
     otherwise. A closed app has a locked vault and nothing to sync with, so it syncs at the next
     open or on its schedule, the same as an iPhone. The body is ignored: the server sends none;
   - keeps the endpoint in the app's private preferences (`EndpointStore`) so one that arrives while
     Dart is not running is still there at the next open.
2. **`kemlock_ports`**: `PushTokens.token()` becomes `pushToken()` returning `(kind, token)`, so
   the caller stops assuming `apns`. iOS keeps `apns`; Android gives `unifiedpush` and the
   endpoint URL. `available` is true on Android when a distributor is installed.
3. **Both Android builds get it**, the store build and the free (F-Droid) build: UnifiedPush is
   free software and is what F-Droid apps use. `parts_free` stops returning `NoPushTokens` on
   Android.
4. **`kemlock_push.dart`** sends the kind it is given. A new endpoint registers again at once
   (`POST /kem/v1/devices/push-token`); `onUnregistered` and the push switch turned off send
   `DELETE`.
5. **The push switch** (Sync settings): with no distributor installed, it says so and links to
   the UnifiedPush page that lists distributors, instead of turning on. With several, it names the
   one in use and lets the person change it.
6. **Kemlock-core**: `km_auth_api.dart`'s comments name `apns` and `unifiedpush` (not `fcm`). That
   change is on the kemlock-core branch `docs/push-kinds` (4981e30); the app's pin moves once it is
   on Kemlock-core's main.

## What the server needs (already true)

The endpoint must be `https` on port 443 or 8443 (ntfy.sh and most hosted distributors are). A
distributor on the server's own network needs `KEMLOCK_UNIFIEDPUSH_ALLOW_PRIVATE=true` on the
server. At most 20 UnifiedPush endpoints per account.

## Tests

- Dart: `kemlock_push` with a fake `PushTokens` for both kinds; re-registering on a new endpoint;
  `DELETE` on unregister and on the switch; the switch's no-distributor and several-distributor
  states (widget tests).
- Kotlin: `EndpointStore` (the kept endpoint, its loss with the distributor, and a change of
  distributor under way) as a plain JVM unit test; the plugin and service need Android and are
  checked by hand.
- Manual, on a phone with ntfy: register, see the endpoint on the server, change an item on
  another device, the open phone syncs; with the app closed nothing happens until the next open or
  schedule.

## Not in this change

- Approval nudges over UnifiedPush: the server's direct push carries no type, so a sign-in
  request shows at the next sync, as it does today without push.
- iOS: unchanged.
