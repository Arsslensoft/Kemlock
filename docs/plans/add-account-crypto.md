# Account crypto for Kemlock Server

This plan adds the Dart primitives a Kemlock Server account needs:
- the root and user keys and their wraps;
- the `kx1` exchange key, the `sig1` signing key and the sealed box;
- the `kem1` item envelope;
- a signed manifest that shows rollback;
- OPAQUE sign-in.

Every byte is the server's contract, `docs/crypto.md` in `../kemlock-server` (branch
`build/vertical-slice`, 96f50a0, with "Legacy ids" from 70560f2). This plan cites that file section
by section and adds only the Dart side. The flows that use these primitives (sign-in, sync,
spaces, the duplicate cleaner) belong to the plans named under Dependencies.

## Why

Kemlock Server stores only ciphertext and wrapped keys. Every key that opens data is made and
unwrapped on a device. The design is "Kemlock Server: design and architecture",
https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y. Before the app can sign in to the Kemlock API,
sync items there or share a space, it needs that design's key hierarchy in Dart. The owner settled
the primitives in the design's Decisions table on 21 November 2026: ML-KEM-1024 + X25519 for
accounts, spaces, collections and servers; the user key wrapped under both the Argon2id master key
and OPAQUE's export key on Kemlock-only accounts; and each item bound to its id, revision, kind and
owner, plus a signed manifest that shows rollback. The server session then fixed the bytes in
`crypto.md`.

The app already has:
- ML-KEM-1024 (`mobile/lib/crypto/ml_kem.dart`, ported from `@noble/post-quantum`);
- ML-DSA-65 (`ml_dsa.dart`, used for RFC 9980's OpenPGP composite);
- AES-256-GCM (`aes_gcm.dart`), HKDF-SHA256 (`hkdf.dart`) and SHA-3 (`keccak.dart`);
- Argon2id (`DartArgon2id` through `bitwarden.dart`);
- X25519 and Ed25519 through `package:cryptography` (`keys/algorithms.dart`).

It has no account keys, no item envelope, no manifest and no OPAQUE.

The app's licence can't take AGPL or GPL code, so the server's `kemlock-crypto` can't be linked.
Everything here is our own Dart or a permissively licensed library, held to the RFCs' vectors now
and to the server's CC0 `test-vectors/` when they are published.

## What changes

- **Account keys**, as `crypto.md` "Account keys" defines them:
  - a 64-byte root, which on a Compatible account is the Bitwarden user key `bwOpenUserKey`
    already opens;
  - the Kemlock user key `HKDF(root, "kemlock/v1/user")`;
  - its labelled children `item-wrap`, `private-keys` and `manifest`.
- **The master key**: Argon2id over the NFC password, with the settings and salt the server
  returns before sign-in ("Master key").
- **The password wrap of the root** under `HKDF(master key ‖ export key,
  "kemlock/v1/password-wrap")` ("The password wrap of the root key").
- **`kx1`**: the ML-KEM-1024 + X25519 key pair from its 96-byte private key, the X-Wing-style
  combiner, and the **sealed box** with its five contexts ("`kx1`", "Sealed box").
- **`sig1`**: ML-DSA-65 + Ed25519 from a 64-byte private key, with signatures over
  `"kemlock/v1/sig1" ‖ lp(context) ‖ lp(message)` ("`sig1`").
- **The public-key bundle and its fingerprint**: SHA-512 over the bundle, shown as 12 groups of 5
  digits and as a QR code of the 64 bytes ("Public-key bundle and fingerprint"). Every plan that
  shows a fingerprint, spaces and device approval included, uses this one.
- **`kem1`**: per-item keys, the item AAD, the item-key wrap and the wire JSON, with **revisions
  assigned by the client** ("`kem1`").
- **Legacy ids**: the UUIDv8 mapping of item and space ids that aren't UUIDs ("Legacy ids"),
  provided here as functions for the sync, move and spaces plans.
- **The signed manifest** of `crypto.md` "Signed manifest", plus the rule that every other plan
  follows for when it is signed and how a device compares it (design 6).
- **OPAQUE (`opaque1`) on the client**: registration, sign-in and the export key, in RFC 9807's
  test vector 1 configuration with the context `"kemlock/v1/opaque"`.
- **The other wraps of the root**: a passkey's PRF output, a trusted-device key that stays in the
  Secure Enclave or Android Keystore, and the device-approval seal. This plan owns the primitives;
  the sync plan owns the flows.
- **Vectors**: RFC 9496, 9497 and 9807, the X-Wing draft's, and FIPS 203 and 204's from the start;
  the server's `test-vectors/` once published, copied to `mobile/test/fixtures/server/` with
  `SHA256SUMS`. No vectors of our own making stand in for the server's.

Out of scope:

- HTTP, DPoP, tokens, discovery, the sign-in and approval screens, sync, and where the account's
  keys are kept on the phone. Those are in `docs/plans/add-kemlock-server-sync.md`, which calls
  this plan's functions.
- Space and collection keys, the member chain and member confirmation
  (`docs/plans/add-server-spaces.md`). That plan uses this one's sealed box, `sig1` and
  fingerprint.
- Duplicate tags (`docs/plans/add-duplicate-cleaner.md`). Their key and input follow `crypto.md`
  "Duplicate tags", and that plan implements them.
- Rotating a user key, emergency access and account recovery. Their sealed-box contexts exist in
  `crypto.md`, and a later plan adds the flows.
- Any change to the vault's own ML-KEM key pair, its sealed values (`vault/sealed_value.dart`), or
  any released format. The vault, exports, QR transfers, sync files, invites, Recovery Kit pieces
  and Vaultwarden items stay byte for byte.
- Gating: none. This plan adds primitives only, and every feature is free.

Settled by `crypto.md`, and no longer questions for the owner:
- the OPAQUE suite, ristretto255-SHA512 with HKDF, HMAC and SHA-512;
- Argon2id run once, as OPAQUE's password input, with the Identity KSF;
- Argon2id at 64 MiB, 3 passes and 4 lanes for new accounts;
- revisions assigned by the client;
- plain OPAQUE-3DH, not `opaque-ke`'s post-quantum handshake;
- the 60-digit fingerprint.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

### 1. Which OPAQUE implementation?

No Dart OPAQUE package exists: searches of pub.dev for "opaque", "OPAQUE PAKE" and "voprf" on
22 November 2026 found none. The server uses `opaque-ke` 4. Its `opaque1` suite is ristretto255.

| Option | Licence | Maintained | Audited | Phones and F-Droid | Browser extension (dart2wasm) | Work to match the server |
|---|---|---|---|---|---|---|
| **A. Our own Dart OPAQUE-3DH over ristretto255**, ported from `@noble/curves` (ristretto255, RFC 9497 `oprf.ts`) | Ours; noble is MIT | We maintain it; noble last pushed September 2026 | Trail of Bits audited noble-curves 2.3.0 in August 2026, all of it; our port is not audited | Pure Dart: no native code and nothing new for the reproducible build | Runs as is | RFC 9496, 9497 and 9807 vectors, then the server's `opaque.json`; about the size of the ML-KEM port |
| B. Our own Dart OPAQUE-3DH over P-256, using pointycastle (already locked) | Ours; pointycastle is MIT | As A | No audited Dart P-256 hash-to-curve | As A | As A | Doesn't match `opaque1`, which is ristretto255; it would need the server to change suite |
| C. `opaque-ke` through `flutter_rust_bridge` | Apache-2.0 or MIT; flutter_rust_bridge is MIT | Active: 5.0.0-pre.0 on 13 November 2026 | NCC Group in June 2021, on v0.5; 4.x and 5.x not re-audited | Rust toolchains for 4 Android ABIs and an iOS xcframework; a Rust build made reproducible for F-Droid; a native library added to the free build's allow-list (`add-fdroid-release`, decision 9) | No: needs a separate wasm build with JS interop | None: the server's library |
| D. `@serenity-kit/opaque` (wraps `opaque-ke` 4.0) | MIT | Active, October 2026 | Inherits C's | No Dart binding, so for phones it is C again | Usable through JS interop | None |
| E. `libopaque` (C, libsodium) | LGPL-3.0 | Last push June 2025 | No | Static linking on iOS conflicts with the LGPL's relinking terms | Its JS build | A different code base from the server's |
| F. pub.dev `ristretto255` (justkawal) | MIT | 1.0.2, November 2023, 1 star | No | Pure Dart | Yes | A group only: no OPRF and no OPAQUE |

Sources, all opened on 22 November 2026:
- [opaque-ke](https://github.com/facebook/opaque-ke) (README, Cargo.toml, releases);
- [@serenity-kit/opaque](https://github.com/serenity-kit/opaque);
- [libopaque](https://github.com/stef/libopaque);
- [noble-curves](https://github.com/paulmillr/noble-curves) (README "Security", `src/abstract/oprf.ts`);
- [RFC 9807](https://www.rfc-editor.org/rfc/rfc9807.txt), section 7 and appendix C;
- [ristretto255 on pub.dev](https://pub.dev/packages/ristretto255).

**Recommendation: A.** It is the suite `opaque1` fixed, and RFC 9807's vector 1 tests it directly.
It follows the repo's preference for Dart algorithms, as `add-fdroid-release` applied to the QR
decoder, and it ports the same audited family the ML-KEM port came from. It adds no native code to
the F-Droid build and runs in the browser extension's dart2wasm core. The cost is our own
implementation, held to three RFCs' vectors and to the server's `opaque.json`.

**The tasks assume A.** Group 6 lists what changes if the owner picks C.

## Design

### 1. Where the code lives

New files go in two folders, and neither imports Flutter:
- `mobile/lib/crypto/account/`: the root and children, the master key, `kx1`, the sealed box,
  `sig1`, the bundle and fingerprint, `kem1`, legacy ids, the manifest and the wraps;
- `mobile/lib/crypto/opaque/`: ristretto255, the OPRF and the OPAQUE client.

So both move into `packages/kemlock_core` with the rest of `lib/crypto` (`add-browser-extension`,
task 2.3), and run under dart2wasm (its task 2.6).

Argon2id runs through that change's key-derivation runner (its task 2.2), not a bare `Isolate.run`,
which throws under dart2wasm. If the runner hasn't landed, the call sits behind a one-function seam
that the runner later replaces.

*Alternative:* a new package now. Rejected, because it would race `add-browser-extension`'s move.

### 2. Encoding

`crypto.md` "Conventions" applies throughout:
- `‖` concatenation, and big-endian `u8`, `u16be`, `u32be`, `u64be`;
- `lp(x) = u32be(len) ‖ x` for every variable field inside a hashed or authenticated input;
- UUIDs as 16 raw bytes in RFC 9562 order inside binary inputs, and hyphenated lower case in
  JSON;
- owners as 17 bytes, `u8(type) ‖ uuid`, with `0x01` for a user and `0x02` for a space;
- binary in JSON as base64url without padding. The decoder refuses padding, the standard alphabet
  and whitespace.

One module, `crypto/account/encoding.dart`, holds all of this. Its strict readers check every
length before decrypting and refuse unknown versions, unknown fields and trailing bytes. The
app's existing formats keep their own padded base64; only Kemlock API values use base64url.

### 3. Keys from the root

- **Root.** On a Compatible account, the 64 bytes `bwOpenUserKey` returns. On a Kemlock-only
  account, 64 random bytes made at registration.
- **Children.** The user key and its children are as `crypto.md` "Account keys" lists, nothing
  more:
  - `item-wrap` wraps the owner's item keys;
  - `private-keys` seals the account's `kx1` and `sig1` private keys;
  - `manifest` is reserved.
  A space key, which the spaces plan opens from its sealed box, has the same children.

Collection keys aren't in `crypto.md` yet. The spaces plan proposes that a collection key takes a
space key's place as the parent of `item-wrap` for that collection's items. It is listed under
"Agreed with the server".

### 4. The master key and its salt

- **Settings and salt.** `crypto.md` "Master key": `m = 65536` KiB, `t = 3`, `p = 4`, and a 16-byte
  salt the server keeps. The server returns them *before* OPAQUE's first message, from a
  prelogin-style call. The sync plan names the route.
- **Unknown emails.** For an email it doesn't know, the server answers with settings and a salt
  derived from the email under a server secret, so the call doesn't reveal which accounts exist.
- **Input.** The password is the UTF-8 of its NFC form, and the output is 32 bytes.
- **Use.** The same master key is OPAQUE's password input and half of the password wrap's
  key-derivation input, so a sign-in runs Argon2id once.
- **Moving accounts.** When a Compatible account becomes Kemlock-only, the root stays and only its
  wrap changes.

### 5. `kx1`, the sealed box, `sig1`, bundle and fingerprint

These follow `crypto.md` byte for byte. On the Dart side:

- **ML-KEM from a seed.** The 96-byte `kx1` private key is `d ‖ z ‖ X25519 private key`.
  `ml_kem.dart` gains a `keyGenInternal(d, z)` entry if it lacks one (FIPS 203 Algorithm 16), so
  the key pair expands as the server expands it.
- **The combiner.** It is `SHA3-256("kemlock/v1/kx1" ‖ ss_m ‖ ss_x ‖ ct_x ‖ pk_x)`, on
  `keccak.dart`. An all-zero `ss_x` is refused, and decapsulation never says which half failed.
- **The sealed box.** It is `u8(1) ‖ ct (1600) ‖ AES-256-GCM(...)`, under a key from
  `HKDF(ss, "kemlock/v1/seal" ‖ lp(context))` and the additional data
  `lp(context) ‖ lp(aad)`. Callers pick one of the five contexts and pass their own `aad`, such as
  the recipient's account id.
- **`sig1`.** It signs with ML-DSA-65 under an empty context, over
  `"kemlock/v1/sig1" ‖ lp(context) ‖ lp(message)`, and appends the Ed25519 signature. Verification
  needs both halves. `ml_dsa.dart` is checked for a pure ML-DSA.Sign with an empty context and a
  seed `ξ` entry, and gains them if missing. Signing stays hedged, and vectors pass fixed
  randomness.
- **The bundle.** `"kemlock/v1/bundle" ‖ account id ‖ u32be(key version) ‖ kx1 pk ‖ sig1 pk`,
  signed under the context `"bundle"`.
- **The fingerprint.** `SHA-512("kemlock/v1/fingerprint" ‖ bundle)`:
  - shown as 12 groups of 5 digits, where group `i` is `u40be(fp[5i .. 5i+5]) mod 100000`, with
    leading zeros;
  - shown as a QR code of the 64 bytes, scanned and compared in constant time;
  - one widget, `FingerprintView`, used by the spaces and sync plans.
- **Device approval.** A new device's one-time `kx1` key has no bundle. Its fingerprint, shown on
  both phones in the same 12-group form, is proposed as
  `SHA-512("kemlock/v1/approval-fingerprint" ‖ request id (16) ‖ kx1 pk)`. This isn't in
  `crypto.md` yet, so it is listed under "Agreed with the server". There is no short form.

### 6. `kem1`, legacy ids and the manifest

**The envelope**, from `crypto.md` "`kem1`":
- each item has its own random 32-byte key;
- the item's additional data is `"kemlock/v1/item" ‖ id ‖ u64be(revision) ‖ lp(kind) ‖ owner`;
- the item key is wrapped under the owner's `item-wrap` child, with the additional data
  `"kemlock/v1/item-key" ‖ id ‖ owner ‖ u32be(key version)`;
- the wire JSON is the one `crypto.md` shows;
- a tombstone is `deleted: true` with no ciphertext.

The client assigns revisions: a new item is revision 1, and each write is the previous revision
plus 1, sent with `If-Match`. An edit may keep the item key. Plaintext is capped at 2 MiB, the
server's JSON limit.

**Kinds.** `crypto.md` names `login`, `otp`, `note`, `backup-codes`, `passkey`, `pgp-key`,
`ssh-key`, `certificate`, `card` and `identity`, all of the alphabet `[a-z0-9_-]`. The sync plan
maps each app entry to one of them. `contact` isn't in `crypto.md` yet, so it is listed under
"Agreed with the server".

**Legacy ids**, from `crypto.md` "Legacy ids":
- a space id is
  `uuidv8(SHA-256("kemlock/v1/legacy-id" ‖ lp("space") ‖ lp(old space id)))`;
- an item id is
  `uuidv8(SHA-256("kemlock/v1/legacy-id" ‖ lp("item") ‖ owner (17) ‖ lp(old item id)))`, where a
  space owner uses its mapped space UUID;
- `uuidv8` takes the first 16 bytes and sets the version and variant bits;
- an id that already is a UUID is never mapped;
- old ids are their stored UTF-8 bytes.

`crypto/account/legacy_ids.dart` provides both functions. The original id stays in the item JSON,
and the merge pairs copies by it. Because the owner is an input, an item with an older id gets a
new UUID when it moves between owners. The server then sees a delete and a create, and the
device pairs the two by the original id.

**The manifest bytes** are `crypto.md` "Signed manifest". Entries are sorted by item id, each with
`SHA-256(ciphertext)`, or 32 zero bytes for a tombstone. The writer signs with `sig1` under the
context `"manifest"`, and the counter only rises.

**When a manifest is signed.** Every plan that writes items follows one rule: a device signs one
manifest per owner it wrote to, at the end of a run.
- The sync plan does it at the end of each sync run that wrote anything.
- The move plan does it once after the move's last batch, before its check.
- The spaces plan does it after a key replacement's last re-wrap batch.

**Who may sign.** A user's manifest is signed by that account's `sig1` key, pinned on the device at
sign-in or approval. A space's manifest is signed by a member whose role the space chain allows to
write. That chain is defined in the spaces plan.

**What a device keeps,** per owner, in the sealed vault store (the sync plan keeps it there):
- the highest verified counter, its hash and its entries;
- every item id it has seen deleted, with that revision, for as long as tombstones are kept (180
  days).

**How a sync is compared.** One pure function sorts each item into one of six results:
- **Expected:** the item matches the latest manifest.
- **Rolled back:** a lower counter means the whole answer is rolled back; a lower revision means
  that one item is.
- **Missing:** the item is listed and not deleted, but absent with no tombstone. Nothing is
  deleted on the device.
- **Unlisted, flagged:** the item is absent from the latest signed manifest, or newer than its
  entry. It is held, not applied, until a manifest from a permitted signer lists it, and the
  device that wrote it signs one at the end of its run. "Not listed means accepted" is not a rule
  here: a removed space member, before keys are replaced, or a server replaying items whose
  tombstones expired, must not be able to add items.
- **Resurrected, flagged:** an id the device saw deleted reappears at or below its tombstone's
  revision, or after the tombstone left the manifest. It is refused and shown.
- **Sibling:** the same revision with another hash is a federation sibling, handed to the merge.

When two valid manifests carry one counter, the higher revision of each item wins, and the next
write signs above both.

For spaces, the server sends every member every space item's envelope. A member checks presence
and revision for every entry, and contents only for the collections they hold. The spaces plan
lists this under its server agreement.

### 7. OPAQUE (`opaque1`)

**Configuration**, from `crypto.md` "`opaque1`":
- RFC 9807 OPAQUE-3DH with appendix C vector 1's configuration (ristretto255-SHA512, HKDF, HMAC
  and SHA-512, the Identity KSF), and the context `"kemlock/v1/opaque"`;
- no client or server identities;
- the credential identifier is the email, trimmed and lower-cased;
- the password input is the 32-byte master key, not the typed password.

**Building it** (decision 1A):
1. ristretto255 per RFC 9496, over Dart `int` limbs, which are true 64-bit on the VM and on wasm;
2. `expand_message_xmd` with SHA-512, and the one-way map;
3. the RFC 9497 OPRF in mode 0;
4. the RFC 9807 envelope, KE1, KE2 and KE3;
5. registration, request then record.

Scalar and point arithmetic run in constant time where Dart allows: no branches on secret bits,
and conditional moves by masks.

**Secrets in memory.** The blind, the envelope key, the master key and the export key live only
for the call, in `Uint8List`s zeroed afterwards.

**A wrong password.** It fails at the server-MAC check. To the person it looks the same as an
unknown account, whose fake KE2 the server makes per RFC 9807's section on unknown users.

**The password wrap**, from `crypto.md`: under `HKDF(master key ‖ export key,
"kemlock/v1/password-wrap")`, with the additional data
`"kemlock/v1/root-wrap" ‖ account id ‖ u32be(key version)`. Neither key alone opens it.

**Compatible accounts** keep Bitwarden's wrap. The sync plan enrols OPAQUE once, through the route
that takes the Bitwarden hash; the client side is this plan's registration.

### 8. The other wraps

These aren't in `crypto.md` yet, apart from the approval seal. They are proposed here and listed
under "Agreed with the server".

- **Device approval.** The approving device seals the root with the sealed box, under the context
  `"device-approval"` and the `aad` `account id ‖ request id` (32 bytes, `crypto.md`'s).
- **Passkey PRF**, as `crypto.md` "The passkey PRF wrap of the root key" fixes it (`prf_wrap.dart`).
  - The PRF evaluation input is `first = SHA-256("kemlock/v1/prf-salt")`.
  - The wrap key is `HKDF(prf output, salt absent, info = "kemlock/v1/prf-wrap" ‖ lp(credential id))`.
  - The wrap is an AES-256-GCM seal of the root under the additional data
    `"kemlock/v1/root-wrap/prf" ‖ account id ‖ u32be(key version) ‖ lp(credential id)`.
  - The credential id is the raw WebAuthn credential id bytes.
- **Trusted device.** This plan owns the primitive; the sync plan's task 4.3 owns only the flow
  that uses it.
  The blob starts with `u8(1) ‖ platform byte` (`0x01` Secure Enclave, `0x02` Android Keystore,
  `0x03` WebCrypto), and a platform AEAD that takes associated data uses
  `"kemlock/v1/root-wrap/device" ‖ account id ‖ device id ‖ u32be(key version)`; both are
  `crypto.md`'s. The inner per-platform layout below is still this plan's proposal.
  1. Dart makes a random 32-byte `K_td` and seals the root under it, with that additional data,
     after the two prefix bytes.
  2. The platform wraps `K_td`: on iOS by ECIES with a Secure Enclave P-256 key, as
     `AutofillKey.swift` already does; on Android by a non-exportable Keystore AES-256-GCM key.
  3. Each platform gains one method pair, `wrapTrustedKey` and `unwrapTrustedKey`, on the channels
     behind `platform/unlock_keys.dart`.
  The two layers exist because iOS's ECIES takes no additional data. Whether the key needs
  biometrics is the sync plan's choice. The default reuses biometric unlock's policy from
  `harden-unlock-and-clipboard`.
  The same copy is also how an account that single sign-on made with no keys opens on its first
  device: that device makes the root key, the keys at version 1 and this copy, and sends them to
  `POST /kem/v1/account/keys/enrol` (the sync plan's task 6.3).

### 9. Vectors

- **RFC and draft vectors** are transcribed once into `mobile/test/fixtures/account/rfc/` and
  kept: RFC 9496 (ristretto255), RFC 9497 (the OPRF), RFC 9807 appendix C, the X-Wing draft's
  combiner cases, and FIPS 203 and 204 key generation from seeds. They test the primitives before
  the server publishes.
- **The server's vectors.** `crypto.md` "Test vectors" says `test-vectors/` (CC0) holds one JSON
  file per format, with `SHA256SUMS`. `mobile/tool/server/copy_vectors.sh <server repo>` copies
  them into `mobile/test/fixtures/server/` as they are, with `SOURCE.json` (repo, commit, date),
  and a test fails on any checksum mismatch. They are never edited, and refreshed only by the
  script.
- **No interim vectors.** Nothing of the app's making stands in for the server's. A format test
  without its server file stays skipped, saying which file it waits for.

### 10. Secrets in memory

Dart can't promise wiping, because the garbage collector may copy. So, as far as it can:
- keys live in `Uint8List`s, never `String`s;
- each holder has a `dispose()` that zeroes them, which the sync plan calls on sign-out and lock;
- comparisons of MACs, fingerprints and tags use one constant-time `bytesEqual`.

This also covers, for the new keys, the audit's note that `lock()` drops keys without wiping them
(plans/security-audit-2026-11-21.md).

## Behaviour

1. **One root per account.** A Compatible account's root is its Bitwarden user key, and the user
   key and its children derive from it under `crypto.md`'s labels.
   - With the Vaultwarden fixtures opened by their password, the user key equals the server's
     vector.
2. **The password wrap needs both keys.**
   - With the right password, the wrap gives the root.
   - With the right master key and another export key, or the reverse, it fails.
   - Under another account id or key version, it fails.
3. **The salt comes first.** Sign-in asks for the Argon2id settings and salt before sending KE1.
   An unknown email gets settings and a salt in the same shape.
4. **The other wraps open only in their place.**
   - A PRF wrap fails under another credential id.
   - A trusted-device wrap's bytes open nothing on another phone.
   - An approval seal opens only with the new device's one-time key, and only for its request id.
5. **Sealing needs both halves.**
   - A box doesn't open with only the ML-KEM or only the X25519 private key.
   - A box sealed under `"device-approval"` doesn't open as `"space-key"`.
   - Any changed byte gives "corrupted".
   - An all-zero X25519 secret is refused.
6. **Signatures need both halves.** A signature with one valid half doesn't verify, and a
   signature made under the context `"manifest"` doesn't verify as `"bundle"`.
7. **Fingerprints match.** Two phones show the same 12 groups of 5 digits for one bundle, equal to
   the server's vector. Scanning the QR code compares all 64 bytes.
8. **Items are bound to their place.** Each of these fails to open:
   - item A's ciphertext and key served as item B;
   - revision 3 served as revision 4;
   - a `login` served as a `note`;
   - a user's item served as a space's.
   Sealing one plaintext twice gives different ciphertexts.
9. **Legacy ids are stable.** `acc-1` in two people's vaults maps to two different UUIDs, and the
   same id under the same owner always maps to the same UUID. A UUID id is left as it is.
10. **Rollback isn't change.** On the device:
    - a lower revision is reported rolled back, and the device's copy stays;
    - a listed item withheld without a tombstone is reported missing, and isn't deleted;
    - an item no signed manifest lists is held and flagged, not applied;
    - an id seen deleted that comes back is refused and flagged;
    - a manifest with a bad signature is refused, and the old one kept.
11. **OPAQUE matches.**
    - RFC 9807 vector 1 matches at every step.
    - The server's `opaque.json` replays to the same messages, session key and export key.
    - A wrong password fails at the MAC check and unwraps nothing.
    - A changed server key fails, with no export key given out.
12. **Secrets stay in memory and off the UI thread.** Argon2id and OPAQUE leave the UI responsive.
    Disposing an account session zeroes its root, user key, private keys and export key.
13. **The vectors are pinned.** A hand-edited server vector fails the checksum test and names its
    file.

## Tasks

Run Flutter from `mobile/`. Commits follow `CLAUDE.md`:
- the scope is `crypto`, or `ios` and `android` for the channel methods;
- one change per commit, with each feature's tests in their own `test(crypto)` commit after it;
- the `Assisted-by` footer.

Coding agents don't run builds or tests. "Verified by" names the test that the single
build-and-test pass after merging runs, together with `flutter analyze` and `dart format`.

### 1. Groundwork

- [x] 1.1 Add `crypto/account/encoding.dart`: the conventions of design 2, base64url without
  padding, `lp()`, owners, and strict readers. Verified by `test/crypto/account/encoding_test.dart`,
  including padded and standard-alphabet input refused.
- [x] 1.2 Transcribe the RFC 9496, 9497 and 9807, X-Wing and FIPS 203 and 204 vectors into
  `fixtures/account/rfc/`. Verified by the tests of groups 2 to 6 reading them.
- [x] 1.3 Add `tool/server/copy_vectors.sh` and the checksum test over `fixtures/server/`. Verified
  by `test/crypto/account/vectors_checksum_test.dart`: a file whose checksum is wrong fails and is
  named, and an absent folder skips the server-vector tests with the file each waits for.
- [x] 1.4 Put the Argon2id seam of design 1 in front of `DartArgon2id`, with NFC on the password.
  Verified by a test through a fake runner.

### 2. Keys from the root

- [x] 2.1 Root, user key and children per `crypto.md`. Verified by `hkdf_tree_test.dart` against
  the Vaultwarden fixtures' user keys, and against the server's `account-keys` vectors once copied.

### 3. `kx1` and the sealed box

- [x] 3.1 `keyGenInternal(d, z)` in `ml_kem.dart` if missing, the 96-byte private key, and the
  combiner. Verified by `kx1_test.dart` with FIPS 203 seeds, the X-Wing combiner cases, the
  both-halves cases and the zero secret.
- [x] 3.2 The sealed box with its contexts. Verified by `sealed_box_test.dart`: the context
  mismatch, every flipped byte giving "corrupted", and a truncated box "malformed".

### 4. `sig1`, bundle and fingerprint

- [x] 4.1 Pure ML-DSA-65 with an empty context and a seed entry in `ml_dsa.dart` if missing, and
  `sig1`. Verified by `sig1_test.dart` with FIPS 204 seeds and one forged half failing.
- [x] 4.2 The bundle, the fingerprint digits and QR, and `FingerprintView`. Verified by
  `bundle_test.dart` with a swapped key refused, and a widget test of the 12 groups. (Code done:
  `bundle.dart` has the bundle, the digits and the constant-time comparison, and
  `features/spaces/fingerprint_view.dart` is the one widget, three rows of four groups and the QR
  code, which the spaces and sync screens use. `fingerprint_test.dart` is its widget test, in
  English and French, against the server's `bundle.json`. Verify after merge.)

### 5. `kem1`, legacy ids and the manifest

- [x] 5.1 Seal and open items, and wrap and unwrap item keys. Verified by `kem1_test.dart`: the four
  swap cases of Behaviour 8, and malformed input refused.
- [x] 5.2 `legacy_ids.dart`. Verified by `legacy_ids_test.dart`: `acc-1`, a 16-hex id and a space id
  against the server's legacy-id vectors once copied, and Behaviour 9.
- [x] 5.3 Build, sign and verify the manifest. Verified by `manifest_test.dart`.
- [x] 5.4 The comparison of design 6 as a pure function, and the deleted-id record it reads.
  Verified by `manifest_compare_test.dart`: each case of Behaviour 10.

### 6. OPAQUE (assumes decision 1A)

- [x] 6.1 ristretto255 (RFC 9496). Verified by `ristretto255_test.dart` with the RFC's appendix A.
- [x] 6.2 `expand_message_xmd` with SHA-512, hash-to-group, and the OPRF (RFC 9497, mode 0).
  Verified by `oprf_test.dart` with RFC 9497's ristretto255-SHA512 vectors.
- [x] 6.3 The OPAQUE client: registration, KE1, KE3 and the export key. Verified by `opaque_test.dart`
  with RFC 9807 vector 1, the wrong-password and changed-server-key cases, and the server's
  `opaque.json` once copied.
- [ ] 6.4 The same files under dart2wasm, if `add-browser-extension` has its core by then. Verified in
  the single build-and-test pass after merging, with `dart test -c dart2wasm`.
  - [x] The compatible part, done without the extension's core: no library of `crypto/account`,
    `crypto/opaque` or `features/spaces/fingerprint.dart` reaches `dart:io`, `dart:ffi`,
    `dart:isolate` or Flutter. `crypto/background.dart` is the one way in to isolates, a
    conditional import of `Isolate.run` where `dart.library.io` exists and of a call on the same
    thread where it doesn't; `argon2id.dart` and the in-memory `KMA1` functions use it.
    `attachment_format.dart` is split into `attachment_core.dart` (no `dart:io`, which `send.dart`
    imports) and `attachment_files.dart`, and still exports both. Held by
    `test/tool/wasm_imports_test.dart`, which reads the imports, and `background_test.dart`.
  - [ ] Compile and run under dart2wasm. The core isn't in this tree (`add-browser-extension` is
    not in `docs/plans`, and there is no `packages/kemlock_core`), and `mobile` has no
    `package:test`, which `dart test` needs, so no `dart_test.yaml` is added here. When the files
    move into `kemlock_core`, its `dart_test.yaml` takes `platforms: [chrome]` and
    `compilers: [dart2wasm]`, and its tests, which can't use `dart:io` for fixtures, are the ones
    that run with `dart test -p chrome -c dart2wasm`. Left open until then.
- If the owner picks C instead, 6.1 to 6.3 become:
  - add `rust/opaque/` with `opaque-ke` and `flutter_rust_bridge`;
  - build it for the Android ABIs and iOS;
  - make the F-Droid build compile it reproducibly;
  - add it to the free build's native allow-list.
  6.4 then becomes a JS-interop binding to `@serenity-kit/opaque`.

### 7. Wraps

- [ ] 7.1 Measure `DartArgon2id` at 64 MiB, 3 passes and 4 lanes. The owner does this on a mid-range
  Android phone and an iPhone, and the times are recorded here. Above 3 seconds, the owner chooses
  a native Argon2id or asks the server session for other settings.
- [x] 7.2 The master key and password wrap of designs 4 and 7. Verified by `wraps_test.dart`: the
  cases of Behaviour 2.
- [x] 7.3 The PRF wrap and the approval seal. Verified by `prf_wrap_test.dart` and
  `sealed_box_test.dart`: Behaviour 4. (Code done; verify after merge.)
  - The PRF wrap (`prf_wrap.dart`) and its salt constant. `prf_wrap_test.dart` checks it by hand
    against `crypto.md` and a failure under another credential id, and
    `server/prf_wrap_vectors_test.dart` replays the server's `prf-wrap.json`.
  - The approval seal needs no code of its own: it is `sealBox` and `openBox` in
    `sealed_box.dart` with the context `SealContext.deviceApproval` (`"device-approval"`) and the
    `aad` `account id ‖ request id`, which the sync plan's flow builds as `approvalAad` in
    `km_approvals.dart`. `sealed_box_test.dart` opens it only with the new device's one-time key
    and for its own request and account id.
- [x] 7.4 The trusted-device primitive: the Dart layer, plus the platform wrap of K_td on the
  `device_keys` channel of the iOS and Android runners. Verified by a Dart test with a fake channel, a Kotlin
  unit test, and an XCTest of the ECIES round trip. The last two run in the single pass after
  merging; Swift runs in CI's macOS job, since this laptop has no Xcode.
  (Code done; verify after merge. The Dart layer is `trusted_device.dart`: its prefix and aad are
  `crypto.md`'s, and the inner per-platform layout is still this plan's proposal. The platform half
  is not a second pair of `wrapTrustedKey` and `unwrapTrustedKey` channel methods: it is `wrap` and
  `unwrap` on the `com.kemlock.app/device_keys` channel of `add-kemlock-server-sync` 4.1 (ECIES with a
  Secure Enclave key in `DeviceKeyChannel.swift`, AES-256-GCM with a Keystore key in
  `DeviceKeyChannel.kt`), reached through `DeviceKeysWrapper` and `KmTrust`. The tests are written and
  not built here: Dart over a fake channel (`trusted_device_test.dart`, `km_trust_test.dart`,
  `device_keys_test.dart`), Kotlin `DeviceKeyFormatTest` (the wrap round trip with a software AES key)
  and XCTest `DeviceKeyChannelTests` (the ECIES round trip with a software P-256 key).)
- [x] 7.5 The holders' `dispose()`, zeroing buffers. Verified by `account_session_test.dart`: every
  buffer reads zero afterwards.
- [x] 7.6 Seal and open the account's private keys (`private_keys.dart`): `u8(1) ‖ kx1 private ‖
  sig1 private` (161 bytes) under the user key's `"kemlock/v1/private-keys"` child, with the aad
  `"kemlock/v1/private-keys" ‖ account id ‖ u32be(key version)` ("The account's private keys").
  Verified by `private_keys_test.dart`. (Code done; verify after merge.)

### 8. The server's vectors and the docs

- [x] 8.1 Copy the server's `test-vectors/` with 1.3's script, once published. Verified by every
  format test passing on them in the pass after merging. (Copied from kemlock-server 7fac2fe,
  unedited, in `mobile/test/fixtures/server/`; `mobile/test/crypto/server/` holds one test file per
  vector file: account-keys, argon2id, bundle, kem1, kx1, legacy-ids, manifest, opaque,
  password-wrap, sealed-box and sig1. Run them in the pass after merging.)
  - `server-seal.json` has no test: the server seals its own secrets with `server.key`, and the
    app never does.
  - `dedup.json` has no test yet: the duplicate cleaner isn't built, and
    `docs/plans/add-duplicate-cleaner.md` adds it when it implements the tags.
  - The server publishes no vectors for the trusted-device blob or the approval seal, so
    `trusted_device_test.dart` and the approval cases of `sealed_box_test.dart` stay hand-checked
    against `crypto.md`. It does publish `prf-wrap.json`, which `server/prf_wrap_vectors_test.dart`
    replays, and `private-keys.json`, which has no vector test yet: `private_keys_test.dart` is
    still hand-checked.
- [x] 8.2 Document the formats in `README.md`'s Security Architecture section, linking `crypto.md`.
  Verified by `kx1`, `sig1`, `aead1`, `opaque1` and `kem1` being named there.

## Agreed with the server

`crypto.md` settles every byte above except:
- the approval fingerprint;
- the trusted-device wrap's inner per-platform layout (its prefix and aad are `crypto.md`'s);
- collection keys as the parent of `item-wrap`;
- the kind `contact`;
- the route that returns the Argon2id settings and salt.

The kemlock-server session decides each, and this plan follows.

## Dependencies

- `docs/plans/add-kemlock-server-sync.md` uses everything here: sign-in, the wraps, `kem1`, the
  manifest results and legacy ids. It also stores the keys. It can't ship before groups 2 to 7.
- `docs/plans/add-server-spaces.md` uses the sealed box, `sig1`, the fingerprint and the manifest
  rule, and supplies collection keys.
- `docs/plans/add-duplicate-cleaner.md` derives its dedup key from the user key or a space key, per
  `crypto.md`.
- `docs/plans/move-off-vaultwarden-sync.md` relies on design 3: a Compatible account's root is its
  Bitwarden user key. It also uses legacy ids and signs a manifest after the move.
- `docs/plans/add-cards-identities-and-websites.md` adds the `card` and `identity` kinds, both
  already in `crypto.md`.
- `docs/plans/add-credential-exchange.md` uploads through `kem1`; it needs nothing else here.
- Earlier changes, in git history before 5ba88b42:
  - `add-browser-extension`: tasks 2.2, 2.3 and 2.6, for the runner, `kemlock_core` and dart2wasm;
  - `add-fdroid-release`: decision 9, the native allow-list;
  - `harden-unlock-and-clipboard`: the biometric key policy;
  - `add-vault-items` and `add-passwords`: the kinds that exist today.
- The server: `crypto.md` and its published `test-vectors/`.
