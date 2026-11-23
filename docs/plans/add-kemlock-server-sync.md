# Kemlock Server sync

This plan adds Kemlock Server as a third backend in Settings › Sync, beside
a WebDAV folder and Vaultwarden. The phone signs in by the master password
through OPAQUE, by a passkey or security key with PRF, or by SSO followed by
an approval or a trusted device. It then syncs the vault's own entries
through the server's own API, `/kem/v1`, with tokens bound to the phone,
nudges from other devices, and failover to a replica when the vault's home
server is down.

## Why

Vaultwarden sync has four limits:

- It can carry only what fits in Bitwarden ciphers.
- It sees a hash of the master password at every sign-in.
- It can't sign someone in through their company's SSO and then open the
  vault without the master password.
- It can't fall back to a second server.

Kemlock Server (`../kemlock-server`, AGPL-3.0) fixes each of these with its
own API. Its design is "Kemlock Server: design and architecture"
(https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y), and the owner settled its
open questions on 21 November 2026 in its Decisions table. The server is
being built in parallel. Its Kemlock API needs a client in the app before
anyone can use it. The app's side can be built and tested now against a fake
server, then held to the server's OpenAPI spec and shared vectors once they
exist.

## What changes

- **A third sync backend.** Settings › Sync offers "Kemlock Server" beside
  "WebDAV folder" and "Vaultwarden". A vault's own entries sync through
  exactly one of WebDAV and Kemlock Server. After a move from a plain
  Vaultwarden home (`move-off-vaultwarden-sync`), a Vaultwarden target may
  stay beside Kemlock Server as a Bitwarden copy. WebDAV spaces keep syncing
  as they do.
- **Finding the server.** The person types the server's address. A vault
  already syncing with Vaultwarden is offered the move when that server's
  `/api/config` says `/kem/v1` exists (its `kemlock` member). The move itself is
  `move-off-vaultwarden-sync`; this plan shows the offer and signs in.
- **Signing in**, each way the server offers for the account:
  - the master password through OPAQUE. The server learns nothing it could
    test guesses against.
  - on a Compatible account's first Kemlock sign-in, the Bitwarden password
    hash once, after which the phone enrols OPAQUE;
  - a passkey or security key with the PRF extension, which signs in and
    also opens the account;
  - SSO with the company's OpenID Connect provider, in the system's browser
    sheet. The account is then opened by an approval from another of the
    person's devices, by this phone's trusted-device key, or by the master
    password;
  - two-step login after the password: an authenticator code, an email code
    or a security key.
- **Tokens bound to the phone.**
  - Every request carries a DPoP proof (RFC 9449), signed by a P-256 key in
    the Secure Enclave or Android Keystore. An access token or refresh token
    copied off the phone is useless elsewhere.
  - If a refresh token is used twice, the server ends the phone's session,
    and the phone says so.
  - The phone registers with the device identifier it already uses with
    Vaultwarden, so the server shows one device for both APIs.
- **Syncing.**
  - The phone asks for what changed since its opaque cursor.
  - It merges with the merge WebDAV sync already uses (`mergeScope`).
  - It writes back in batches of up to 500, each item guarded by
    `If-Match`. A stale write is merged again on the phone, never on the
    server.
  - Deletions arrive as tombstones.
  - A note's files go up and down as the same `KMA1` bytes.
  - The removal guard of Vaultwarden sync stops a run that would empty the
    vault.
  - Every run checks the account's signed manifest, so a rolled-back,
    missing or resurrected item stops the run. A run that wrote signs a new
    manifest at its end.
  - Item ids that aren't UUIDs, such as 0.1.0's `acc-1`, are sent as the
    UUIDs `add-account-crypto`'s legacy-id mapping gives. The original id
    stays inside the entry, so the merge pairs copies as it does today.
- **"Sync now" from other devices.**
  - The server's nudge arrives through Kemlock's push relay as APNs on iOS.
    Android has no push service: no Firebase, in either build (the owner's
    decision of 2026-11-22, below).
  - While the app is open and unlocked, it listens on `/kem/v1/live`. On
    Android that, with the existing schedule, is how a nudge arrives, in the
    store build and the F-Droid build alike.
- **Approving other devices.**
  - A new browser or phone that asks to sign in shows on this phone with its
    name, address and the approval fingerprint: 12 groups of 5 digits, the
    same rule as every Kemlock fingerprint.
  - Approving seals the account's user key to that device's one-time key.
    The server only relays it.
  - Settings lists the account's devices. Each row shows the device's last
    use of the Kemlock API and of the Bitwarden API. Any other device can
    be signed out from the list.
- **Failover.** The phone keeps each vault's server list: the home first,
  then its replicas.
  - It switches after two failed requests or 10 seconds without an answer.
  - It signs in to the replica with its device key, with no password.
  - It returns once the home has answered health checks for 5 minutes.
  - It takes a new home only with a promotion record signed by a server it
    already knows.
  - Changes only the home may accept (the master password, two-step login)
    wait, and the sync sheet says so.
- **Nothing existing changes shape.** The new settings member and sealed keys
  are new keys older builds keep or ignore. WebDAV and Vaultwarden sync,
  their files and their fixtures stay byte for byte.

Out of scope:

- The primitives: OPAQUE, the user key and its wraps, the exchange and
  signing keys, item envelopes, fingerprints and the manifest
  (`add-account-crypto`). This plan calls them.
- Moving entries off Vaultwarden or WebDAV, and keeping a plain home's
  Bitwarden copy (`move-off-vaultwarden-sync`).
- Spaces on the server, collection keys and member fingerprints
  (`add-server-spaces`).
- Duplicate tags and `/kem/v1/duplicates` (`add-duplicate-cleaner`).
- Account recovery by a space's admins, emergency access, Sends, and setting
  up two-step methods or passkeys from the phone. The phone signs in with
  them; setting them up stays in the web vault for now.
- A Kemlock Server backend in the browser extension. It is a later plan
  over the same engine.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

Each question lists its options and a recommendation. The tasks assume the
recommendation, as each one says.

1. **What does Kemlock Server need a gate for?** Nothing.
   - **Decided by the owner on 2026-11-23: Kemlock is free and open source,
     and nothing is gated.** Everything on Kemlock Server is free from the
     start, on every backend: syncing one's own entries, server spaces,
     Sends, server matching of duplicates, cards, identities, the duplicate
     cleaner and Credential Exchange import. No task here checks for a plan,
     a trial or a purchase.
2. **How does the store build get push on Android?**
   - (a) FCM through Google's `firebase-messaging` library in
     `parts_store`'s Android side, behind a small Kotlin channel, with no
     Dart plugin and no `google-services` Gradle plugin.
   - (b) The `firebase_messaging` Dart plugin.
   - (c) No push: the live socket and the schedule only.
   - *Recommendation: (a)*. Approvals after SSO need to reach a closed
     phone, and (a) keeps Google's code out of the free build and the Dart
     tree. The tasks assumed (a), with APNs through a Swift channel on iOS.
   - **Decided by the owner on 2026-11-22: (c) on Android.** Kemlock has no
     Firebase, and the README promises no telemetry, so the store build
     has no FCM. Android push is the live socket while the app is open, plus
     the sync schedule. UnifiedPush (3 (b)) is a later option through the same
     `PushTokens` port. iOS keeps APNs. Task 11.1's Android half is replaced by this.
3. **What does the F-Droid build do without FCM?**
   - (a) No push: requests and changes arrive while the app is open,
     through the live socket and the schedule, and the sheet says so.
   - (b) UnifiedPush now, through a distributor such as ntfy.
   - *Recommendation: (a) now, (b) later* through the same `PushTokens`
     port. The tasks assume (a).
4. **Which passkeys can sign in on the phone?** A native app can use a
   platform passkey only for a relying party associated with the app. On
   iOS that is a build-time entitlement no self-hosted domain can be in. On
   Android, a server can serve `assetlinks.json` naming the app.
   - (a) Security keys over NFC and USB on both platforms, through the app's
     own CTAP stack. Platform passkeys on Android 14 and later through
     Credential Manager, when the server serves `assetlinks.json`. No
     platform passkeys on iOS.
   - (b) (a), plus iOS through the web vault in `ASWebAuthenticationSession`,
     with the PRF output passed back in the callback.
   - (c) Security keys only.
   - *Recommendation: (a)*. (b) puts a vault-opening secret in a URL. The
     tasks assume (a).
5. **How does SSO open the browser?**
   - (a) A small Kotlin and Swift channel: `ASWebAuthenticationSession` and
     Custom Tabs.
   - (b) The `flutter_web_auth_2` plugin (MIT).
   - *Recommendation: (a)*. It adds no dependency, as `unlock_keys.dart`
     doesn't, and `network_callers_test` can name its one file. The tasks
     assume (a).
6. **What if the phone has no hardware key for DPoP?** That is the case on
   simulators and some older phones.
   - (a) A software P-256 key sealed in the vault, and the sign-in sheet
     says so.
   - (b) Refuse to sign in.
   - *Recommendation: (a)*. The tasks assume (a).
7. **Does the push switch start on?**
   - (a) On, with a line at sign-in saying the relay sees only device tokens
     and times.
   - (b) Off until turned on.
   - *Recommendation: (a)*. Without push, an SSO sign-in on another device
     waits until this phone is opened. The tasks assume (a).
8. **Which second steps does the app answer?**
   - (a) An authenticator code, an email code, and a security key. Duo,
     YubiKey OTP and the recovery code point to the web vault.
   - (b) (a) plus Duo through the browser sheet.
   - *Recommendation: (a)* in this plan. The tasks assume (a).
9. **Is the client written by hand or generated from the OpenAPI spec?**
   - (a) By hand, in `vw_api.dart`'s style, with a contract test against the
     spec.
   - (b) Generated, which brings `dio` or `built_value` and code the free
     build's reproducibility check would pin.
   - *Recommendation: (a)*. The tasks assume (a).

## Design

### Context

- **Sync today** runs per vault in scopes (`sync_scheduler.dart`):
  - The vault's own entries go to WebDAV (`personalScope`) or Vaultwarden
    (`vaultwardenScope`). Each WebDAV space is its own scope.
  - A run takes this phone's `Lists` and the ids the scope held after its
    last run (`ScopeState.known`). It returns the merged `SyncDoc`, the new
    `known`, and a state map kept sealed.
  - `mergeScope` (`sync_merge.dart`) merges by id: the later `updatedAt`
    wins, with tombstones. It also carries a login's losing password, keeps
    the higher HOTP counter, joins contacts' keys, and uses
    `combineKeyCopies` for PGP keys. The server design calls this "the
    field-level merge". This plan reuses it unchanged.
  - `SyncSettings` keeps `personal`, `spaces` and `vaultwarden`, with
    `extra` for keys a version doesn't know.
- **Vaultwarden sync** already has most of the hardening this client needs,
  from the 21 November 2026 audit:
  - `vw_api.dart` never follows a redirect.
  - Answers go through `readAnswer` with a cap.
  - `vw_http.dart` pins one compared certificate.
  - KDF costs are checked (07f6bf46).
  - The removal guard counts over a day (`removalWindow`).
  - Tombstones are clamped to now.
  - Security-key second steps claim the web vault's origin (`vwKeyOrigin`).
  - The vault's device id (`VwCredentials.deviceId`) is a UUID made once per
    vault.
- **Network.** Every request passes `NetworkGate` (`platform/network.dart`),
  so offline mode can stop it. `test/platform/network_callers_test.dart`
  fails when any other file makes a client, a socket or a browser launch.
- **Secrets on the phone** are sealed values (`saveEncryptedValue`). Keys
  prefixed `backmycodes_` are deleted with their vault by suffix and
  re-sealed by a key-pair replacement.
- **Hardware.**
  - `platform/unlock_keys.dart` talks to the Secure Enclave and Android
    Keystore.
  - The app has its own CTAP stack with hmac-secret over NFC and USB
    (`lib/security_key`).
  - Reveals ask the owner through `ownerCheckProvider`.
- **Builds.** The store and free builds differ in `kemlock_parts`
  (`packages/parts_store`, `packages/parts_free`) behind `kemlock_ports`.
  The free build has no Play services (`add-fdroid-release`).
- **`add-browser-extension`** plans to move the crypto, the models, the
  vault store, the sync merge and the Vaultwarden engine into a pure-Dart
  `packages/kemlock_core`, leaving an `export` at each old path. That move
  isn't done.
- **The server's routes.** The names below are the design doc's. Routes the
  design doesn't name were read from the server's code on `build/vertical-slice`
  (task 1.2). `mobile/test/fixtures/kemlock/README.md` lists each one: those the
  server has, and those it hasn't built yet, which the client is written to
  this plan's shape for.

### 1. The engine is pure Dart beside the Vaultwarden one

`lib/features/sync/kemlock/` holds:

- `km_api.dart`, the HTTP client;
- `km_dpop.dart`, the proof builder over a `DeviceKey` interface;
- `km_session.dart`, the sealed session and account;
- `km_sync.dart`, the run;
- `km_failover.dart`, the server list and switching;
- `km_signin.dart`, the sign-in steps as data, like `VwSignInStep`;
- `km_approvals.dart`.

None imports Flutter. Platform parts come in through interfaces: the device
key, the browser sheet, PRF and push. `add-browser-extension`'s core move can
take the folder with the Vaultwarden engine, and the extension can add a
Kemlock backend later. Sheets live in `lib/features/sync/`
(`kemlock_sheet.dart`, `kemlock_login.dart`, `kemlock_devices.dart`,
`kemlock_approval.dart`).

*Weighed:* building inside `packages/kemlock_core` after the move. That
blocks this plan on unrelated work, while a folder with no Flutter import
moves with one `git mv`.

### 2. A run is a scope of its own, `kemlockScope`

`SyncSettings` gains `kemlock`, a `KemlockTarget`. It holds the account's id
and email, the server list (decision 12), the device id, a certificate pin
per server, and `extra`.

- **The invariant:** at most one of `personal` and `kemlock` holds the
  vault's own entries.
- `vaultwarden` may sit beside `kemlock` only as the Bitwarden copy that
  `move-off-vaultwarden-sync` keeps, which its scope state marks
  `copyOf`.
- `syncsOwnEntries` counts `kemlock`.
- An older build keeps `kemlock` in `extra`, sees sync as off, and may turn
  WebDAV on beside it. When this build then finds both, it pauses both and
  asks which keeps the vault's own entries.

The scheduler adds `(key: kemlockScope, scope: null, sync: _kemlockScope(...))`.
So the schedule, the race guard (`_revision`) and `applySynced` work
unchanged. A run, in `km_sync.dart`:

1. Load the sealed cache `backmycodes_kemlock_cache`. It holds the server's
   items as this phone last opened them: per id, the revision, the kind and
   the decrypted entry JSON. It also holds the cursor, the highest manifest
   seen, and the removal counts.
2. Read `GET /kem/v1/sync?since=<cursor>`, page by page. Open each item
   through `add-account-crypto` and apply it, provisionally, to a copy of
   the cache.
   - A tombstone removes the cached item with `at = min(at, now)`.
   - An item of a kind this build doesn't know stays in the cache untouched
     (decision 3).
3. Check the manifest (decision 5). A rolled-back, missing or resurrected
   item stops the run with `SyncProblem.older` before anything is stored.
   An unlisted item is held out of the copy and flagged.
4. Build the remote `SyncDoc` from the cache, then run
   `mergeScope(await combineKeyCopies(local, remote), state.known, remote, now: now)`,
   as `syncScope` does for WebDAV.
5. Diff the merged doc against the remote into puts and deletes, and run the
   removal guard (decision 6).
6. Seal each put. Send `POST /kem/v1/items:batch` in chunks of up to 500,
   each write carrying `If-Match: <revision>`, or create-if-absent for a new
   id. A note's files go up first (decision 16).
7. On a 409, read the delta again from step 2's cursor, merge and resend.
   That is three attempts, as `syncScope` makes. Ids are made on the phone,
   so a resent batch never duplicates.
8. If the run wrote anything, sign and send the new manifest: one per run,
   after the last batch, as `add-account-crypto` design 6 requires. Store
   the cache with the new cursor and the deleted-id record. Return the
   merged doc, `known` and the scope state.

The cursor is stored only in step 8. A run that dies midway repeats from the
old cursor.

*Weighed:* no decrypted cache, with the remote doc rebuilt from a full
download each run. That throws away the cursor's point: a 1,000-item vault
would download everything every five minutes.

### 3. One `kem1` item per entry, its JSON the entry's own

Each `VaultEntry` becomes one item, whose plaintext is the entry's
`toJson()`. So `extra` keys of later versions survive a round trip, as they
do in sync files.

**Ids.** An entry whose id is a UUID keeps it as the item id. Any other id,
such as 0.1.0's `acc-1` or a 16-hex id, is mapped by `crypto.md`'s "Legacy
ids": `uuidv8(SHA-256("kemlock/v1/legacy-id" ‖ lp("item") ‖ owner ‖ lp(old
id)))`, through `add-account-crypto`'s `legacy_ids.dart`. The entry's JSON
keeps its own `id`, and the cache and the merge pair copies by that id, so
`mergeScope` sees exactly the ids it sees today. The server never needs to
accept string ids. Because the owner is part of the mapping, an entry with
an older id that moves between the vault and a space gets a new UUID. The
server sees a delete under one owner and a create under the other, and the
phone pairs them by the original id.

**Kinds**, from `crypto.md`'s list, one per entry, decided by the entry's
list and, for keys, by the key's kind, which never changes once a key is in
the vault:

| List | Kind |
|---|---|
| `accounts` | `otp` |
| `backupServices` | `backup-codes` |
| `keys` with `KeyKind.pgp` | `pgp-key` |
| `keys` with `KeyKind.ssh` | `ssh-key` |
| `keys` holding a certificate | `certificate` |
| `keys` with `signing`, `exchange` or `other`, no certificate | `key` *(not in `crypto.md` yet)* |
| `notes` | `note` |
| `passkeys` | `passkey` |
| `keyAccounts` (codes whose secret lives on a security key) | `key-otp` *(not in `crypto.md` yet)* |
| `contacts` | `contact` *(not in `crypto.md` yet)* |
| `logins` | `login` |
| from `add-cards-identities-and-websites` | `card`, `identity` |

The kind sits in the item's additional data, so the server can't relabel an
item. A kind this build doesn't know is never deleted and never written. A
key rotation passes it through. These names are a contract with the server,
the web vault and Amethystora Vault. Those marked *(not in `crypto.md` yet)* wait for the server session to add
them, and the kinds fixture holds only the names `crypto.md` lists.
`mobile/test/fixtures/kemlock/items.json` pins each kind's plaintext JSON,
written once only after task 1.2 has the server's confirmation of every
name.

`move-off-vaultwarden-sync` takes this kind list as the list of what moves,
so a kind added later moves without code there.

### 4. What this plan calls in `add-account-crypto`

- `OpaqueClient` registration and sign-in, giving the export key;
- the Argon2id master key, and opening the user key under it and the export
  key;
- sealing and opening a `kem1` item, bound to id, revision, kind and owner;
- the legacy-id mapping for ids that aren't UUIDs;
- the manifest: sorting a returned set into expected, rolled back, missing,
  unlisted, resurrected and sibling, and signing a new one;
- the sealed box under the `"device-approval"` context, used to seal the
  root to an approval request's one-time key and to open this phone's own
  answer;
- wrapping the root under a passkey's PRF output, and the trusted-device
  primitive (its task 7.4), whose flow is this plan's task 4.3;
- fingerprints, including the approval fingerprint (decision 11), and
  `FingerprintView`;
- verifying a server's ML-DSA-65 + Ed25519 signature, for promotion records.

Groups 3 to 11 of the tasks are written and tested against a fake of this
interface. Group 13 swaps in the real one and runs the server's vectors.

### 5. The manifest turns a rollback into a stopped run

After step 2 the phone asks `add-account-crypto` to sort the returned set
against the highest manifest it has seen and the deleted-id record it keeps
(that plan's design 6, which owns the rule).

- **Rolled back** (an item older than the manifest), **missing** (an id the
  manifest lists without a tombstone) and **resurrected** (an id this phone
  saw deleted that comes back, even after its tombstone left the manifest)
  stop the run. A manifest whose signature or counter fails stops it too.
  Each shows as `SyncProblem.older`, the problem WebDAV uses for an old
  file.
- **Unlisted**: an item that opens but isn't in the latest signed manifest,
  or is newer than its entry, is held, not applied, and flagged on the
  sheet. Another device of the account signs a manifest at the end of the
  run that wrote it, so a held item is normally listed by the next sync.
  One still unlisted after 24 hours is shown as a problem. "Only a key
  holder could seal it" isn't trusted: a device signed out, or a server
  replaying old envelopes, must not be able to add items.
- **Siblings** go to the merge.

The deleted-id record keeps each id seen deleted, with its revision, for
180 days, as long as tombstones are kept. It lives in
`backmycodes_kemlock_cache`.

At the end of a run that wrote anything, the phone signs one manifest of
the merged state and sends it after the last batch. The server's app contract (not built yet)
has `PUT` and `GET /kem/v1/manifests/{owner}`, the owner `user:<uuid>`, with
`{"manifest", "signature"}` as base64url; a counter at or below the stored one is a 409 `stale-manifest`.

### 6. One removal guard for both servers

Vaultwarden's two rules move unchanged into `sync/removal_guard.dart`:

- more than three removals and more than a quarter of the scope;
- counted together with the last day's removals in `removalWindow`.

That move is its own refactor commit. Vaultwarden and Kemlock Server then
call the same code, and the same cases pin both. A stopped run raises
`SyncProblem.removals` with its count, and the sheet's Keep and Remove
reuse `RemovalChoice`.

### 7. Sign-in, step by step, as data

`km_signin.dart` returns `KmSignInStep` values, as `VwSignInStep` does, so
each sheet is a plain view and each step a unit test.

1. `GET /kem/v1/config` on the typed address. The client refuses a
   non-https address, an answer not shaped like a Kemlock config, and a
   redirect.
2. `POST /kem/v1/auth/methods` with the email (confirmed). The answer
   lists the ways in, SSO's provider name, and whether "Require SSO"
   applies.
3. One of:
   - **Password, OPAQUE.**
     1. The Argon2id settings and salt come first, from a prelogin-style
        call, `POST /kem/v1/auth/prelogin` (confirmed), so the master key exists before KE1. The
        phone checks the settings against fixed bounds before any work: 2
        to 10 passes, 16 to 1,024 MiB, and 1 to 16 lanes, Amethystora's
        bounds in the design.
     2. Then `…/auth/opaque/start` with KE1, and `…/finish` with KE3.
   - **Password, a Compatible account without OPAQUE.**
     1. Bitwarden prelogin, with the KDF checked by `bitwarden.dart`'s
        existing bounds.
     2. The hash goes once to the route that takes it (the server has none yet; built to
        `…/auth/bitwarden`).
     3. The phone runs OPAQUE registration in the same session *(route to
        confirm)*, then signs in again through OPAQUE.
     4. The user key is the Bitwarden one, so it doesn't change.
   - **No downgrade.** Once this phone has seen an account enrolled in
     OPAQUE (a successful OPAQUE sign-in or registration), it records that
     in `backmycodes_kemlock_account` as `opaqueEnrolled`. From then on it
     refuses the Bitwarden-hash route for that account, whatever the server
     says. OPAQUE can't tell a plain wrong password from a server that
     isn't the one set up, so the sheet says both: "Wrong password, or this
     isn't the server you set up", with the server's address, and nothing
     derived from the password is sent. A hostile or rolled-back server can
     always claim OPAQUE isn't enrolled, so only the phone's own record can
     close the route. Removing the
     record needs the person to turn sync off for that account.
   - **Passkey or security key.** `…/auth/passkey/options`, then `…/verify`
     (decision 8).
   - **SSO** (decision 9).
4. **A second step**, when the server asks for one. The phone answers an
   authenticator code, an email code, or a security key through the CTAP
   path Vaultwarden's provider 7 uses.
5. **Device registration**:
   - the device key's public JWK;
   - the name ("Kemlock on <model>");
   - the push token, if any;
   - the vault's Vaultwarden device identifier (`VwCredentials.deviceId`),
     when the vault syncs or synced with Vaultwarden on this server's
     Bitwarden API.

   With that identifier, the server shows one device with each API's last
   use, which `move-off-vaultwarden-sync` relies on to tell when no device
   uses the Bitwarden API any more. The sheet then offers "Trust this
   phone", on by default, which sends the user key wrapped by the
   trusted-device key.

Tokens and the device id are sealed in `backmycodes_kemlock_session`. The
account's user key and key pairs are sealed in `backmycodes_kemlock_account`,
in `add-account-crypto`'s format. Turning sync off deletes both. The
trusted-device copy on the server and the hardware key stay until the
person removes trust. That is the point of trust: turning sync back on
with SSO opens the account without an approval.

### 8. Passkeys with PRF: security keys everywhere, platform passkeys on Android

This is owner decision 4.

- **Security keys over NFC and USB, on both platforms.** They go through the
  app's own CTAP stack, as `add-vaultwarden-security-key` does.
  - The client data claims the server's web-vault origin, by `vwKeyOrigin`'s
    rule.
  - PRF is hmac-secret with WebAuthn's salt mapping,
    `SHA-256("WebAuthn PRF" || 0x00 || input)`.
  - This works with any server.
- **Platform passkeys on Android 14 and later.** They go through Credential
  Manager with the `prf` extension, when the server serves
  `/.well-known/assetlinks.json` with Kemlock's certificates. The Play and
  F-Droid signing certificates differ, and both must be listed.
- **No platform passkeys on iOS.** The sheet offers a security key, SSO or
  the password.

The PRF output never leaves the phone. It goes straight into the unwrap.

*Weighed:* the ceremony in the web vault through `ASWebAuthenticationSession`,
with the PRF output passed back in the callback. That puts a secret that
opens the vault in a URL.

### 9. SSO through the system browser sheet, bound with PKCE and the device key

The server runs the code flow with PKCE against the provider. The phone adds
a second PKCE between itself and the server.

1. The phone makes `verifier`, and sends `challenge = S256(verifier)`, a
   `state`, and its DPoP proof to `POST /kem/v1/auth/sso/start`.
2. It opens the provider address it got back:
   - on iOS, in `ASWebAuthenticationSession` with callback scheme `kemlock`.
     The callback reaches only the session that started it.
   - on Android, in Custom Tabs, returning through an activity filtered on
     `kemlock://sso` and checked for `state`.
3. The server's callback ends at `kemlock://sso?code=<one-time>&state=…`.
4. The phone sends the code and `verifier` with a DPoP proof to
   `POST /kem/v1/auth/sso/finish` (the server has the route; `km_sso.dart` was read against it). The server checks that
   both match step 1.

The audit noted that another app can claim the `kemlock` scheme. A code
taken that way is useless without `verifier` and the device key. Opening
the account follows: the trusted-device copy first, else an approval
request (decision 11), else the master password. The channel is
`platform/browser_auth.dart` with a Kotlin and Swift side (owner decision 5),
listed in `network_callers_test.dart`.

*Weighed:* `flutter_web_auth_2`, which does the same with a dependency and
its own redirect activity. It is the fallback if the channel grows.

### 10. DPoP with a hardware P-256 key

The Secure Enclave and the Keystore do ECDSA P-256 only, so proofs are ES256.

- **iOS**: a Secure Enclave key, `AfterFirstUnlockThisDeviceOnly`, without
  user presence, so a sync needs no prompt.
- **Android**: a Keystore key, StrongBox when present, without user
  authentication.
- **No hardware key**: a software P-256 key sealed in the vault, and the
  sheet says so (owner decision 6).

The proof:

- header: `typ: dpop+jwt`, `alg: ES256`, `jwk`;
- claims: `jti`, `htm`, `htu` (the exact URL without query or fragment);
- `iat`, corrected by the server's `Date` offset when the phone's clock is
  off by more than a minute;
- `ath` with a token, and the last `DPoP-Nonce`.

A 401 with `use_dpop_nonce` is retried once. The same key signs the replica
sign-in challenge (decision 12). Keys are tagged by vault and account, so
vaults stay apart.

*Weighed:* Ed25519 proofs, which neither secure element does.

### 11. Approvals and the fingerprint

The phone reads `GET /kem/v1/devices/approvals` while the vault is open: on
open, on a nudge, and each sync. It shows pending requests in a sheet over
the current screen.

Both devices show the request's approval fingerprint, as
`add-account-crypto` design 5 defines it: SHA-512 over the request id and
the one-time `kx1` public key, shown as 12 groups of 5 digits through
`FingerprintView`. It is the same display rule as every Kemlock
fingerprint, with no short form. Its derivation is listed under "Agreed
with the server", and the server's vectors pin it.

- **Approve**:
  1. The phone asks the owner through `ownerCheckProvider`, always, whatever
     "Ask before showing a secret" says.
  2. It seals the root to the request's `kx1` key in a sealed box under the
     `"device-approval"` context.
  3. It posts the sealed blob.
- **Deny** posts a refusal.
- **When this phone waits for approval after SSO**, it makes the one-time
  key pair and shows its fingerprint. It polls the request every 2 seconds
  for up to 15 minutes, then opens the answer.

*Weighed:* the canvas's five-word phrase. One format for every fingerprint
needs no word list in every language, and the server's contract fixed
digits.

### 12. Failover is a small state machine with a fake clock

`km_failover.dart` holds the vault's server list. Each server has an
address, an identity key pinned at first sight, an optional certificate pin
and a role. The list also holds the home epoch. The state is `onHome`,
`onReplica(since, index)` or `returning(healthySince)`.

- **Failures.** Every request goes through `KmFailover.send`. A request that
  doesn't connect, or gets no first byte within 10 seconds, is a failure.
  Any answer, even 500 or 409, counts as reached.
- **Switching.** Two failures in a row, or the 10-second timeout, move the
  phone to the next server. It signs in there with the device key: a
  challenge from `POST /kem/v1/auth/device-key/challenge` (the device id,
  with a DPoP proof of the key), sent to `…/auth/device-key/verify` with a
  proof of the same key. The routes are for accounts copied to the replica.
- **Returning.** On a replica, each sync also reads the home's
  `/kem/v1/config`, at most once a minute. Five minutes of unbroken answers
  return to the home. One miss resets the clock.
- **A new list** comes from `GET /kem/v1/config?vault=user:<uuid>`: the
  epoch, the servers (id, address, identity key, role) with the home first,
  and the signed promotion record of that epoch. It must name at least one
  known server. A new home, or a later epoch, also needs the record, an
  envelope signed `sig1("federation-promotion", body)` by the new home with
  the identity key already pinned for it, for this vault and epoch and
  naming the list's own servers. Otherwise the list is refused and shown.
- **Siblings.** When two servers accept writes to one item apart, `GET
  /kem/v1/sync` lists the versions held beside the head as `siblings`. The
  phone merges them into the head with the field merge of every sync, writes
  the result as the next revision, and calls `POST
  /kem/v1/items/{id}/siblings/resolve`, which the server refuses with a 409
  once the head went to another server; the next run then writes a newer
  version and resolves again.
- **Home-only changes.** While on a replica, the master password and
  two-step changes are refused with `KmHomeAway`.

Time comes in as `DateTime Function()` with fake timers, as `SyncScheduler`
takes it, so each behaviour below is a unit test.

### 13. Nudges: push in the store build, the live socket while open

- **Push** is a `kemlock_ports` interface, `PushTokens`, with `token()` and
  `onMessage`.
  - The store build implements it with APNs through a Swift channel (the
    Push Notifications capability and the `remote-notification` background
    mode).
  - On Android, the store build returns no token and `available` is false,
    as `parts_free` does: no Firebase (owner decision 2, as changed on
    2026-11-22), so a nudge reaches the phone through the live socket and
    the schedule while the app is open. UnifiedPush may follow, through
    this same port.
  - `parts_free` returns no token.
  - A nudge carries only its type, `sync` or `approval`.
- **A `sync` nudge** runs the scheduler when the vault is open, and is
  dropped otherwise.
- **An `approval` nudge** raises a notification with fixed text and no
  names: a local one through `flutter_local_notifications` on Android, and
  the relay's alert push on iOS. Tapping it opens the unlock, then the
  approval sheet.
- **The live socket.** `/kem/v1/live` is a WebSocket, open only while the
  app is in front with the vault unlocked.
  - Its upgrade carries DPoP.
  - A `sync` frame runs the scheduler.
  - Reconnects back off from 2 s to 5 minutes, and the five-minute
    schedule stays as the floor.
  - The socket is made in `platform/network.dart`, behind the gate.

### 14. How this fits the work in flight

- **`add-offline-mode`.** Every request, the browser sheet, the socket and
  push registration pass `NetworkGate`.
- **`add-cloud-drive-sync`.** Every sync backend is free, Kemlock Server
  included (owner decision 1).
- **`add-browser-extension`.** Decision 1 applies: no gate.
- **`add-fdroid-release`.** The free build stays free of Play services.
  `network_callers_test` and that change's class scan keep checking it.
- **`add-passwords`.** Logins sync to Kemlock Server, which Vaultwarden
  sync never did (its decision 7).

### 15. Contract: a hand-written client held to the spec

The client is written by hand (owner decision 9). When the server publishes
its OpenAPI 3.1 JSON, it is copied into
`mobile/test/fixtures/server/openapi.json` with the server commit it came
from, beside the vectors `add-account-crypto` copies there.

A contract test then fails when the client uses a route, method, header,
field or status the spec lacks, or with another type. The fake server
answers with the spec's examples. Until then, `fake_kemlock_server.dart`
follows the design doc, and `mobile/test/fixtures/kemlock/README.md` lists
every route the server lacks.

### 16. Limits on what the server can send

- **Redirects:** none followed, on any route.
- **JSON:** stops at 2 MiB, the server's own body cap. A sync page stops at
  8 MiB.
- **Files:**
  - A note's file stops at the size its item names, and at the app's
    largest attachment.
  - It is uploaded before the item that names it.
  - A pre-signed URL may point at another host. It must be https and gets
    no `Authorization` or DPoP header.
- **Timeouts:** 30 seconds per route, with the failover rule's 10 seconds
  to the first byte.
- **Pins:** identity-key and certificate pins are per server. A pin never
  widens trust beyond one certificate.

### Risks

- **The server's routes change while this is built.** Each unnamed route is
  marked, task 1.2 reconciles them, and the contract test catches drift.
- **`add-account-crypto` is late.** The engine codes against its interface
  and closes only after group 13 runs the real vectors.
- **iOS has no platform passkeys.** Security keys, SSO and the password
  cover it, and the sheet doesn't offer what can't work.
- **A closed Android app learns of a change late.** With no Firebase there
  is no push to a closed Android phone (owner decision 2, as changed on
  2026-11-22): it syncs at the next schedule run or the next open, and an
  approval request waits until then. UnifiedPush may close that gap later.
- **The relay sees when an account's devices change.** It sees device
  tokens and times only. Kemlock is their processor under a data processing
  agreement (the design's Decisions table), and the sign-in sheet says so.
- **A large first sync is slow.** Opening and sealing run in an isolate in
  batches of 500, with progress on the sheet.
- **A wrong clock breaks DPoP.** The `iat` offset and the server's nonce
  handle it.

### Rolling back

Nothing stored changes. `SyncSettings.kemlock` and the three sealed keys are
new. An older build keeps `kemlock` in `extra` and sees sync as off. The
vault's entries and WebDAV spaces stay, and the account stays on the server.

## Behaviour

### The backend

- **Kemlock Server is a sync backend.** Settings › Sync offers it beside a
  WebDAV folder and Vaultwarden. Only one of WebDAV and Kemlock Server
  holds the vault's own entries. Choosing one while the other is on asks
  first. WebDAV spaces keep syncing.
  - *Sync off:* the sheet offers "WebDAV folder", "Vaultwarden" and
    "Kemlock Server".
  - *From WebDAV:* picking Kemlock Server says WebDAV sync of own entries
    stops, and changes nothing until confirmed.
  - *A WebDAV space:* its file keeps syncing on the same schedule, byte for
    byte.
- **The server is checked before anything is sent.** Only `https`, and
  `/kem/v1/config` is read before any sign-in. A certificate the phone
  doesn't trust is offered only by fingerprint comparison, then pinned.
  - *Plain http:* refused, nothing sent.
  - *Not a Kemlock Server:* says so, and offers Vaultwarden when
    `/api/config` answers.
  - *Self-signed:* the SHA-256 fingerprint is shown; one certificate is
    trusted after the person confirms.
- **A Vaultwarden address that serves the Kemlock API offers the move.** At
  a sync, when `/api/config` says `/kem/v1` exists, the Vaultwarden sheet
  shows "This server also speaks Kemlock's own API" with Move and Not now.
  The offer shows at most once a day until answered, and changes nothing
  on its own.
  - *Not now:* the offer stays hidden until Settings › Sync is opened on a
    later day.

### Signing in

- **The sign-in offers the account's ways in.** SSO comes first when the
  email's domain uses it, then a passkey or security key, then the password.
  Ways a space's "Require SSO" blocks are hidden.
  - *An SSO domain:* "Continue with Example Co SSO" first, the others below.
  - *SSO required:* only SSO, with the reason; an owner or admin still sees
    every way.
- **The master password signs in through OPAQUE.** No hash of the password
  is sent. The export key and the Argon2id master key open the user key.
  - *Right password:* signed in, user key held, no request carried the
    password or a hash.
  - *Wrong password:* "wrong email or password", no lockout.
  - *The salt first:* the Argon2id settings and salt are read before KE1 is
    sent.
- **No downgrade to the password hash.** Once the phone has seen an account
  enrolled in OPAQUE, it never sends the Bitwarden hash for it again.
  - *The server later claims OPAQUE isn't enrolled:* the sign-in stops with
    "Wrong password, or this isn't the server you set up", naming the
    server's address, and nothing derived from the password is sent. A plain
    wrong password reads the same, as OPAQUE can't tell the two apart.
- **A Compatible account moves to OPAQUE once.** The Bitwarden hash goes
  once to the Kemlock route that takes it. OPAQUE is enrolled in the same
  sign-in, and later sign-ins use OPAQUE. KDF costs are checked first.
  - *First sign-in of a copied account:* one hash, then OPAQUE, no second
    prompt.
  - *A PBKDF2 cost of 1:* the sign-in stops before anything derived from
    the password is sent.
- **A passkey or security key with PRF signs in and opens the account.**
  Without PRF, opening goes on by approval or password.
  - *A security key with PRF over NFC or USB:* signed in and open.
  - *No PRF:* the sheet asks for approval or the password.
  - *iOS:* no platform passkey is offered.
- **SSO signs in through the system browser.** The provider opens in the
  system's sheet, never a view the app draws. PKCE and the device key bind
  the result. A cancel leaves the phone signed out.
  - *SSO:* signed in once the sheet closes, then opening the account.
  - *Another app takes the redirect:* it can't finish without the verifier
    and device key.
- **After SSO the account opens on the phone.** It opens by the
  trusted-device key without asking, by an approval after both devices show
  the same fingerprint, or by the master password. "Trust this phone" is on
  by default, explained, and removable.
  - *Approval:* a new phone opens the account once the other phone
    approves with the same 12 groups of digits.
  - *Trusted phone:* after sync was turned off and on, SSO alone opens the
    account.
  - *An account SSO just made:* it has no keys yet, so this phone makes
    them and its trusted-device copy of the root key and opens the account
    with no further step. If another phone enrolled first, it goes on as
    for any account with keys.
- **Two-step login follows the password.** The phone answers an
  authenticator code, an email code, and a security key. Other methods are
  named and sent to the web vault.
  - *A code:* signed in.
  - *Only Duo:* the sheet says to sign in from the web vault.
- **Tokens are bound to the phone.** Every request with a token carries a
  fresh proof from the device key. Tokens are kept only sealed, and each
  refresh token is used once.
  - *Copied tokens:* refused elsewhere, since no proof can be signed.
  - *No hardware key:* a software key sealed in the vault, and the sheet
    says so.
- **The phone is one device for both APIs.** When the vault syncs or synced
  with Vaultwarden on the same server, registration sends that
  Vaultwarden device identifier.
  - *A vault on Vaultwarden that signs in to Kemlock Server:* the devices
    list shows one "Kemlock on Pixel 9" with both APIs' last use, not two
    rows.
- **Signing out and being signed out.** Turning sync off signs out on the
  server and deletes the session. When the server ends the session, the
  phone says why and keeps every entry.
  - *Signed out from the web vault:* the next sync says so and offers to
    sign in.
  - *A refresh token used twice:* "the session was ended for safety", sign
    in again, entries kept.

### Syncing

- **A run takes only what changed.** The cursor is sent back unread. The
  first run takes everything. The cursor is kept only after the merge is
  stored.
  - *Nothing new:* nothing downloaded, nothing written.
  - *Dropped midway:* the next run repeats from the previous cursor, and
    nothing is lost.
- **Entries merge on the phone as WebDAV sync merges them.** The later copy
  wins. A losing password goes to previous passwords, HOTP never goes
  down, PGP copies combine, and a deletion loses to a later edit.
  - *Two phones edit one login:* both keep the later password, the other
    first among previous passwords.
  - *Edited after a delete elsewhere:* the entry stays with the edit.
- **Writes go up in checked batches.** At most 500 per batch. Each write
  names the revision it replaces. A refused write is merged again and
  resent, up to three times per run.
  - *Another device wrote first:* the newer copy is merged and written with
    the new revision.
  - *1,200 entries:* three batches. A failed batch resent at the next run
    makes no second copy.
- **A run that would remove many entries waits.** The limit is more than
  three removals and more than a quarter of the vault, counted with the
  past 24 hours. The sheet offers Keep them and Remove them.
  - *Five of 40 removed at each of four runs in an afternoon:* the run that
    crosses a quarter stops and asks.
- **Deletions are kept long enough.** Deletions go up as tombstones. A
  tombstone removes the entry unless the phone's copy is newer. A future
  date counts as now.
  - *A tombstone dated next year:* it removes only an entry unchanged since
    it arrived.
- **Older items are refused.** A rolled-back, missing or resurrected item,
  or a manifest that fails, stops the run before anything is stored. An
  item no signed manifest lists is held and flagged, not applied.
  - *Revision 3 served where the manifest says 5:* nothing stored, "the
    server handed back an older copy of the vault".
  - *An entry deleted in March served again in October:* refused, though
    its tombstone has left the manifest.
  - *An item no manifest lists:* held; applied once another device's
    manifest lists it.
- **Older ids keep working.** An entry with an id like `acc-1` syncs under
  its mapped UUID and keeps `acc-1` in the vault.
  - *Two phones from 0.1.0:* both send `acc-1` under the same UUID, and the
    merge pairs them as WebDAV does.
- **A note's files travel as their encrypted bytes.** The same `KMA1` bytes,
  uploaded before their item, capped on download.
  - *A 3 MB photo:* the second phone gets the same bytes and opens it.
  - *More bytes than promised:* the download stops at the limit and nothing
    is stored.
- **Sync runs on the schedule and when nudged.** It runs on open, a moment
  after a change, on coming to the front, and every five minutes in front.
  A nudge also runs it while the vault is open. Nudges carry no data and
  never sync a locked vault.
  - *An edit in the web vault:* the open phone syncs within seconds.
  - *Locked:* nothing fetched; sync on next open.
  - *F-Droid build:* no push offered; the sheet says changes arrive while
    the app is open.
- **Offline mode pauses Kemlock Server.** Offline mode stops every request:
  sign-in, sync, the socket, push registration, approvals and health
  checks.
  - *Turned on mid-sync:* no further request; the sheet shows sync paused.
- **Problems are said in plain words.** A failed run keeps the entries as
  they were and shows one problem: unreachable, session ended, write
  refused, older data, removals waiting, home away, or not supported by
  this version.
  - *Turned off:* signed out, session and cache deleted, entries kept.

### Devices and approvals

- **A sign-in request shows on the phone.** While the vault is open, the
  sheet shows the device, its address, its age and the approval
  fingerprint, with Deny and Approve. A request older than 15 minutes is
  dropped.
  - *A browser asks:* "Firefox on Linux is asking to sign in as you", with
    the same 12 groups of digits the browser shows.
- **Approving seals the root to the requesting device.** Approve asks the
  owner, then sends only the sealed blob. Deny sends no key.
  - *Same digits:* biometrics, sealed key sent, the other device opens.
  - *Different digits:* the sheet says to deny.
- **Requests reach a phone that isn't open.** A notification names no device
  or account. Tapping it opens the unlock, then the request. The F-Droid
  build shows requests at the next open.
- **The account's devices are listed, with each API's use.** Each row shows
  the name, what it opens, and its last use of the Kemlock API and of the
  Bitwarden API, either one "never". This phone is marked. Any other device
  can be signed out, and "Sign out everywhere else" is offered.
  - *The Bitwarden extension:* listed with its last Bitwarden API use and
    "Kemlock API: never".
  - *This phone after a move:* one row with both dates, the Bitwarden one
    going stale once its copy stops.
  - *Signing out "Kemlock on Pixel 9":* its session ends and the row goes.
- **This phone's trust can be removed.** The server deletes its wrapped
  copy and the phone deletes its hardware key. The next SSO sign-in needs
  an approval or the password.

### Failover

- **The phone keeps the vault's server list.** The home comes first, then
  replicas, sealed, with identity keys as first seen. A list naming no known
  server is refused.
  - *One replica:* both kept, home first.
  - *A list of strangers:* the old list is kept and the answer is shown as a
    problem.
- **The phone switches after two failures or ten seconds.** An error answer
  from a reached server is not a failure.
  - *The home goes down:* the phone signs in to the first replica and the
    run goes on.
  - *A 409 from the home:* merged and retried on the home.
- **A replica is signed in with the device key.** No password. A replica
  that doesn't know the device yet is reported, and the phone keeps trying
  the others.
- **The phone returns after five healthy minutes.** One failed check
  restarts the clock.
  - *3 minutes up, one miss, up again:* the phone stays on the replica for 5
    more healthy minutes.
- **A new home needs a valid promotion record.** The record must be signed
  by a known server with a higher epoch.
  - *A planned move:* taken.
  - *Signed by an unknown key:* the old home is kept first, and the sheet
    says the server list couldn't be checked.
- **Home-only changes wait.** Items keep syncing. Password and two-step
  changes are refused with the reason. The sheet shows the server in use and
  since when.
  - *The sheet while away:* "Home server offline since 09:12", "Using VPS
    (Germany)".

## Tasks

No task runs a build, a test, CI or `pub get` in a subagent. Each "verify"
names the test that the single build-and-test pass after merging runs, or a
check the owner makes on a device. The commit scope is `sync`, which the
main session adds to `CLAUDE.md` in a `docs` commit before building starts,
with `android` and `ios` for the native channels. Tests go in their own
`test(sync)` commits after their code.

This plan owns the `SyncSettings` invariant (task 2.1) and the `/api/config`
discovery (task 12.2); `move-off-vaultwarden-sync` uses both.

### 1. Groundwork and the contract

- [x] 1.2 Settle every route, the kind names, the `/api/config` flag's name, the device registration's Vaultwarden identifier field, and the approval fingerprint's derivation with the server's code, and record them in `mobile/test/fixtures/kemlock/README.md` and in this plan. Verify that nothing is left marked to confirm in either. (Read from the server's `build/vertical-slice`: every route the client calls is served and settled against its code, and recorded in the README. The server list and promotion record, the replica sign-in, siblings, passkeys with PRF, the approval poll's `accountId`, the account's keys, the manifest, the device list, the Bitwarden enrolment, the four SSO routes (start, callback, finish, backchannel-logout; `km_sso.dart` matches their bodies, answers, PKCE and `kemlock://sso` redirect), and the push token are served. The push token is not a member of the device body, which refuses unknown fields; the client registers it at `POST /kem/v1/devices/push-token` as `{kind: "fcm" or "apns", token}`. The `/api/config` flag is the `kemlock` member `{api: "<domain>/kem/v1", versions: ["v1"]}`, which `KemlockOffer.fromConfig` reads. Not served, and the client does without: the provider name and "Require SSO" in `/auth/methods`, passkeys in `/auth/methods`, and a file's size and SHA-256 in `FileDto`. Not checked: the WebAuthn second step's challenge options, which the client does not call, as it offers a code, authenticator or email as a second step. Kinds `key`, `key-otp` and `contact` are not in `crypto.md`; the server takes any kind of 1 to 64 characters. Nothing is marked to confirm in the code or the README.)
- [x] 1.3 Add `fake_kemlock_server.dart` in `mobile/test/features/sync/kemlock/`, in the style of `fake_vaultwarden.dart`. It serves config, methods, OPAQUE with a fake crypto, sync pages, batches with `If-Match` and create-if-absent, 409, files, approvals, devices, device challenges and tokens with DPoP checks. Verify with its own smoke test that a batch put sent twice leaves one item.
- [x] 1.4 Add the `add-account-crypto` interface of design decision 4 as an abstract class with a fake. Verify that the fake seals and opens an item, and that a changed revision fails to open. (`add-account-crypto`'s Dart landed first, so `km_crypto.dart` holds only the part the run uses, items and the manifest, with `AccountItemCrypto` over the real code; sign-in's parts join it in group 5. The fake keeps the real `kem1` and signs with a cheap MAC.)

### 2. Settings and stored state

- [x] 2.1 Add `KemlockTarget` and `SyncSettings.kemlock`, keeping unknown keys. Add the invariant of design decision 2, including the `copyOf` exception for the Vaultwarden copy. Verify with model tests: round trips, unknown keys, older settings byte for byte, and the both-set case reading as "ask".
- [x] 2.2 Add `backmycodes_kemlock_session`, `backmycodes_kemlock_account` and `backmycodes_kemlock_cache` as sealed values. Verify that `test/vault/unknown_sealed_value_test.dart` lists them, that `VaultRegistry.removeVaultData` removes them, and that a key-pair replacement re-seals them.
- [x] 2.3 Add `kemlockScope` to `SyncScheduler` beside WebDAV and Vaultwarden. Verify with `sync_scheduler_test.dart`: the scope runs on open, settle, front, the period and Sync now, and a run that raced a user change is redone. (code done; the host makes the backend once sign-in exists)
- [x] 2.4 Put no gate on the backend (owner decision 1). Verify with a widget test that the sync sheet opens for Kemlock Server as it does for Vaultwarden, with no check. (The sync sheet is one sheet for every backend and opens with no check; the widget test is the existing sheet's.)

### 3. The client, its limits and DPoP

- [x] 3.1 Write `km_api.dart` with design decision 16's limits: no redirects, caps, timeouts, per-server pins through `vw_http.dart`'s client, all through `NetworkGate`. Verify with tests against `MockClient`: a 302 isn't followed, a 3 MiB JSON answer and an endless body are refused, a pre-signed URL gets no `Authorization` or DPoP.
- [x] 3.2 Write `km_dpop.dart` over a `DeviceKey` interface with a software P-256 key. Verify against RFC 9449's examples for shape, an ES256 signature check, `ath`, the `DPoP-Nonce` retry, and the clock offset from `Date`.
- [x] 3.3 Add the client to `network_callers_test.dart`'s allowed files only where it makes a client. Verify that the test passes and still fails for any other file. (No allowed file is added: the client takes the app's gated client and makes none, so the list stays as it is and a new test names the Kemlock folder.)

### 4. The device key on the phone

- [x] 4.1 Add `platform/device_keys.dart` with a Swift side (a Secure Enclave P-256 key, `AfterFirstUnlockThisDeviceOnly`, no user presence) and a Kotlin side (a Keystore P-256 key, StrongBox when present, no user authentication). Commit each side in its own `feat(ios)` and `feat(android)` commit. Verify with a Dart test over a fake channel, Kotlin unit tests of the key's parameters, and an XCTest of the key's attributes, all in the single pass after merging (Swift on CI's macOS job). (code done; verify after merge: the Dart test over a fake channel, the Kotlin tests of the key names, parameters (P-256, SHA-256, AES-256-GCM, no user authentication, StrongBox from API 28) and the keystore wrap, and the XCTest of the key attributes are written but not built here, and the keys themselves are made and used on a phone in task 13.4. The one `com.kemlock.app/device_keys` channel carries signing and wrapping keys, so the trusted-device primitive of `add-account-crypto` 7.4 uses its `wrap` and `unwrap` and has no channel of its own.)
- [x] 4.2 Fall back to the sealed software key when no hardware key exists, with the sheet's line. Verify with a widget test over a channel that reports no hardware. (The line is a message, kemlock.deviceKey.software; the sign-in sheet that shows it is task 5.2, so the widget test waits for it. The resolver's tests use a fake that reports no hardware.)
- [x] 4.3 The trusted-device flow only: "Trust this phone", uploading the wrapped copy, using it after SSO, and removing trust. It calls `add-account-crypto`'s trusted-device primitive (its task 7.4), which owns the hardware key. Verify with a test over that primitive's fake: a copy opens only through the same key, and removing trust deletes the server copy and the key.

### 5. Signing in

- [x] 5.1 Write `km_signin.dart`'s steps: config, methods, the Argon2id settings and salt before KE1, OPAQUE with the bounds, the Bitwarden hash once then enrolment, the `opaqueEnrolled` record that refuses the hash route afterwards, the second step, and registration with the Vaultwarden device identifier when there is one. Verify against the fake server for each behaviour under "Signing in", including a PBKDF2 cost of 1 and an Argon2 memory of 2 GiB stopping before anything is sent, and a fake that claims "not enrolled" after an OPAQUE sign-in getting no hash. (The server's app contract has since been built, with the Bitwarden-hash and enrolment routes and the read of the account's keys, `GET /kem/v1/account/keys` (the wrapped root key, bundle and sealed private keys, with no PRF wraps). Tests are written in `km_signin_test.dart` and run after merging.)
- [x] 5.2 Build the setup and sign-in sheets: address, email, ways in, password, second step, "Trust this phone", and the push line. Adapt `SignIn.dc.html` and `Unlock.dc.html` from the design canvas (https://claude.ai/artifact/4wvdwScsMsGu6NMSj6ptPo) to the phone's sheets. Add the copy to `en.json` and `fr.json`. Verify with widget tests for each way in, the "Require SSO" case, and `test/i18n/messages_test.dart`. (`KemlockSetup` in `kemlock_setup.dart` over `KmSetupFlow` in `kemlock_flow.dart`; the sync sheet offers "Kemlock Server" beside the other two. A security key is offered as a way in, not as a second step, which needs the server's challenge options the client doesn't read yet, so a second step the sheet answers is a code, authenticator or email. The device is named "Kemlock on Android" or "on iPhone", as no plugin reads the model, and the device key is tagged by vault. Not done: offering Vaultwarden when `/api/config` answers at a non-Kemlock address. Tests are in `kemlock_setup_test.dart`, run after merging.)
- [x] 5.3 Seal the session and account, rotate the refresh token, and handle the server ending the session for each reason. Verify against the fake: a refresh token used twice shows "ended for safety"; signing out from another device shows its message; entries stay in every case. (The host's backend is `KmHost` in `km_host.dart`, made by `makeKmHost` and run by the scheduler from `SyncHost`; "Turn off" signs out through it. The server's reasons for ending a session map to the sheet's words in `problemOf`, and a session the server ended is kept marked so every later run says so without asking. Tests are in `km_host_test.dart`, run after merging.)

### 6. SSO through the system browser

- [x] 6.1 Add `platform/browser_auth.dart` with `ASWebAuthenticationSession` on iOS and Custom Tabs on Android, plus the `kemlock://sso` activity. Use separate `feat(ios)` and `feat(android)` commits. List the file in `network_callers_test.dart`. Verify with a Dart test over a fake channel, and a Kotlin test that an intent with the wrong `state` is dropped. (code done; verify after merge: the Dart test over a fake channel is written, the Kotlin test of the redirect's `state` and the XCTest are written but not built. Android opens the system browser with the raw Custom Tabs intent extra rather than `androidx.browser`, which would be a new dependency. The sheet is cancelled from the sign-in sheet, since a Custom Tab closed with Back sends nothing back.)
- [x] 6.2 Add the phone-to-server PKCE and the finish step of design decision 9, then open the account by trust, approval or password. Verify against the fake: a code without the verifier, or with another device key, is refused; a cancel leaves the phone signed out. (The finish step is `kmSsoSignIn` in `km_sso.dart`; the account opens through `KmSignIn.openWithTrust` or the password, and by an approval once task 9.3 lands. The server's `sso/start`, `callback`, `finish` and `backchannel-logout` are the ones read from its code.)
- [x] 6.3 Enrol the keys of an account SSO made with none: `POST /kem/v1/account/keys/enrol`. When SSO answers `newAccount`, or `GET /kem/v1/account/keys` says the account has none (404: a first device that was closed before it enrolled; a key version 0 answer with no bundle is one the server never gives, and is refused as unreadable), this phone makes a fresh root key, the bundle, its signature and the sealed private keys at key version 1 (`_newKeys`), seals its trusted-device copy of the root key (`KmTrust.seal`, bound to the account, the device and key version 1, under the hardware's `protection`) and sends them in one request, then opens the account from what the server holds, with no further step. The copy is part of the enrolment, not the optional "Trust this phone", so the sheet doesn't trust the phone again. A 409 means another device enrolled first: nothing is overwritten, this phone's new hardware key is deleted, and the sign-in goes on as for an account with keys (this phone's copy, an approval). The hardware key is deleted only on the server's refusal: an answer lost to the network may follow a stored enrolment, and the copy is then the only way in, so it stays. A phone with no hardware key can't hold the copy and stops with `kemlock.signin.noDeviceKey`; other failures are the existing sign-in errors. Verify against the fake: a new account enrols and opens, an account found at sign-in with a 404 enrols, a key-version-0 answer is refused, a lost answer keeps the key, a 409 falls back without overwriting, and the copy written opens with the device key and gives the root that opens the sealed keys. (`KmSignIn.enrolKeys` and `KmAuthApi.enrolKeys`; the sheet calls it through `KmSetupFlow.enrolKeys` before trying the trusted-device copy. Adding a password to such an account later is not part of this. Tested in `km_enrol_test.dart`.)

### 7. Passkeys and security keys with PRF

- [x] 7.1 Sign in with a security key through `lib/security_key`'s CTAP, with the web-vault origin and WebAuthn's PRF salt mapping. Verify with the fake authenticator: the client data matches `vwKeyOrigin`'s rule, the salt is `SHA-256("WebAuthn PRF" || 0x00 || input)`, and the PRF output opens the fake's wrapped user key. (`kmPasskeySignIn` in `km_passkey.dart` and `KmKeyStep` in `kemlock_key_step.dart`; the key is asked through `HmacSecret.assertWithSecret`, the `hmac-secret` exchange of the vault unlock widened to take the server's name and client data hash. The server's passkey routes are `POST /auth/passkey/options`, with no email and no body (the credentials are discoverable, so the allow list is empty), and `/verify`, which takes the sealed challenge and the credential as a browser's `toJSON()` (with the user handle and none of the PRF output) and answers the tokens and the passkey's copy of the root key for the current key version. `GET /account/keys` has no `prfWraps`. A security key is asked with no allow list, through a discoverable option of `HmacSecret.assertWithSecret` and `getAssertion`. The client reads `GET /account/passkeys` and `PUT /account/passkeys/{id}/prf`, and stores no wrap after a sign-in, which the plan does not ask for. The fake authenticator is the existing `SoftKey`, which can hold a discoverable credential. Tests are in `km_passkey_test.dart`, run after merging.)
- [x] 7.2 Add Credential Manager passkeys with `prf` on Android 14 and later, offered only when the server's `assetlinks.json` names the app. Verify with a Kotlin test of the request JSON, and a Dart test that iOS never offers a platform passkey. (code done; verify on a device: Credential Manager is called through the platform API with the bundles `androidx.credentials` writes, so there is no new library and no Gradle dependency (`androidx.credentials` is already one), and the free build has it too. Dart builds the request JSON and reads the answer, and the Dart tests in `km_platform_passkey_test.dart` check the JSON and that iOS never offers it; `PlatformPasskey.requestProblem` refuses a request with no challenge, relying party or `prf` input before the picker shows, and the Kotlin test `PlatformPasskeyTest` checks it with the request Dart writes, the bundle the request travels in, and the support and error words. Offered only where the account has a passkey, the phone is on Android 14 or later and the server's `assetlinks.json` names the app.)

### 8. The sync run

- [x] 8.1 Move Vaultwarden's removal guard into `sync/removal_guard.dart` in a `refactor(sync)` commit. Verify that every existing Vaultwarden guard test passes unchanged. (Vaultwarden still exports RemovalChoice, removalWindow and lostLately, so its tests stay as they were.)
- [x] 8.2 Write `km_sync.dart`'s run of design decision 2: cache, delta pages, the unknown-kind pass-through, merge, diff, guard, batches, the 409 loop, tombstone clamp, and the cursor stored last. Verify against the fake for each behaviour under "Syncing", including a run killed after the delta and before the store. (Tombstones carry no time on the server, so a deletion is dated by when this phone first saw it. The host-side backend that opens the sealed session and account and calls KmScopeSync is task 5.3.)
- [x] 8.3 Map each list to its kind and each id through the legacy-id mapping (design decision 3). Only after task 1.2 has the server's confirmation of every kind name, write `mobile/test/fixtures/kemlock/items.json` once, holding each kind's plaintext JSON, with a README saying it is never regenerated. Verify that each kind round-trips byte for byte through the fake and the fixture, that `acc-1` travels as the server's legacy-id vector UUID and comes back as `acc-1`, and that an entry moved into a space pairs by its original id. (Done as far as the server has confirmed: items.json holds the kinds crypto.md lists that the app has a model for; key, key-otp and contact, and certificate, card and identity, get their own files once confirmed, as an existing fixture is never edited.)
- [x] 8.4 Check the manifest each run (design decision 5), keep the deleted-id record, and sign one manifest at the end of a run that wrote. Verify against the fake: a rolled-back, a missing and a resurrected item stop with `older`; an unlisted item is held and applied once a later manifest lists it; a run that wrote sends exactly one manifest, after its last batch.
- [x] 8.5 Sync a note's files as `KMA1` bytes, uploaded first and capped on download. Verify with `attachment_sync_test.dart`-style tests: a 3 MB photo arrives byte for byte; an oversized download stores nothing. (The server numbers files itself and needs the note's item first, so the note is written, the file uploaded, and the note written again naming the server's file id in its attachment's own keys, rather than the file going up before its item. Fetching runs at the end of the run; wiring it into the downloads list the sheets show is left to the sheet work.)
- [x] 8.6 Add the problems to `SyncProblem`, `problemOf` and `sync_messages.dart`, with `en.json` and `fr.json`. Verify with `sync_messages_test.dart`.
- [x] 8.7 Build the "on" sheet: account, server in use, last sync, Sync now, removals, push switch and Turn off. Verify with widget tests that Turn off signs out and keeps every entry. (The push switch stores the choice, on by default; it acts once the push relay's client exists, group 11. The server sign-out is the host's, through kemlockSignOutProvider, whose default signs out nowhere.)

### 9. Approvals and devices

- [x] 9.1 Write `km_approvals.dart`: read pending requests on open, nudge and sync; drop requests over 15 minutes; Approve through `ownerCheckProvider`, sealing to the one-time key; Deny. Verify against the fake: an approval sends a blob the fake opens with the request's key; Deny sends none. (`KmApprovals` in `km_approvals.dart`. The approval is shown and checked by the server's five words (`km_phrase.dart`, `crypto.md` "Device-approval phrase") in place of the 12 groups of digits of design 11. The server's list returns no one-time public key for a request, only its own `phrase`, so an approving phone can't compute the words or seal; the client is written to a `publicKey` member of each request and says so when it is missing. The sealed box's extra binding is empty, which `crypto.md` doesn't fix for this context. Tests are in `km_approvals_test.dart`, run after merging.)
- [x] 9.2 Add the approval sheet with the approval fingerprint in `FingerprintView` (design decision 11), and its warning when the digits differ. Verify with a widget test, and with the server's approval-fingerprint vectors once copied by `add-account-crypto`'s script. (The sheet shows the five words this phone computes, as 9.1 does, in place of `FingerprintView`'s digits, so the server's fingerprint vectors do not apply. `KemlockApprovalSheet` in `kemlock_approval.dart`; `KemlockApprovalsHost` reads the requests when the host starts and after each sync, and shows each new one once. Tests are in `kemlock_approval_test.dart`, run after merging.)
- [x] 9.3 Add this phone's own approval wait after SSO: polling every 2 seconds for up to 15 minutes, then opening the answer. Verify with a fake clock: an answer at 40 s opens the account; none in 15 minutes ends with the other ways offered. (`KmApprovalFlow` in `km_approvals.dart`, tested with a fake clock in `km_approvals_test.dart`: an answer at 40 s opens the account, and none in 15 minutes ends with the other ways offered. Run after merging.)
- [x] 9.4 Build the devices list, adapted from `Devices.dc.html`: each device's name, what it opens, and its last Kemlock API and Bitwarden API use; this phone marked; sign out one or all others; removing trust. Verify with widget tests: the Bitwarden extension shows "Kemlock API: never"; a phone registered with its Vaultwarden identifier is one row with both dates. (`KemlockDevicesSheet` in `kemlock_devices.dart`, opened from the on sheet. It shows each device's two uses and this phone marked, without a line for "what it opens", as the server's list gives only a name and a kind. Tests are in `kemlock_devices_test.dart`, run after merging.)

### 10. Failover

- [x] 10.1 Write `km_failover.dart`'s state machine with an injected clock. Verify with unit tests for each behaviour under "Failover": two failures, the 10-second timeout, a 409 not counting, and the 5-minute return reset by one miss. (`KmFailover` in `km_failover.dart`, with the injected clock; the first-byte timeout is a parameter of `send` (10 s by default). Tests are in `km_failover_test.dart`, run after merging.)
- [x] 10.2 Add the replica's device-key sign-in, and the checks on a new list and a promotion record. Verify against two fake servers: switching needs no prompt; a list of strangers and a record from an unknown key are refused. (`kmReplicaSignIn` and `acceptServerList` in `km_failover.dart`. The server's shapes are used: the replica signs in at `/auth/device-key/challenge` and `/verify`; the list is `vaults[]` of `GET /config?vault=user:<uuid>` (`KmApi.config`), and the promotion record is the CBOR envelope of `docs/federation.md`, checked as `sig1("federation-promotion", body)` by the new home's pinned identity key, for this vault, epoch and list (`KmPromotion`). After each run that goes through, and at the health check of the home while away, `KmHost` reads `/config?vault=user:<account>` and takes the account's vault through `acceptServerList`; an accepted list is the failover's from the next run and goes to the settings through `onList`, and a refused one leaves the old list (`km_host_list_test.dart`). A refusal is not shown yet: the `kemlock.failover.list.*` messages are unused. `KmHost` runs each sync through `KmFailover.send`, with `KmApi.firstByte` giving the 10-second rule per request: it signs in to a replica with the device key (the replica's session is kept in memory only), checks the home once a minute while away, and reports where it is through `kemlockAwayProvider`. Tests are in `km_failover_test.dart`, `km_host_failover_test.dart` and `km_first_byte_test.dart`, run after merging.)
- [x] 10.3 Refuse home-only changes on a replica, and show the home away on the sheet, adapted from `Failover.dc.html`. Verify with widget tests for "offline since" and "using". (The sheet shows the home away and the server in use from `kemlockAwayProvider`; `KmHost.requireHome` refuses a home-only change with `KmHomeAway`. The phone has no master-password or two-step change yet, so nothing else calls it. Tests are in `kemlock_away_test.dart` and `km_host_failover_test.dart`, run after merging.)

### 11. Nudges

- [x] 11.1 Add the `PushTokens` port to `kemlock_ports`. The store build gets APNs through a Swift channel; Android has no push service (the owner's decision of 2026-11-22: no Firebase in the app, so the live socket while the app is open and the sync schedule, with UnifiedPush maybe later). `parts_free` gets none. Use separate `feat(ios)`, `feat(android)` and `chore(deps)` commits. Verify with Dart tests over fake ports, and, in the single build-and-test pass after merging, that neither APK's class scan of `add-fdroid-release` finds a Firebase class. (code done; verify on a device: the port, `NoPushTokens`, `ChannelPushTokens` and its tests were done earlier. `PushChannel.swift` answers `token` (permission for alerts, then APNs) and gives `nudge` the type only; the entitlement is `aps-environment` `development`, which the distribution profile makes production, with the `remote-notification` background mode. The Android half, an FCM channel in `parts_store/android` with `com.google.firebase:firebase-messaging`, was built and then replaced by the owner's decision of 2026-11-22: Kemlock has no Firebase. The module, its checksums in `verification-metadata.xml` and its tests were removed, and on Android `ChannelPushTokens.available` is false and `token()` is null, as `NoPushTokens` does in the free build, so the app relies on the live socket (task 11.3) and the schedule; UnifiedPush through this same port is a later option (decision 3 (b)). The README's "Push on Android" says so. The token and nudges themselves are tried on an iPhone in task 13.4. The token is not in the device body (the server refuses unknown device fields): `KmHost` registers it at `POST /kem/v1/devices/push-token` after each run that goes through, again when it or the server in use changes, and the sheet's switch off calls `DELETE`; a failure is let go and retried at the next run (`km_push_token_test.dart`). The port has no token-refresh event, so a refreshed token waits for the next run.)
- [x] 11.2 Route nudges: `sync` runs the scheduler only while open; `approval` raises the fixed-text notification that opens the unlock, then the request. Verify with tests: a nudge while locked fetches nothing; tapping the notification lands on the request after unlock. (code done; verify on a device: `KemlockApprovalsHost` routes a `sync` nudge to the scheduler only while the vault is open, Kemlock Server sync is on and the push switch is on, and an `approval` nudge to a read of the requests, which shows the sheet; the host registers the push token with the server. An `approval` nudge at a locked vault raises `ApprovalNotice` (in `platform/reminders.dart`, over `flutter_local_notifications`, one channel `approval_requests` and one id): fixed words, no device and no account, and nothing fetched. On iOS, with no engine running, the relay's alert push is the notice; on Android nothing raises it until the app is next open. Tapping it launches the app, which shows the unlock as any launch does; the host then starts, reads the requests and shows the sheet, and the notice is taken back. A tap while the app runs with the vault open reads the requests at once. The phone is asked for permission to show it once, after it gives a push token (iOS; Android gives none now, and so is not asked). Tests are in `kemlock_notice_test.dart`, run after merging, including the tap, then the unlock, then the request; the tap through a real unlock is tried on a phone in task 13.4. The relay's alert push must carry `type` at the top level of the payload and `content-available`: that shape is assumed.)
- [x] 11.3 Add the `/kem/v1/live` socket in `platform/network.dart` behind the gate: DPoP on upgrade, open only in front and unlocked, back-off from 2 s to 5 minutes. Verify with a fake socket server: a `sync` frame runs the scheduler; hiding the app closes it; offline mode refuses it. (`connectLiveSocket` in `platform/network.dart` is the one place the app makes a WebSocket, dart:io's own, with no new package: it passes the gate, takes only `wss` (`ws` on loopback in tests), trusts the system or the server's pinned certificate, and pings every 30 seconds to find a dead connection. `KmLive` in `km_live.dart` keeps one socket open, backing off 2 s, 4 s, … to 5 minutes (a socket that stayed open a minute starts it over), and reads a frame, a JSON object with a `type` or the bare type, `sync` or `approval`. `KmHost.liveUpgrade` builds each upgrade: the access token (renewed first) and a fresh DPoP proof for the `GET`. `KemlockLiveHost` in `lib/app` opens it only in front, with the vault unlocked, Kemlock Server sync on and offline mode off, closes it otherwise, and turns a `sync` frame into `requestSync` and an `approval` frame into a read of the requests. The five-minute schedule stays as the floor. Assumed, as the server's code has no `/live` yet: the frame's shape; and that the upgrade needs no DPoP nonce, since dart:io's WebSocket doesn't hand back the refusal's headers, so a server that asks for one fails the first attempt and the back-off tries again. Tests are in `km_live_test.dart`, `kemlock_live_test.dart` and `live_socket_test.dart`, run after merging.)

### 12. Offline mode and the Vaultwarden offer

- [x] 12.1 Check that every Kemlock request, the browser sheet, the socket and push registration pass `NetworkGate`. Verify with offline-mode tests for each, and that the sheet shows sync paused. (Checked by reading: every Kemlock request goes through the gated, pinning client (`kemlockClientFactoryProvider`); the SSO sheet through `ChannelBrowserAuth`'s gate check; the live socket through `connectLiveSocket`, which `KemlockLiveHost` does not even try while offline mode is on; and the host, approvals and devices are reset to none while it is on. One gap found: the push token was asked of FCM or APNs with no gate, a request to Google's or Apple's servers; it now isn't asked while offline mode is on. The device registration that carries the token is part of the sign-in, which passes the gate. Tests: `km_gate_test.dart` (requests), `kemlock_offline_test.dart` (the browser sheet and the socket), `kemlock_live_test.dart` (the socket closes), `kemlock_setup_test.dart` and `kemlock_sheet_test.dart` (the sheets say sync is paused), run after merging. The token's own gate has no test: the setup sheet offers no way to connect while offline, so only the sign-in can reach it.)
- [x] 12.2 Read `/api/config` at a Vaultwarden sync and show the move offer at most once a day. Move hands off to `move-off-vaultwarden-sync`'s sheet. Verify with `fake_vaultwarden.dart` serving the flag: the offer shows and Not now hides it until a later day. (The flag is the `kemlock` member of `/api/config`, read from the server's code: `{"api": "https://host/kem/v1", "versions": ["v1"]}`; `KemlockOffer.fromConfig` in `vw_kemlock_offer.dart` wants `v1` among the versions and an https address. It is read when the Vaultwarden "on" sheet opens, not inside the sync run, so the sync's own requests stay as they were, and it is when the person can act; the sheet shows "This server also speaks Kemlock's own API" with Move and Not now. The day it was shown, `kemlockOfferDay` (`yyyy-mm-dd`, the phone's calendar day), is kept in the Vaultwarden target, written only once there is one, so older settings keep their bytes. The offer is read and shown only on a day other than that, so Not now keeps it hidden until a later day, and a server with no Kemlock API costs one small request each time the sheet opens and saves nothing. Offline mode reads nothing. The seam for `move-off-vaultwarden-sync`: `moveOffVaultwardenProvider` in `vw_kemlock_offer.dart` is a `MoveOffVaultwardenSheet`, a function of the sheet's context, the Vaultwarden target and the offer; that plan overrides it with its sheet. Its default only says, in a toast, that moving isn't in this version. Tests are in `vaultwarden_move_offer_test.dart`, run after merging.)

### 13. The real crypto, the server's vectors, and end to end

- [x] 13.1 Replace the fake of task 1.4 with `add-account-crypto`'s implementation. Verify that every test of groups 3 to 12 still passes and that the shared vectors in `mobile/test/fixtures/server/` pass through this plan's code. (Production has used `AccountItemCrypto` since task 1.4; what was left was the tests. `real_km_crypto.dart` has `RealKmCrypto`, the production crypto over a `KmTestAccount`'s keys, and `useRealCrypto` makes the kit's phones use it, so `km_sync_real_test.dart` and `km_manifest_real_test.dart` run every test of `km_sync_test.dart` and `km_manifest_test.dart` again on the real `kem1` and `sig1` (ML-DSA-65 with Ed25519), with a long timeout as `sig1` is slow in pure Dart. The other suites still use the fake, which is quick, and any can be run on the real crypto the same way. `km_server_vectors_test.dart` opens the server's `kem1.json` envelopes through `AccountItemCrypto` (and refuses a changed revision or kind), verifies the signed `manifest.json` cases (and refuses a flipped signature, another key and another owner), and checks `kmItemId` against the item cases of `legacy-ids.json`. Nothing in `mobile/test/fixtures/server` was edited. Not run here: a test that expects the fake's own errors may differ on the real crypto, and the single pass will say which.)
- [x] 13.2 Copy the server's OpenAPI JSON into `mobile/test/fixtures/server/openapi.json` with its commit, and add the contract test of design decision 15. Verify in the pass after merging that it passes, and that it fails on a renamed field in a test-local copy. (Code done; the run is pending the main session's pass, which is the verification. The JSON is copied at server 2f66a04 (`SOURCE.json`). `openapi_checker.dart` is a small checker of the schema subset the document uses (`$ref`, `type` and its lists for null, `properties`, `required`, `additionalProperties`, `items`, `enum`, `allOf`, `oneOf`, `anyOf`, `minimum`, the `uuid` and `int32` formats), which `FakeKemlockServer.client` and `FakeSpaceServer.client` report each exchange to when a test sets `OpenApiChecker.active` (the sign-in, dedup and Sends fakes extend the first): path, query and header parameters, the DPoP headers, the request body, and the answer's status, content type and body. `openapi_contract_test.dart` runs the client's flows through the fakes (sign-in, second step, Bitwarden enrolment, SSO, passkeys, approvals, devices, account keys and their enrolment, sync with a file and the manifest, the key copy, the duplicate cleaner, Sends, the space routes) and expects no violation beyond the gaps of the document it lists; it renames `writes` of the batch and `cursor` of the delta in a copy of the spec and expects the checker to report them; and it lists each route the client code names, with where it comes from, and checks each is in the document with its method and that no route string of the code is missing from the list. The document has no examples, so the fake can't answer with them: its answers are checked against the schemas instead. Found: the client asked `/spaces/{id}/pending` where the server's route is `/spaces/{id}/chain/pending` (fixed with its fake and a test); the fakes left out members the document requires (`vaults` of `/config`, the KDF and wrap of `/account/keys`, the space DTOs, the manifest's `storedAt`, `siblings` of a space's delta) and answered 200 where it says 204 (fixed). What the document lacks or gets wrong is in `mobile/test/fixtures/kemlock/README.md` for the server session; the client calls no route it lacks.)
- [ ] 13.3 Add `mobile/test/kemlock_server/`, run only when `KEMLOCK_URL` is set, like `test/vaultwarden_server/`: sign in, sync two simulated devices, approve, and fail over between two servers. Verify by one run against the server's development build, made by the main session after merging, and record it here. (code done; verify by a run: `server_kit.dart` says how to run it, with `KEMLOCK_URL`, `KEMLOCK_EMAIL` and `KEMLOCK_PASSWORD` of an account made beforehand on the development build (the phone has no registration) and, for a pin, `KEMLOCK_PIN`. `sync_test.dart` signs in with the master password, syncs two simulated phones both ways with an edit and a deletion, and checks that a signed-out phone is told and keeps its entries; `approval_failover_test.dart` approves and denies a new phone's request with the same five words on both, and fails over from a home made to fail to the replica by the device key (`KEMLOCK_REPLICA_URL` and `KEMLOCK_REPLICA_PIN` for a second server, else the same server by its replica route). Not run here, so the result is for the main session to record under this task.)
- [ ] 13.4 On an iPhone and an Android phone, check: password sign-in, SSO with approval, a security key over NFC, Android Credential Manager, push approvals, the live socket, and a failover with the home stopped. Record what passed in this plan; where no phone is at hand, leave a "Not done:" note saying what was checked instead. (Not done: no phone was at hand, and the device keys, the push token and its nudges, the notification's tap through the unlock, the live socket, the SSO sheets, a security key over NFC and Credential Manager are all native code that only a device runs. Checked instead: the Dart halves against fakes, and the Kotlin and Swift of each channel's pure parts by unit tests written for the single pass. To check on a phone: 4.1's keys, 6.1's sheets, 7.2's Credential Manager, 11.1's token and nudges, 11.2's notification and tap, and 11.3's socket.)
- [x] 13.5 Describe Kemlock Server sync in the README's sync section: what the server and the push relay see, the device key, and failover. Verify that the README names each stored key of design decision 7. (The README's "How sync works" has a "Kemlock Server sync" subsection: signing in, the device key, what the server and the push relay see, approvals, failover, and what is kept on the phone, which names `backmycodes_kemlock_session`, `backmycodes_kemlock_account` and `backmycodes_kemlock_cache` and the `kemlock` member of the sync settings. The build section's "Push on Android" says that neither build has Firebase and how a nudge reaches an Android phone.)

## Agreed with the server

The kemlock-server session must provide, in its OpenAPI 3.1 spec and shared
vectors:

- `GET /kem/v1/config`: the server's identity key, the vault's server list
  with each server's role and address, the home epoch, the promotion record
  when one exists, and the ways in it supports.
- The `/api/config` flag that `/kem/v1` exists, and its name (served: the `kemlock` member, `{api, versions}`).
- A route listing an email's ways in, SSO's provider name, and whether
  "Require SSO" applies, the same for unknown emails.
- OPAQUE start and finish (RFC 9807), OPAQUE registration, and the route that
  takes a Compatible account's Bitwarden hash once.
- The second-step challenge and answer for authenticator codes, email codes
  and security keys, with the WebAuthn origin the server checks.
- Passkey options and verify with the `prf` extension, and
  `/.well-known/assetlinks.json` listing Kemlock's Play and F-Droid
  certificates.
- SSO start and finish with phone-to-server PKCE and the `kemlock://sso`
  redirect.
- DPoP (RFC 9449) with ES256 on every token, `DPoP-Nonce`, rotating refresh
  tokens, revoke on reuse, and a reason when a session ends.
- Device registration that takes the device key's JWK, a name, a push token,
  and the vault's Vaultwarden device identifier, matched to the Bitwarden
  API's device of that identifier.
- The device list, with each device's last use of the Kemlock API and of the
  Bitwarden API.
- Device-key challenge and sign-in on a replica.
- The trusted-device copy: store, fetch after SSO, delete.
- The Argon2id settings and salt before OPAQUE's KE1, from a prelogin-style
  route, with the same shape for unknown emails (`crypto.md` "Master key").
- `GET /kem/v1/sync?since=` with an opaque cursor, paging, and tombstones
  kept 180 days. Item ids are UUIDs, with older ids mapped on the phone by
  `crypto.md` "Legacy ids"; no string ids are needed.
- `POST /kem/v1/items:batch` of up to 500, with `If-Match`, create-if-absent,
  a safe resend, and a 409 naming each stale item.
- The manifest's route: one upload after a run's last batch.
- `/kem/v1/items/{id}/files`: streamed or pre-signed, with each stored file's
  size and SHA-256.
- Approvals: list, answer, deny, and a 15-minute expiry.
- `/kem/v1/live` with DPoP on the upgrade, and push relay nudges of type
  `sync` and `approval` with no other payload.
- The kind names marked *(not in `crypto.md` yet)* in design decision 3 (`key`, `key-otp`,
  `contact`), and the approval fingerprint's derivation, both added to
  `crypto.md` and its vectors.

## Dependencies

- `docs/plans/add-account-crypto.md` comes first. It provides OPAQUE, the
  user key and its wraps, item sealing, legacy ids, the manifest rule, the
  sealed box, the trusted-device primitive, and fingerprints with the
  approval fingerprint. Groups 3 to 12 use a fake of it; group 13 needs it
  done.
- `docs/plans/add-cards-identities-and-websites.md` adds the `card` and
  `identity` kinds and the `uris` key. This plan carries them as items. It
  doesn't wait for that plan: kinds it doesn't know pass through.
- `docs/plans/move-off-vaultwarden-sync.md` builds on this plan's sign-in,
  batch writer, kind list, settings invariant, device identifier and
  per-device API use. The offer of task 12.2 hands off to it.
- `docs/plans/add-server-spaces.md` adds space-owned scopes on this engine,
  with its client, tokens and cursor.
- `docs/plans/add-duplicate-cleaner.md` adds `tags` and `tagVersion` to this
  plan's item writes, and its server switch to this backend's settings.
- `docs/plans/add-credential-exchange.md` imports into the vault. With
  Kemlock Server on, imported items reach the server through this plan's
  next run.
- From the history before 5ba88b42: `add-offline-mode` (the gate),
  `add-cloud-drive-sync` (sync on every backend), `add-browser-extension` (the
  core move), `add-fdroid-release` (the free build), `add-passwords` (logins
  in sync) and `add-vaultwarden-security-key` (the CTAP path and origin).
