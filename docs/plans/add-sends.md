# Kemlock Sends

This plan lets the app share a secret through a link. A Kemlock Server account holder makes a
Send from the phone: a text, or a file. They choose when it is deleted, whether it expires
earlier, how many times it may be opened, and an optional password. The app shows the link and
copies or shares it. The owner sees a list of their Sends and can edit or delete any of them. Anyone
with a link can open it in the app, with or without an account. The key is only ever in the link's
fragment, which no request carries.

Every byte is the server's contract: `docs/crypto.md` "Sends" in `../kemlock-server`, branch
`build/vertical-slice` at e75e333. The section was added in 4d05056 and has the meta key that
derives from the owner's item-wrap key. The routes are
`crates/kemlock-api-kem/src/routes/sends.rs`, at 2608dee. Task 1.2 read both again at 4f763da, and
the README of `mobile/test/fixtures/kemlock` records what it found. This plan cites both by
section and adds only the app's side.

## Why

The server and the web vault have Sends. The app has none.

- **The server has all of it.** `sends.rs` serves the owner's routes (`POST`, `GET /kem/v1/sends`,
  `GET`, `PUT`, `DELETE /kem/v1/sends/{id}`, `PUT /kem/v1/sends/{id}/file`). It also serves the
  public routes (`POST /kem/v1/send-access/{accessId}` and `…/file`).
- **The web vault made Sends, and now opens them.** It makes them, lists them and builds their
  links (`web/src/features/send/sendCrypto.ts`, `sendLink`). At e75e333 its router had no page that
  opened one: `web/src/app/router.tsx` has `/send` under the vault's layout and no public
  `/#/send/<accessId>/<key>` route, and `createSendAccessApi` in `web/src/api/sends.ts` was called
  by nothing, so no Kemlock client opened a Send link. By 4f763da `web/src/app/Root.tsx` shows
  `SendAccess` for such a hash.
- **The design wants Sends free.** "Kemlock Server: design and architecture"
  (https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y) lists Send in its screen review as "Text or
  file, view limit, password, hidden email, 1 to 30 days, key after the #". It is marked
  "Feasible" and "Free for every account".

People who keep a vault in Kemlock share passwords and recovery codes by message today, where the
secret stays readable for good. A Send gives the secret an end date and an open limit. The server
can't read it.

## What changes

- **Making a Send** from the open vault, once Kemlock Server sync is signed in:
  - A text, or one file up to 50 MiB.
  - A name the recipient sees, and private notes only the owner sees.
  - A deletion date 1 to 30 days ahead, 7 by default, and an optional earlier expiry.
  - An optional limit on opens, and an optional password.
  - "Hide my email", which a space policy may refuse.
- **The link.** Once the server has the Send, a sheet shows its link with Copy and Share. Copy goes
  through the secret clipboard, which marks the copy sensitive and clears it after the delay set in
  Settings (`platform/secret_clipboard.dart`).
- **The owner's list.** A "Sends" page, opened from the Vault tab. Each row shows the Send's name,
  kind, status (active, expired, used up, off, waiting for its file), opens used of the limit, and
  when it is deleted. Copy link works from every row, because the link is rebuilt from the Send's
  sealed key with no copy kept on the phone.
- **Editing and deleting.** The owner can change the name, notes and text (of a text Send), the
  dates, the open limit, the password (set, change or remove), "Hide my email", and an on/off
  switch. Delete removes the Send and its file. A Send's key, its file and its open count never
  change (`UpdateSendRequest` in `sends.rs`).
- **Opening a Send, as a recipient.** A link reaches the app in one of two ways:
  - shared to Kemlock from another app's share sheet;
  - pasted into "Open a Send" on the Sends page.

  The app reads the link, asks for the password if the Send has one, then shows the text or offers
  the file. Recipients need no account. A link in the web vault's format is the same link
  (`https://<host>/#/send/<accessId>/<key>`) and opens the same way. A Bitwarden Send link, whose
  key is 16 bytes, is handed to the browser.
- **The password proof.** The app never sends the password. It sends the 32-byte Argon2id proof
  that `crypto.md` "Password" fixes: 19 MiB, 2 passes, 1 lane, run off the UI thread.
- **Offline mode** stops every Send request, making and opening alike, and the sheets say so.
- **Making a Send from an item:** a login's password, or a note's text, starts a new text Send,
  after the owner check. This assumes decision 3 (b).
- **Nothing on the phone changes shape.** No new stored key and no new sealed value. No format the
  app already writes changes.

Out of scope:

- Sends of a Bitwarden app on the Bitwarden API. `crypto.md` keeps them in Bitwarden's format, and
  "a client never mixes the two". The app opens no Bitwarden Send: it hands the link to the browser.
  The Sends the account made from a Bitwarden app are listed, and can be deleted, but not opened,
  edited or shared (design 5).
- A recipient page in the web vault. It is the server's, and it has one (see "Agreed with the
  server").
- Opening `https` Send links straight from a tap in another app, through Android App Links or iOS
  Universal Links. Both need the host fixed in the build, and a self-hosted server's host can't be:
  the sync plan's decision 4 found the same for passkeys. The app's entitlements have no associated
  domains (`ios/Runner/Runner.entitlements`). The manifest claims no `https` link
  (`android/app/src/main/AndroidManifest.xml`). The server serves no `assetlinks.json` or
  `apple-app-site-association`.
- A QR code of a link, and scanning one.
- Email-verified recipients. The design doc lists them under "Send extras" as P1, and the server has
  no route for them.
- Sends in the browser extension, and Sends owned by a space.

## Decisions for the owner

Taken as recommended on 2026-11-22, when the owner said to keep going without answering them; the owner may still overturn any. Since the plan was written, the web vault gained a recipient page, so "browser only" would now work too.

Each question lists its options and a recommendation. The tasks assume the
recommendation, as each one says.

1. **Can recipients open Sends in the app, or only in the browser?**
   - (a) In the app, for anyone with Kemlock and an unlocked vault, no account needed. A link
     arrives through the share sheet or the paste field. A link the app can't open (a Bitwarden
     Send, a key of the wrong length) goes to the browser through `LinkOpener`.
   - (b) Only in the browser. The app hands every Send link to `LinkOpener`.
   - (c) (a), plus claiming `https` links through App Links and Universal Links for one host fixed
     at build time, if Kemlock ever runs a hosted server.
   - *Recommendation: (a).* At e75e333 the web vault had no page that opened a link, so under (b) a
     link the app made would have opened nowhere until the server built one; it has one now, at
     4f763da. In the app, the received text
     stays in the secret clipboard and the secret selection, and a file goes through the app's own
     save, with no copy left in the cache. (c) has no host to name today. The tasks assume (a).
2. **Do Sends need a gate?** No.
   - **Decided by the owner on 2026-11-23: Kemlock is free and open source, and nothing is gated.**
     Making, listing and editing need a Kemlock Server sign-in and nothing else. Opening is free for
     everyone, with no account. The server design marks Send "Free for every account", and the sync
     plan's decision 1 gates nothing either.
3. **Can a Send be made from an item?**
   - (a) No. Every Send starts from the New Send sheet.
   - (b) Yes, for text: "Send" on a login's password and on a note's text opens the New Send sheet
     with that text filled in and the item's name as the name. It runs the owner check first
     (`ownerCheckProvider`, `features/vault/owner_check.dart`), as a reveal does. The Send is a copy
     and isn't linked to the item afterwards. A note's file isn't offered.
   - (c) (b), plus a note's attached file, decrypted from its `KMA1` and sealed again under the
     Send's payload key.
   - *Recommendation: (b).* It covers the common case, sharing one password, without a new place
     where a vault file is decrypted. (c) can follow once file Sends have been used. The tasks
     assume (b) (group 9).

## Design

### Context

- **The format.** `crypto.md` "Sends":
  - The link key `K` is 32 random bytes. The send id is a version 4 UUID the client chooses. The
    access id is the id's 16 bytes in base64url, 22 characters.
  - The link is `https://<host>/#/send/<access id>/<base64url(K)>`, and the key is 43 characters.
  - The payload key and the proof salt derive from `K`. The meta key derives from the owner's
    `"kemlock/v1/item-wrap"` child key, never from `K`, so a link holder can't read the owner's
    notes. Its HKDF info also binds the send id and `u32be(key version)`.
  - Every seal is AES-256-GCM, `nonce(12) ‖ ciphertext ‖ tag(16)`. Payload and meta take the aad
    `label ‖ send id ‖ lp(kind)`. `sealedKey` is `u32be(key version) ‖` the seal of `K` under the
    item-wrap key, with aad `"kemlock/v1/send-key" ‖ send id ‖ u32be(key version)`: 64 bytes.
  - The payload JSON is exactly `{"name","text"}` or `{"name","mime","size"}`, and a reader refuses
    any other field. The meta JSON is exactly `{"name","notes"}`.
  - A file is one `KMA1` file under the payload key, `12 + plain + 16 × max(1, ⌈plain / 65536⌉)`
    bytes long.
  - The password proof is `Argon2id(NFC password, proof salt, m = 19456, t = 2, p = 1, L = 32)`.
- **What the server checks** (`sends.rs`, `kemlock-domain/src/sends.rs`):
  - The id is a version 4 UUID, and a taken id is a 409. The kind is `text` or `file`.
  - `meta` is at least 28 bytes and at most 16 KiB, and `payload` at most 256 KiB. `sealedKey` is
    64 bytes and the proof is 32 bytes.
  - `file.size` must be a `KMA1` length, at most `max_file_size` (100 MiB by default). The upload
    must have that `Content-Length` and start with `KMA1`.
  - The deletion date is in the future and at most 30 days away, with one hour of clock skew
    forgiven. The expiry may not come after it. An open limit is at least 1.
  - A space policy may refuse making a Send ("Remove Send"), or refuse hiding the email ("Always
    show the sender's email"). Either is a 403 `send-policy`.
- **What a recipient gets** (`kemlock-app/src/sends/access.rs`):
  - The public routes take no account. `POST /send-access/{accessId}` answers `AccessDto`: kind,
    sealed payload, `fileSize`, dates, and the sender's email unless hidden. It sends
    `Cache-Control: private, no-store`.
  - A text Send counts an open when it is opened. A file Send counts one only when its bytes are
    downloaded (`…/file`), so a Send limited to one open can still be read before the download.
  - Without a proof, a Send with a password answers 401 `send-password-required`. A wrong proof
    answers 401 `send-wrong-password`. Tries with a proof are limited to 10 a minute per Send (a
    right proof clears the count), then a 429 `rate-limited` that waits 1 second and doubles. A
    request with no proof isn't counted.
  - A Send that is off, expired, deleted, used up or still waiting for its file is a plain 404.
- **The app already has:**
  - the item-wrap key (`AccountKeys.itemWrapKey`, `crypto/account/keys.dart`) and the key version
    (`KmAccount.keyVersion`, `features/sync/kemlock/km_account.dart`);
  - HKDF with an absent salt (`crypto/hkdf.dart`), AES-256-GCM (`crypto/aes_gcm.dart`), and
    `label`, `lp`, `u32be` and strict base64url (`crypto/account/encoding.dart`);
  - Argon2id behind its seam with NFC (`deriveMasterKey`, `crypto/account/argon2id.dart`), which
    takes a 16-byte salt and any settings, so it makes the proof as it is;
  - `KMA1` (`crypto/attachment_format.dart`), whose `kma1Length` is the server's length rule;
  - the Kemlock client: `KmApi` (`features/sync/kemlock/km_api.dart`) has design 16's limits (no
    redirects, read caps, timeouts, DPoP when a token is passed and none with `proof: false`);
  - `KmHost.withAccount` (`km_host.dart`), which runs an action with a connection and the open
    account outside a sync and wipes the account's keys after;
  - `KmHost.requireHome` for what only the home server may do;
  - the gated client (`platform/network.dart`), the link opener with its offline prompt
    (`platform/links.dart`), and the secret clipboard and secret selection
    (`platform/secret_clipboard.dart`, `platform/secret_selection.dart`);
  - the share hand-over (`platform/shared_items.dart`, `features/share/share_flow.dart`, the
    Android `SEND` filters in `AndroidManifest.xml`, and the iOS `Share` extension);
  - `FileService.saveFile` and `shareFile` (`platform/files.dart`), which on iOS write the file
    under the temporary `share/<random>/` folder only while the share sheet is open.
- **Sends live on one server.** The design's federation table says Send links don't travel between
  servers: "A link names one server's address".

### 1. Where the code lives

- `mobile/lib/crypto/account/send.dart`: the keys, seals, wrap, proof and strict JSON readers of
  `crypto.md` "Sends". It is pure Dart beside `kem1.dart`, so it moves into `kemlock_core` with the
  rest of `lib/crypto` (`add-account-crypto` design 1).
- `mobile/lib/features/sync/kemlock/km_sends_api.dart`: the owner's and public routes over
  `KmApi`, in `km_auth_api.dart`'s style. No Flutter.
- `mobile/lib/features/sends/`: `send_link.dart` (reading and building links, no Flutter),
  `sends_service.dart` (making, listing, editing, opening, no Flutter), and the sheets:
  `sends_page.dart`, `new_send_sheet.dart`, `send_link_sheet.dart`, `send_edit_sheet.dart` and
  `received_send_sheet.dart`.
- `mobile/lib/platform/send_links.dart`: `PendingSendLink`, in `setup_links.dart`'s shape: a link
  that arrived waits there while the vault is locked.

*Weighed:* putting everything under `features/sync/kemlock/`. Opening a Send has nothing to do with
sync or an account, and a recipient without Kemlock Server sync would then depend on the sync
folder.

### 2. The format in Dart

`send.dart` follows `crypto.md` byte for byte:

- `sendPayloadKey(K)`, `sendProofSalt(K, sendId)` and `sendMetaKey(itemWrap, sendId, keyVersion)`
  use `hkdfSha256` with an empty salt, which `keys.dart` notes is the absent salt.
- `sealSendPart` and `openSendPart` take the label, id, kind and key, with the aad
  `label(text) ‖ id ‖ lp(kind)`. The label is raw ASCII, as `kemlock-crypto/src/send.rs` `aad`
  writes it, with no length before it.
- `wrapLinkKey` and `unwrapLinkKey` work on the 64-byte `sealedKey`. `sealedKeyVersion` reads its
  first four bytes, so the meta key derives before `K` is opened. `crypto.md` asks for this so the
  list needs no link in hand.
- `SendPayload` and `SendMeta` are strict readers that refuse a missing field, an extra field or a
  wrong type, as `parsePayload` and `parseMeta` do in `sendCrypto.ts`. A `size` that is negative or
  above 2^53 is refused.
- Keys are `Uint8List`s, wiped after use (`add-account-crypto` design 10).

*Weighed:* calling the web vault's worker code through a WebView. That would bring a WebView into a
password manager for one feature. The Dart is about 200 lines over primitives the app already
tests.

### 3. Links: reading, building, never logging

`send_link.dart`:

- **Building.** `sendLink(server, sendId, K)` is the server's address as the sync target keeps it,
  path included, then `/#/send/<accessId>/<b64url(K)>`. It is the shape `crypto.md` fixes and
  `sendLink(origin, …)` writes in the web vault. The app uses the address it signed in to (the
  sync target's), not `KmConfig.domain`, so a link points where the phone already reached the
  server.
- **Reading.** `SendLink.parse(text)` takes:
  - an `https` URL whose fragment is `/send/<accessId>/<key>` exactly, with any path before the `#`;
  - the first such URL inside a longer text, such as a message pasted whole.

  It refuses anything else. The access id must decode to 16 bytes, which is the send id. The key
  must decode to 32 bytes, which makes it a Kemlock Send. A 16-byte key is a Bitwarden Send and
  comes back as `BitwardenSendLink`, for the browser. `http`, a user-info part, a query and padded
  base64 are refused, by the same strict decoder as `encoding.dart`.
- **Requests.** The access route is built from the link's scheme, host, port and path, plus the
  access id, through `KmApi`'s `_api` rule (`server.path + /kem/v1 + route`). The key goes into no
  `Uri`, header or body, so no request, error message or `http.ClientException` can carry it.
- **Never logged.** `SendLink.toString()` prints the host and access id and "key hidden". Nothing in
  `features/sends` or `km_sends_api.dart` calls `debugPrint` or `print`; the lint already sets
  `avoid_print`. A test fails if those files call either. Problems name the host, never the link.
  The link's text field and the received text are cleared when their sheet closes.

### 4. Making a Send

`SendsService.make` runs inside `KmHost.withAccount`, after `requireHome`:

1. Check the input. A text's sealed payload must fit 256 KiB, checked after sealing as
   `sendCrypto.ts` does. A file must be at most 50 MiB (design 8). The deletion date must be 1 to
   30 whole days ahead, and the expiry, when set, no later.
2. Choose the send id (a random version 4 UUID, which the server requires) and `K`.
3. Seal the payload under the payload key. Seal the meta under the meta key, with
   `account.keyVersion`. Wrap `K` under the item-wrap key. For a file, write the `KMA1` file under
   the payload key with `kma1Encrypt` in an isolate.
4. If there is a password, make the proof (design 6).
5. `POST /kem/v1/sends` with `file.size = kma1Length(plain)` for a file. For a file, then `PUT` the
   bytes to `uploadUrl` with their `Content-Length`. That address must be the same server
   (`kmSameServer`), because the server builds it from its own domain (`upload_url` in
   `sends.rs`).
6. If the upload fails, try it twice more. Then `DELETE` the Send, so no file Send waits closed for
   the server's 24-hour purge (`SendsConfig.abandoned_after`), and say the file didn't go up.
7. Return the link. Wipe `K`, the payload key and the meta key.

A 409 on the create means the id was taken. The service picks a new id and seals again, once. A 403
`send-policy` shows the server's reason. A 413 shows the server's `maxSize`.

The New Send sheet:

- **Text or File.** The text field takes up to the payload cap, and the file comes from
  `FileService.pickFile`, whose picker copy is deleted once read (`platform/scratch.dart`).
- **Name**, labelled as seen by the recipient. It goes into the payload for a text, as
  `sendCrypto.ts` puts it, and into the meta. For a file, the payload carries the file's own name.
- **Notes**, labelled "Only you see these".
- **Deletes after:** 1, 2, 3, 7, 14 or 30 days, 7 by default.
- **Link stops working:** never before deletion, or a date before it.
- **Opens:** no limit, or a number from 1.
- **Password:** optional, with the generator's button.
- **Hide my email:** off by default.

*Weighed:* making the Send and uploading its file as one step that the server rolls back. The
server's routes are two steps by design ("a file Send is made without its bytes and stays closed
until … lands them", `create.rs`). Deleting on failure gives the same result from the phone.

### 5. The owner's list, editing and deleting

- **List.** `GET /kem/v1/sends` gives `SendDto`s, newest first. For each, the phone reads the key
  version from `sealedKey`, derives the meta key, opens `meta`, and unwraps `K`. A row that doesn't
  open shows as "Can't be read on this phone" with Delete only. Status comes from the DTO alone:
  - `disabled`: off;
  - `expiresAt` passed: expired;
  - `accessCount ≥ maxAccess`: used up;
  - `file.ready` false: waiting for its file;
  - otherwise active.
- **Sends made in a Bitwarden app.** The server keeps them in the same table, and the list returns
  them with a `sealedKey` that is the UTF-8 of Bitwarden's key string, not 64 bytes. `KmSendsApi.list`
  returns each as a `KmForeignSend`: the id, kind, deletion date, expiry, open count and limit, password
  flag and on/off switch, which the server keeps in plain. Their `meta`, `sealedKey` and `payload` are
  never decoded, and nothing is decrypted. A `sealedKey` that isn't base64url still fails the whole list.
  The page shows them in their own section, "Made in a Bitwarden app", with the line "Made in a
  Bitwarden app. Open, change or share it there." A tap opens a small sheet with that line, the status
  and Delete, which asks first and uses the same `DELETE /kem/v1/sends/{id}`. It has no Copy link, Share,
  Show text or Edit. The app keeps no count or limit of the account's Sends, so none includes them.
- **Copy link** rebuilds the link from `K`. Nothing about a Send is stored on the phone, so the list
  is read again each time the page opens, and pulled down to refresh.
- **View.** The owner reads a text Send's content by opening `payload` with `K`, from the DTO. That
  makes no public request, so it never spends an open.
- **Edit.** `PUT /kem/v1/sends/{id}` sends every option again, because the server replaces them all
  (`UpdateSendRequest`):
  - `meta` sealed again with a fresh nonce;
  - for a text Send whose text or name changed, `payload` sealed again under the same `K`, as
    `crypto.md` says an edit does;
  - the open limit, which can't go below the opens already used, so the sheet doesn't offer it;
  - the dates, with deletion at most 30 days from now;
  - "Hide my email", and the on/off switch (`disabled`);
  - a new proof, or `removePassword`, never both.

  A file Send's file and name can't change; the sheet says to make a new one.
- **Delete.** `DELETE /kem/v1/sends/{id}`, after a confirmation that names the Send. A 404 counts as
  done.

*Weighed:* caching the list sealed in the vault, for offline viewing. It would add a stored key, a
re-seal on key-pair replacement and a stale list, for a page that is no use offline: a link can't
be opened while the network is off.

### 6. The password proof

`sendProof(password, K, sendId)` is
`deriveMasterKey(password, sendProofSalt(K, sendId), settings: Argon2idSettings(memoryKiB: 19456,
iterations: 2, parallelism: 1))`. That gives NFC, the 16-byte salt check, wiping and the isolate
seam for nothing extra. The sheet shows a spinner while it runs.

- **The owner** makes it once when the Send is made or its password changes.
- **A recipient** makes it once per password typed, before any request that carries it. The proof
  is kept in memory for the file download that follows, and wiped when the sheet closes.
- **Rate limit.** A 429 shows "Too many tries. Try again in N seconds", from `retryAfter` or
  `Retry-After` as `km_api.dart` reads them. The password field stays disabled until then.
- **Empty passwords.** An empty field means no password, as in `sendCrypto.ts`.

*Weighed:* sending a hash the server could check faster. `crypto.md` fixes the proof, and its cost
is what makes a stolen database useless without the link.

### 7. Opening a Send, with no account

The public routes take no account and no token (`sends.rs`: "The public routes take no account").
So opening needs neither a Kemlock Server account nor sync. It needs Kemlock installed, and a vault
open, because links are taken by the open vault's shell as set-up links and shared items are
(`app/app_shell.dart`). Someone without Kemlock opens the link in a browser, once the web vault has
a recipient page.

`SendsService.open(link)`:

1. If the link is a `BitwardenSendLink`, hand it to `LinkOpener.open`, which asks first while
   offline mode is on, and stop.
2. Build a `KmApi` over the gated client with no pin, system trust only. The recipient has never
   seen this server, so there is nothing to pin and no certificate to offer. It must be https.
3. Send `POST /kem/v1/send-access/{accessId}` with an empty body and no proof, and with no
   `Authorization` and no DPoP, even when the host is the recipient's own server.
   - On 401 `send-password-required`, ask for the password, make the proof, and send again with
     `{"password": <proof>}`.
   - On `send-wrong-password`, say so and ask again.
   - On 404, say "This Send isn't available. It may have expired, been used up or been deleted."
     The server doesn't say which.
4. Check the answer:
   - `kind` is `text` or `file`;
   - `payload` opens under the payload key with this id and kind;
   - the payload JSON is the kind's, exactly;
   - for a file, `fileSize == kma1Length(payload.size)`.

   Anything else shows "This link doesn't open", and nothing is shown.
5. Show the text, or the file's name, type and size with Save and Share. A file's bytes are fetched
   only on Save or Share (`POST …/file`), which spends the open. The sheet says so when the Send has
   an open limit.

The sender's email, when the server sends one, shows as "The server says this is from
name@example.com". It is the server's word, not signed by the sender, and the sheet says so.

*Weighed:* opening on the lock screen, without the vault. It would show a secret on a phone whose
owner hasn't unlocked it. It would also need the clipboard, the selection guard and the file save
outside the shell that holds them today.

### 8. Files: caps, and no plain copy in the cache

- **Making.** A file Send is at most 50 MiB, the app's attachment limit (`attachmentSizeLimit`,
  `models/secure_note.dart`). The server's own limit may be lower, in which case its 413 says
  `maxSize`.
- **Opening.** The app refuses a file whose `payload.size` is over 50 MiB before downloading
  anything, and offers the browser instead. The download is read up to `fileSize` bytes, no more
  (`readAnswer` in `platform/network.dart`), with `KmApi.fileTimeout`.
- **In memory only.** The `KMA1` bytes and the plaintext are held in memory: `kma1Decrypt` runs in
  an isolate. Nothing is written to disk until the person taps Save or Share.
  - **Save** goes through `FileService.saveFile`: the system save dialog on Android, which takes the
    bytes, and the share sheet on iOS.
  - **Share** goes through `FileService.shareFile`.
  - On iOS, both write one file under `<temporary>/share/<random>/`, which `_share` in `files.dart`
    deletes when the sheet closes.
  - The file's name comes from the sender, and only `fileNameOnly` makes it a path (`files.dart`).
- **When the sheet closes or the vault locks,** the bytes are dropped and the buffers zeroed.
- **A killed app.** A save that was cut short, with the app killed while the iOS share sheet was
  open, leaves that one copy. Task 8.2 checks that the start-up sweep (`main.dart`,
  `sweepPhoneScratch`) or a new one removes `share/<random>/`. `scratch.dart` notes that `share/`
  "has a sweep of its own" for the shared item that waits, and the task confirms it covers this
  case. If it doesn't, it adds the sweep.

*Weighed:* streaming the download to an encrypted file, as `kma1DecryptFile` does for note files. At
50 MiB, memory is enough, and nothing reaches the disk at all.

### 9. How a link reaches the app

- **Share sheet, Android.** Chrome and Messages share a link as `text/plain`, which the existing
  `SEND` filter takes (`ShareIntent.kt`). Kemlock gets a `SharedText`.
- **Share sheet, iOS.** The extension takes plain text, or anything that conforms to `public.data`
  (`ios/Share/Info.plist`). A shared item that isn't plain text goes to `loadFileRepresentation`
  (`ShareViewController.swift`, `write`). Safari shares a page as `public.url`, so a link from Safari
  may arrive as an unreadable file. Task 7.4 makes the extension take an `https` `public.url` as
  text. The hand-over file has complete file protection and is deleted when taken
  (`ios/Shared/SharedItemFile.swift`).
- **Before other shared text.** A `SharedText` that `SendLink.parse` reads is taken out of
  `offerSharedItem` before any other shared item is handled and goes to the Send sheet.
- **The paste field.** "Open a Send" on the Sends page has a text field the person pastes into. The
  app never reads the clipboard itself, which would show iOS's paste prompt, and never clears a
  clipboard it didn't write.
- **Waiting.** `PendingSendLink` holds a link that arrived while the vault was locked, as
  `PendingSetupLink` does, and the open vault's shell takes it.

### 10. Offline mode, failover and policies

- **Offline mode.** Every request goes through the gated client, which refuses while offline mode is
  on (`NetworkGate`, `OfflineException`).
  - The Sends page says "Offline mode is on" and lists nothing.
  - New Send is disabled with that reason.
  - A link that arrives says the same, with "Open in browser", which goes through `LinkOpener`'s
    offline prompt.
  - A Bitwarden link goes through that prompt too.
- **Failover.** Sends live on the home server only. While the phone is on a replica
  (`kemlockAwayProvider`), making, listing and editing are refused through `KmHost.requireHome`,
  and the page says "Your home server is offline since 09:12. Sends are kept there". Opening a link
  is unaffected: it goes to the link's own host.
- **Session ended.** If the server ended the session, the page shows sync's message and its "Sign in
  again" (`KmProblem.sessionEnded`).
- **No sync.** Without Kemlock Server sync, the page says "Sends need Kemlock Server sync" with a
  button to Settings › Sync. "Open a Send" still works.

### 11. The clipboard and the screen

- **Copy link** and a received text's Copy go through `SecretClipboard`. On Android it sets the
  sensitive mark. On iOS it is local only, with the expiry. It clears after the Settings delay, 30
  seconds by default (`defaultClipboardClearSeconds`, `features/settings/prefs.dart`).
- **The link sheet** says the link opens the Send for anyone who has it. A link meant for a message
  is better shared with Share than copied.
- **Received text** shows in a `SelectableText` with `secretTextMenu` inside `SecretSelection`. That
  leaves out Share, Look Up and Search Web, so the text reaches no other app by a long press.
- **"Save as note"** adds the text to the open vault as a note, so the person can keep it after the
  Send is gone.

### 12. Limits on what a server can send

The sync plan's design 16 applies, through `KmApi`:

- no redirect is followed;
- an access answer is read up to 512 KiB, which holds a 256 KiB payload in base64url;
- a list is read up to 8 MiB (`maxPageBytes`);
- a file is read up to `fileSize`, at most `kma1Length(50 MiB)`;
- JSON requests time out at 30 seconds, files at 5 minutes;
- the sender's email is shown only if it is at most 254 characters, without control characters.

### Risks

- **The server's shapes change.** Task 1.2 read them again from the server's code at 4f763da, and
  the sync plan's contract test (its task 13.2) covers these routes once the OpenAPI JSON is copied.
- **`send.json` was late.** `crypto.md` and `test-vectors/README.md` listed it, but it wasn't in the
  tree at e75e333. Group 2 was tested against `kemlock-crypto/src/send.rs` read by hand and the web
  vault's round trip, and closes with task 2.4's vectors, which the server has published.
- **Argon2id at 19 MiB in pure Dart is slow on old phones.** It runs in an isolate with a spinner.
  The account crypto plan's task 7.1 measures 64 MiB; the owner notes the 19 MiB time beside it.
- **A view can be lost to a dropped connection.** The server counts a text Send's open before its
  answer reaches the phone. If the connection drops, the open is spent and the phone saw nothing.
  The sheet says so on the 404 that follows. The server can't fix this without a second step.
- **Self-signed recipients' servers.** A recipient's phone trusts only the system's roots, so a link
  to a server with a self-signed certificate won't open in the app. The sheet offers the browser.

### Rolling back

Nothing stored changes, and no released format changes. Removing the feature leaves the server's
Sends in place, readable from the web vault.

## Behaviour

### Making a Send

- **A text Send needs a Kemlock Server sign-in on the home server.**
  - *Signed in:* New Send makes it, and the link sheet shows a link of the form
    `https://<server>/#/send/<22 characters>/<43 characters>`.
  - *No sync:* the page says Sends need Kemlock Server sync, and New Send isn't offered.
  - *On a replica:* refused, with the home's "offline since".
- **The server gets only ciphertext.** No request carries `K`, the payload key, the password or the
  text.
  - *Any Send:* the fake server's log of request URLs, headers and bodies holds no base64url of `K`
    and no byte of the plaintext.
- **The deletion date is required and at most 30 days away. The expiry is optional and no later.**
  - *30 days:* accepted.
  - *Expiry after deletion:* the sheet doesn't offer it.
- **A file Send's bytes go up after it is made, or it is deleted.**
  - *A 3 MB PDF:* the upload is `kma1Length(3 MB)` bytes long, and the Send becomes ready.
  - *Upload fails three times:* the Send is deleted and the sheet says the file didn't go up.
  - *A 60 MB file:* refused before anything is sealed.
- **Policies are the server's to enforce, and the sheet says why.**
  - *"Always show the sender's email":* a Send with Hide my email is refused with the policy's words.
  - *"Remove Send":* New Send is refused with the policy's words; existing Sends can still be
    deleted.
- **A password is sent only as its proof.**
  - *Password "hunter2":* the request's `password` is 43 base64url characters equal to the proof
    vector; "hunter2" appears in no request.

### The owner's list

- **Every Send of the account is listed, with its status.**
  - *A Send with 1 open of 1 used:* "Used up".
  - *A file Send whose upload never finished:* "Waiting for its file", with Delete.
  - *A Send whose meta doesn't open:* "Can't be read on this phone", with Delete only.
- **Copy link works from any row,** with no link stored on the phone.
  - *The page opened on a second phone of the account:* the same link is copied.
- **The owner's view spends no open.**
  - *Viewing a text Send limited to 1 open:* its count stays 0, and a recipient can still open it.
- **Edits keep the key.**
  - *Text changed:* the old link opens the new text.
  - *Password removed:* the link opens with no password.
  - *Turned off:* the link answers "isn't available" until it is turned back on.
- **Delete removes it.**
  - *Deleted:* the link answers "isn't available", and the row is gone.

### Opening a Send

- **No account is needed.**
  - *A phone with no Kemlock Server sync:* a shared link opens the text.
  - *The request:* carries no `Authorization` and no `DPoP` header.
- **A web vault link opens like an app link.**
  - *`https://vault.example.com/#/send/<id>/<key>` from the web vault's Copy:* opens in the app.
  - *A link inside a message's text:* found and opened.
  - *A server under a path, `https://example.com/kemlock/#/send/…`:* the request goes to
    `https://example.com/kemlock/kem/v1/send-access/<id>`.
- **A Bitwarden Send goes to the browser.**
  - *A 22-character key:* `LinkOpener` opens it, and nothing is requested by the app.
- **A password is asked only when the server says so.**
  - *Right password:* the text shows.
  - *Wrong password:* "Wrong password", asked again.
  - *Eleven wrong tries in a minute:* "Too many tries", with the wait.
- **What doesn't open is refused whole.**
  - *A payload sealed for another id or kind:* "This link doesn't open", and nothing is shown.
  - *A payload with an extra field:* refused.
  - *A file whose `fileSize` isn't its payload's `KMA1` length:* refused before the download.
- **A closed Send says only that it is closed.**
  - *Expired, deleted, used up or off:* one message, "This Send isn't available".
- **A file is fetched on Save or Share, and only then counts.**
  - *A file Send limited to 1 open:* the name and size show; Save fetches it and spends the open.
  - *A second Save in the same sheet:* uses the bytes already held, with no second request.
- **A shared link opens the Send sheet.**
  - *A shared Send link:* opens the Send sheet; another shared text is handled as before.
- **A link waits for the vault.**
  - *Shared while locked:* the Send opens after unlocking.

### Security

- **The key is only ever in the fragment.**
  - *Every request of every test:* its URL, headers and body hold no base64url of `K`.
- **Links are never logged.**
  - *A failed open:* the problem names the host and nothing of the link.
  - *`SendLink.toString()`:* "key hidden".
- **The clipboard clears itself.**
  - *Copy link with the 30-second delay:* the clipboard is cleared after 30 seconds unless something
    else was copied.
  - *Copy on a received text:* the same.
- **A received file leaves no plain copy behind.**
  - *Save, then close the sheet:* nothing of the file is under the temporary or cache folders.
  - *The vault locks with a file open:* the bytes are dropped.
- **Files have caps.**
  - *A 60 MB file to send:* refused.
  - *A received file whose payload says 60 MB:* refused before the download, with Open in browser.
  - *A server that sends more than `fileSize`:* the read stops, and nothing is saved.

### Offline mode

- **Offline mode stops every Send request.**
  - *The Sends page:* "Offline mode is on", no request.
  - *A shared link:* no request; "Open in browser" asks first, as every link does in offline mode.
  - *Turned on after a file Send's name shows:* Save makes no request and says offline mode is on.

## Tasks

No task runs a build, a test, CI or `pub get` in a subagent. Each "Verify" names the test that the
single build-and-test pass after merging runs, together with `flutter analyze` and `dart format`, or
a check the owner makes on a device. Run Flutter from `mobile/`. Commits follow `CLAUDE.md`:

- the scope is `send`, which the main session adds to `CLAUDE.md` in a `docs` commit before
  building starts;
- `crypto` for `send.dart`, and `ios` and `android` for the native changes;
- one change per commit, with tests in their own `test(…)` commits after their code;
- the `Assisted-by` footer.

### 1. Groundwork and the contract

- [x] 1.1 ~~Add the `send` scope to `CLAUDE.md`'s list.~~ Not needed: the commits use `share`, `sync`, `crypto`, `ios`, `android`, `i18n` and `docs`, and no scope is added.
- [x] 1.2 Read the Send routes, their bodies, answers and problem slugs again from the server's
  `build/vertical-slice`. Record them in `mobile/test/fixtures/kemlock/README.md` and settle each
  point under "Agreed with the server" that the server has answered. Verify that nothing is left
  marked to confirm in the README or in this plan.
  Done: read at 4f763da (`sends.rs`, `kemlock-app/src/sends`, `kemlock-domain/src/sends.rs`,
  `problem.rs`, `crypto.md`) and recorded in the README with every slug. The byte format matches
  `crypto.md` and `fixtures/server/send.json` is the server's file. Found and fixed: the upload's
  answer was read with 16 KiB, too little for a long meta (26bc5a12); the list failed on a
  Bitwarden API Send, which shares the table (9aead28e); and the fake differed on the 400 slug, an
  edit under a "Remove Send" policy, a note's upload, the 429's wait and the order of the public
  checks, and lacked `sends` in `features`. All seven points under "Agreed with the server" are
  settled. Not modelled in the fake: the file Send quota (`storage-*`), the 411, and a limit lowered
  between make and upload.
- [x] 1.3 Extend `test/features/sync/kemlock/fake_kemlock_server.dart` with the Send routes:
  - the owner's routes, with DPoP;
  - the public routes, with none;
  - the open count (a text on access, a file on download), the password check with 10 wrong tries a
    minute, and the plain 404s;
  - the upload's length and `KMA1` check, and the policy refusals;
  - a log of every request.

  Verify with its own smoke test: a text Send limited to one open answers once, then 404.

### 2. The format

- [x] 2.1 Write `crypto/account/send.dart`: the payload key, proof salt and meta key; the payload and
  meta seals with their aad; the 64-byte `sealedKey` and its version; the strict `SendPayload` and
  `SendMeta` readers. Verify with `test/crypto/account/send_test.dart`. Each of these fails to open:
  a payload under another id or kind, a `sealedKey` under another key version, and a meta opened
  with a key from `K`. An extra JSON field is refused. Sealing twice gives different bytes.
- [x] 2.2 Add `sendProof` over `deriveMasterKey` with the fixed settings. Verify with a fake runner
  that it passes `m = 19456`, `t = 2`, `p = 1` and the 16-byte salt. Also verify that a decomposed
  and a precomposed "é" give one proof, and that another send id gives another salt.
- [x] 2.3 Seal a file Send's bytes with `kma1Encrypt` under the payload key, and check a received
  `fileSize` against `kma1Length`. Verify that a 0-byte, a 65,536-byte and a 3 MB file round-trip,
  and that a size one byte off is refused.
- [x] 2.4 Once the server publishes `test-vectors/send.json`, copy it with
  `tool/server/copy_vectors.sh` and add `test/crypto/server/send_test.dart`. It covers the keys,
  aads, seals, wrap, the proof (from a decomposed password too), the `KMA1` file, the link, and the
  changed ids, kinds, keys and key versions that must not open. Verify in the pass after merging.
  Nothing in `fixtures/server` is edited by hand.

### 3. Links

- [x] 3.1 Write `features/sends/send_link.dart`: `sendLink`, `SendLink.parse` (a whole URL, a URL
  inside text, a path before the `#`), `BitwardenSendLink`, and a `toString` that hides the key.
  Verify with `test/features/sends/send_link_test.dart`. It refuses `http`, padded base64, a 31-byte
  key, a query and user info. It reads a 22-character key as Bitwarden's. It round-trips a link the
  web vault's `sendLink` would write.
- [x] 3.2 Add `test/features/sends/no_link_logging_test.dart`: it fails when a file under
  `lib/features/sends/` or `km_sends_api.dart` calls `print` or `debugPrint`. It also checks that a
  failed open's `KmError` and `SendsProblem` hold no part of the key. Verify that it passes, and
  that it fails on a test-local file that logs a link.

### 4. The client

- [x] 4.1 Write `features/sync/kemlock/km_sends_api.dart`:
  - the owner's routes over `KmApi.call`, with DPoP;
  - the public routes with `proof: false`;
  - `SendsProblem` for `send-password-required`, `send-wrong-password`, `send-policy` (with its
    detail), `file-too-large` (with `maxSize`), 404, 409 and 429.

  Verify against `MockClient`: a public request carries no `Authorization` and no `DPoP`, a 302
  isn't followed, an access answer over 512 KiB is refused, and a download stops at `fileSize`.
- [x] 4.2 Add the recipient's client: the gated client with no pin, https only, through the
  existing client factory. Verify that offline mode refuses it, that an `http` link is refused
  before any request, and that `network_callers_test.dart` still passes with no new allowed file.

### 5. Making a Send

- [x] 5.1 Write `SendsService.make` (design 4) inside `KmHost.withAccount` after `requireHome`:
  sealing, the create, the upload with two retries, the delete after a failed upload, the one
  retry with a new id on 409, and wiping. Verify against the fake server:
  - a text Send and a 3 MB file Send open from the fake's public routes;
  - the request log holds no `K` and no plaintext;
  - three failed uploads leave no Send;
  - on a replica, the make is refused with `KmHomeAway`.
- [x] 5.2 Build `new_send_sheet.dart`: Text or File, Name ("The recipient sees it"), Notes ("Only
  you see these"), Deletes after, Link stops working, Opens, Password and Hide my email. Add the copy
  to `en.json` and `fr.json`. Verify with widget tests: the policy refusal shows the server's words,
  a 60 MB file is refused, and an expiry after the deletion isn't offered. Also verify with
  `test/i18n/messages_test.dart`.
- [x] 5.3 Build `send_link_sheet.dart`: the link, Copy through `secretClipboardProvider`, Share
  through `FileService.shareText`, and the line that anyone with the link can open it. Verify with a
  widget test over a fake `SensitiveClipboard`: Copy goes through it, and the sheet's text field is
  empty after it closes.

### 6. The owner's list

- [x] 6.1 Build `sends_page.dart`, opened from the Vault tab: rows opened from `meta` and
  `sealedKey`, the status of design 5, Copy link, pull to refresh, "Open a Send", and the messages
  for no sync, offline, session ended and home away. Verify with widget tests for each status, the
  unreadable row, and each message.
- [x] 6.2 Add edit and delete: the full `PUT` with meta (and payload for a text) sealed again, the
  password set, changed or removed, the on/off switch, and Delete with its confirmation. Verify
  against the fake: after a text edit the old link opens the new text; after "remove password" it
  opens with none; a turned-off Send answers 404; a deleted one is gone; a 404 on delete counts as
  done.
- [x] 6.3 Add the owner's view of a text Send from the DTO's payload. Verify that the fake's open
  count doesn't change.

### 7. Opening a Send

- [x] 7.1 Add `platform/send_links.dart` (`PendingSendLink`) and route links to it:
  - from `offerSharedItem`, before other shared items are handled;
  - from the paste field.

  The open vault's shell takes it, as it takes `pendingSetupLinkProvider`. Verify with tests:
  - a shared Send link opens the Send sheet;
  - another shared text is handled as before;
  - a link shared while locked opens after unlocking.
- [x] 7.2 Write `SendsService.open` (design 7): the Bitwarden hand-off, the access with and without
  the proof, the checks of the answer, 404 and 429. Verify against the fake:
  - a Send opens with no account and no token;
  - a wrong password is asked again;
  - the eleventh try in a minute waits;
  - a payload sealed for another kind, or with an extra field, shows nothing;
  - a server under a path gets the request at its path.
- [x] 7.3 Build `received_send_sheet.dart`:
  - a text in `SecretSelection` with `secretTextMenu`, Copy and Save as note;
  - a file's name, type and size with Save and Share, fetched once;
  - the sender's email as the server's word;
  - the line that Save spends the open of a limited Send.

  Verify with widget tests: Copy goes through the secret clipboard, Save as note adds a note to the
  open vault, and a second Save makes no second request.
- [x] 7.4 Make the iOS Share extension take an `https` `public.url` attachment as text, in
  `ShareViewController.swift`, in a `feat(ios)` commit. Verify with an XCTest of the type choice in
  CI's macOS job, and on an iPhone: a link shared from Safari and from Messages opens in Kemlock.

### 8. Files

- [x] 8.1 Apply the caps of design 8: 50 MiB to make, a received payload over 50 MiB refused before
  the download with Open in browser, and the server's 413 `maxSize` shown. Verify with tests at 50
  MiB and at 50 MiB plus one byte, both ways.
- [x] 8.2 Keep a received file in memory, save and share it through `FileService`, and zero it when
  the sheet closes or the vault locks. Check that a copy under `<temporary>/share/<random>/` left by
  a killed app is swept at start, and add the sweep if it isn't. Verify with a test over a real
  temporary folder: after Save and close, no file is left under it; after a simulated kill, the
  start-up sweep removes it.
  Checked: `PendingShare.sweep` runs at start and when the app returns to the front and deletes anything under
  `share/` older than ten minutes, `share/<random>/` included, so no new sweep was added. The test covers
  `sweepSharedFiles`; the share step's own cleanup after the sheet closes is `files.dart`'s `_remove`, which a phone checks.

### 9. From an item (assumes decision 3 (b))

- [x] 9.1 Add "Send" to a login's password menu (`login_sheet.dart`) and to a note's menu
  (`note_page.dart`), behind `ownerCheckProvider`. Each opens the New Send sheet with the text and
  the item's name filled in. Verify with widget tests: the owner check comes first, a refused check
  opens nothing, and the Send isn't linked to the item.

### 10. Offline mode, failover and policies

- [x] 10.1 Check that every Send request passes `NetworkGate`, and show offline mode on the page,
  New Send, the paste field and a shared link. Verify with offline-mode tests for each: no request
  is made, and "Open in browser" goes through `LinkOpener`'s prompt.
- [x] 10.2 Refuse making, listing and editing on a replica, and show the home away on the page.
  Verify with `km_host_failover_test.dart`-style tests: on a replica, nothing is sent to it, and
  opening a link still works.

### 11. End to end and the README

- [ ] 11.1 Add `test/kemlock_server/sends_test.dart`, run only when `KEMLOCK_URL` is set, as
  `sync_test.dart` is. It makes a text Send with a password and an open limit of 1, opens it from a
  second client with no session, and finds it closed after. It also makes a 3 MB file Send, opens
  it and checks its bytes. Verify by one run against the server's development build, made by the
  main session after merging, and record it here. (Code done; verify by a run: `mobile/test/kemlock_server/sends_test.dart` signs in with the master password of `server_kit.dart`, makes a text Send with a password and one open, finds the password asked for and a wrong one refused, opens it from a client with no session, finds it closed after (`notFound`) and listed as used up, and makes a 3 MB file Send, opens it and compares the downloaded bytes. It deletes what it makes. The server must be https. Not run here, so the result is for the main session to record under this task.)
- [ ] 11.2 On an iPhone and an Android phone, check these, and record what passed here:
  - sharing a link to Kemlock from Messages, Safari and Chrome;
  - pasting a web vault link;
  - saving a received file to Files;
  - the clipboard clearing after Copy link.

  Where no phone is at hand, leave a "Not done:" note saying what was checked instead.
- [x] 11.3 Describe Sends in the README's Kemlock Server section: what the server sees, where the
  key goes, the proof, and that nothing is stored on the phone. Verify that it names
  `crypto.md` "Sends".

## Agreed with the server

The server session's answers, read from its code at 4f763da of `build/vertical-slice` in task 1.2
and recorded in `mobile/test/fixtures/kemlock/README.md`. Each point is settled:

- **`test-vectors/send.json`.** Published. `mobile/test/fixtures/server/send.json` is the same file
  (task 2.4).
- **The meta comment.** `CreateSendRequest.meta` in `sends.rs` now says the meta key is HKDF of the
  owner's item-wrap child key, the Send id and the key version, never the link key.
- **The recipient page.** The web vault has it: `web/src/app/Root.tsx` shows `SendAccess` for a
  `#/send/<accessId>/<key>` hash. Someone without Kemlock can open a Send.
- **Telling clients about Sends.** `/kem/v1/config` lists `sends` in `features`. It doesn't give
  `max_file_size`, so the sheet learns the limit from the 413 `file-too-large` and its `maxSize`.
  The app doesn't gate New Send on the feature: a server without the routes answers 404.
- **Bitwarden links.** The server never sees a key, so it can't promise anything about its length.
  `crypto.md` gives a Kemlock Send a 32-byte key (43 characters) and Bitwarden's is 16 bytes (22),
  and the client tells them apart by it. The Bitwarden API's Sends share the table and come back in
  `GET /kem/v1/sends` with a `sealedKey` that isn't 64 bytes; the client lists those as Sends made in
  a Bitwarden app, to see and delete, and decrypts none of them (design 5).
- **The 429 answer.** It carries `retryAfter` and `Retry-After`: 1 second after the tenth try, then
  doubling.
- **Lost opens.** The rule is the server's: a text Send's open is counted before the answer is
  sent, and `sends/mod.rs` says so. There is no second step. The app accepts that a dropped
  connection can spend one.

## Dependencies

- `docs/plans/add-account-crypto.md` provides the item-wrap key, HKDF, the encoding, the Argon2id
  seam and the server-vector script. Group 2 needs its groups 1, 2 and 7.
- `docs/plans/add-kemlock-server-sync.md` provides `KmApi` and its limits, `KmHost.withAccount`
  and `requireHome`, the gated client factory, the fake server, the session's messages, and
  its decision 1 (no gate). Groups 4 to 6 need its groups 3, 5 and 10.
- `docs/plans/add-server-spaces.md` adds the space policies whose refusals the New Send sheet shows.
  This plan doesn't wait for it: the server enforces them.
- From the history before 5ba88b42:
  - `add-share-extension`: the hand-over and the share filters;
  - `add-offline-mode`: the gate and `LinkOpener`'s prompt;
  - `harden-unlock-and-clipboard`: the secret clipboard and the owner check;
  - `add-pgp-messages`: the pattern of a temporary job folder swept at start;
  - `add-cloud-drive-sync`: sync on every backend, which includes Sends.
- The server: `docs/crypto.md` "Sends" and `crates/kemlock-api-kem/src/routes/sends.rs` on
  `build/vertical-slice`, and `test-vectors/send.json`.
