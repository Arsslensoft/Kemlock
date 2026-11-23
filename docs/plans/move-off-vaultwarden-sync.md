# Moving off Vaultwarden sync

At its first sign-in to Kemlock Server's own API, a phone moves the vault's own entries from
Vaultwarden or WebDAV sync into `kem1` items, and loses none of them on the way. Phones, Amethystora
Vault and Bitwarden apps that haven't moved keep working. A plain home's items stay in sync as a
Bitwarden copy for as long as any device of the account still uses the Bitwarden API.

## Why

Kemlock Server answers the Bitwarden API that Kemlock's Vaultwarden sync uses today, and it also
serves its own Kemlock API (`/kem/v1`). That API carries every Kemlock kind as a `kem1` item, logins
and accounts on a security key included. When someone first signs in to the Kemlock API
(`docs/plans/add-kemlock-server-sync.md`), the phone has to move the vault's own entries off the old
sync without losing any of them. Everyone who hasn't moved has to keep working meanwhile.

The server design's section "Moving a Kemlock user off Vaultwarden sync" sets the steps. The owner's
decision "Plain home copies" (21 November 2026) sets how long a plain home's Bitwarden copy stays.

## What changes

- **A move at the first Kemlock API sign-in.** The phone runs one last sync with the old store.
  It then writes each of the vault's own entries as a `kem1` item through `items:batch`. A UUID id
  stays the item id. Any other id, such as 0.1.0's `acc-1`, becomes the UUID that `crypto.md`'s
  "Legacy ids" gives, and the entry keeps its own id inside. It uploads every note's `KMA1` file,
  signs one manifest after the last batch, and reads the result back through `/kem/v1/sync`. It
  compares every id and every entry's hash before it changes anything in the old store. Nothing
  is deleted, and nothing goes to the trash before that check passes.
- **Two sources:**
  - A Vaultwarden home on the same server, sealed or plain.
  - A WebDAV personal vault. This goes beyond "Vaultwarden" in the title, since the server design
    moves WebDAV users the same way. The phone merges `backmycodes-sync.json` once and then stops
    writing it. The file, its `backmycodes-file-*` files and every space and invite stay exactly as
    they are, for phones that haven't moved. WebDAV spaces move in `docs/plans/add-server-spaces.md`.
- **A sealed home is closed.** Its home note goes to the trash first, then its sealed items. Phones
  still on Vaultwarden sync then stop with "home gone" (`vw_sync.dart`, step 2) and change nothing.
  A home holding an item this phone can't read is not closed.
- **A plain home's items stay, as a Bitwarden copy.** Amethystora Vault and Bitwarden apps read
  them, and trashing them would make Amethystora trash its own copies. The moved phone keeps syncing
  them, with today's code, beside the Kemlock API. Once the server's device list shows no device of
  the account on the Bitwarden API for 30 days, the app offers to remove the copy.
- **The move resumes.** Its progress is kept, sealed, in the vault store, so a move that is killed,
  offline or refused picks up where it stopped. Ids are made on the client, so a batch is sent
  again unchanged.
- **Screens:**
  - Before anything is written, a screen says what moves and what stays.
  - While the move runs, progress is shown by step; afterwards, the result is shown with counts.
  - A phone still on Vaultwarden sync whose home another phone closed sees "This vault moved to
    Kemlock Server", with a sign-in button, when `/api/config` shows the Kemlock API.
- **Staying on Vaultwarden.** Vaultwarden sync keeps writing byte for byte what
  `mobile/test/fixtures/vaultwarden/formats.json` and `vault-items.json` pin. WebDAV sync keeps
  writing what `mobile/test/fixtures/sync` and `vault-items` pin. The existing fixture tests prove
  both, run unchanged.

Out of scope:

- The Kemlock API client, sign-in, tokens, the sync cursor and the device list
  (`docs/plans/add-kemlock-server-sync.md`).
- The `kem1` item and manifest crypto (`docs/plans/add-account-crypto.md`). This plan calls both.
- Moving WebDAV spaces and `bmc-space:` invites to server spaces (`docs/plans/add-server-spaces.md`).
- Turning an account Kemlock only. That is an account setting on the server; the removal offer here
  only links to it.
- Moving from a Vaultwarden on another address than the Kemlock Server. The phone has no access to
  the old store through the new server, so the person keeps both syncs or turns the old one off.
- The `SyncSettings` invariant and the `/api/config` discovery. Both are owned by
  `docs/plans/add-kemlock-server-sync.md` (its tasks 2.1 and 12.2), and this plan uses them.
- Gating: none. The move adds no gate of its own, and sync is free.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

The tasks assume the recommended answer of each. Another answer changes only the task named.

1. **What happens to a WebDAV file after the move?**
   - (a) Stop writing it, as the server design says. Other phones on that file keep working but
     stop seeing this phone's changes until they move too.
   - (b) Keep syncing it beside the Kemlock API until the person turns it off. This costs little
     (Design 7's mechanism), but the vault then lives in two places.

   Recommended: (a). Task 5.3 assumes it.
2. **Offer "Go back to Vaultwarden" for 30 days after a sealed home is closed?**
   - (a) Yes: restore the home note and items from the Bitwarden trash, and turn the Kemlock API
     off for the vault's own entries.
   - (b) No: leave restoring to the Bitwarden web vault's trash.

   Recommended: (a). Task 4.4 assumes it.
3. **Close a sealed home while other devices still use the Bitwarden API?**
   - (a) Close it at once, as the server design says, after naming those devices on the move
     screen. They stop at "home gone" and are offered the move.
   - (b) Keep it as a sealed copy until no device uses the Bitwarden API, as a plain home is kept.

   Recommended: (a). Task 4.2 assumes it.

## Design

What shapes the approach:

- **One store syncs the vault's own entries today.** `SyncSettings` holds `personal` (WebDAV) or
  `vaultwarden`, never both (`lib/features/sync/sync.dart`); spaces sync through WebDAV beside
  either. The Kemlock Server sync plan adds a Kemlock Server target for the vault's own entries.
- **Vaultwarden sync is hardened.**
  - `VaultwardenScopeSync` (`vw_sync.dart`) reads the vault, claims the home's items, merges with
    `mergeScope`, and writes item by item with `lastKnownRevisionDate`.
  - Its removal guard counts losses over a day (`lostLately`, the November audit's finding 7), and
    the reader refuses values without a MAC (60104e2f, finding 1).
  - It never holds logins or accounts on a security key: `_keepOnKey` keeps them on the phone.
  - A plain home holds back kinds the person hasn't agreed to have written in the clear
    (`plainKinds`), and entries too long for an item's notes.
  - Linked logins are the person's own: Kemlock owns only their code and its `Kemlock` field
    (`EntryClaim.own == false`).
- **Files are already on the phone as `KMA1`.**
  - The attachment store keeps each note's file as its `KMA1` bytes.
  - A sealed home uploads those bytes; a plain home uploads the plain file, under Bitwarden's
    attachment key; WebDAV keeps `backmycodes-file-<id>` as the `KMA1` bytes.
  - Each old sync already downloads what the phone lacks (`vw_file_sync.dart` step 3,
    `attachment_sync.dart` step 5).
- **`VaultwardenBackend.removeFromVault`** trashes Kemlock's own items, unlinks codes from the
  person's logins, and trashes the home note last.
- **Ids.** New entries get v4 UUIDs (`core/ids.dart`). Vaults from 0.1.0 carry ids such as `acc-1`
  (`test/fixtures/legacy-v0.1.0.json`), and others carry 16-hex ids. On the Kemlock API every item
  id is a UUID: `crypto.md` "Legacy ids" maps any other id under its owner, through
  `add-account-crypto`'s `legacy_ids.dart`. The entry's JSON keeps its own id, and the merge pairs
  copies by it.
- **Planned move of code.** The add-browser-extension change (tasks 2.3 and 2.4) moves
  `lib/models`, the sync merge and the Vaultwarden engine into `packages/kemlock_core`. The move's
  logic is written without Flutter, so it moves with them.

Goals: no entry or file is lost on any path (killed, refused, offline, two phones at once, an item
the phone can't read). The released formats stay untouched, with nothing new written into a
Vaultwarden item or a WebDAV file. New sync code stays small: the old engines run as today, and the
move only orchestrates them. Not goals: a converter from `bw` items to `kem1` that bypasses the
phone's vault, and moving several vaults in one step; each vault moves at its own sign-in.

1. **The move syncs the old store once, then uploads the vault.**
   - The move first runs the old engine's ordinary run, `VaultwardenScopeSync` or the WebDAV
     personal run, with files. Then it uploads the vault's own entries from the phone.
   - The server design says "read the home through `/api/sync` and open each entry". The ordinary
     run does exactly that, with the MAC checks, duplicate rules, removal guard, `combineKeyCopies`
     and file downloads already tested.
   - Weighed: translating each `bw` item straight to `kem1`. Rejected: it skips the merge with this
     phone's unsynced edits, and needs a second decoder held to the same fixtures.
2. **Every own entry moves, of every kind the Kemlock API carries.**
   - The source set is the vault's own lists after the last sync, not the home's items. Logins,
     accounts on a security key, plain-held entries (`paused`) and too-long entries all move.
   - The kind list is the Kemlock Server sync plan's, so a kind added later moves with no code
     here.
   - Batches hold at most 500 items, in kind order: accounts, backup codes, keys, accounts on a
     key, notes, passkeys, contacts, cards, identities, logins. A login's `accountId` then never
     points at an item a stopped move hasn't sent.
   - Each item's id is the entry's id when it is a UUID, else its legacy-id UUID under the user's
     owner. The mapping is fixed, so a resent batch and a second phone moving the same vault send
     the same UUIDs.
   - Duplicate tags: if `docs/plans/add-duplicate-cleaner.md` has landed, its cache tags the moved
     items on the device as it tags any change (its task 3.2). With server matching on, the copy
     step's batches go through that plan's tag provider (its task 7.1), so `cred` tags travel with
     the move's writes. If the cleaner hasn't landed, nothing is tagged here, and its backfill tags
     the items later.
3. **A resend creates only what is absent, then compares, then merges.**
   - A first write asks the server to create the item only if no item has that id: a batch write
     with `expectedRevision: null` (or `If-None-Match: *` on `PUT`). An id that exists is a 409
     `stale-revision` naming `currentRevision`, and a batch is all or none, so the phone reads the
     vault through `GET /sync` and decides each item before it sends.
   - When the item exists, the phone reads it, decrypts it and compares the canonical JSON. If they
     are equal, the item is done. If they differ, another device moved first: the phone merges the
     single entry with `mergeScope` and writes the merge with `If-Match` on the read revision.
   - This covers both a resend after a crash and two phones moving at once.
   - Weighed: a `PUT` without a precondition. Rejected: it overwrites the first phone's newer
     field.
4. **The check reads everything back.**
   - After the last batch and the files, the phone signs one manifest for the user's owner, as
     `add-account-crypto` design 6 requires after a move. The check then reads `/kem/v1/sync` from
     an empty cursor and decrypts each item with the account crypto plan's item code.
   - It compares each entry's `sha256(canonical(toJson()))` with the hash recorded when the entry
     was sent. It also checks that the signed manifest it just sent lists every moved id at its
     revision, and that the server returns that manifest.
   - The server reports no size or SHA-256 for a file (task 1.1), so the phone downloads each moved
     file and compares its SHA-256 with the one it recorded, or opens it with its key when another
     phone uploaded it.
   - The sent hashes are kept in the progress record, so a check after a restart needs no
     recomputation. A local edit made after the copy is not a mismatch: it goes up at the first
     Kemlock API sync.
5. **Progress lives in one sealed record, `backmycodes_kemlock_move`.**
   - It is sealed with `saveEncryptedValue` like the sync settings, and deleted with its vault by
     suffix (`VaultRegistry.removeVaultData`):

     ```json
     {"v":1,"source":"vaultwarden","server":"https://vault.example.com","home":"<home id>","mode":"sealed",
      "step":"copy","sent":{"<id>":"<sha256 b64>"},"files":{"<attachment id>":"<sha256 b64>"},
      "checked":false,"closed":false,"startedAt":1795300000000}
     ```

   - The steps are `sync`, `copy`, `files`, `check`, `oldStore` and `done`. Each step is
     idempotent, so a resume restarts the recorded step.
   - After `done`, the record stays for Design 9's window, then is trimmed to
     `{v, source, done, finishedAt}`.
   - While a move is unfinished, the scheduler runs no sync of the vault's own entries. Spaces keep
     syncing, and edits on the phone wait for the first Kemlock API sync.
6. **A sealed home is closed home note first.**
   - A new `VaultwardenBackend.closeHome` trashes the home note, then the sealed items the check
     confirmed, then unlinks codes from the person's own logins in the home.
   - Home first means a phone on Vaultwarden sync running at that moment stops at "home gone"
     before it can count missing items as deletions. Items first, as `removeFromVault` does today,
     would let that run tombstone them on that phone.
   - `removeFromVault` takes the same order; its tests change only in the order of calls.
   - An item the phone can't read (`unreadable` or `protected` in `_plan`) blocks the close. The
     home then keeps syncing beside the Kemlock API, as a plain copy does, and the result says why.
7. **After a plain home's move, the existing Vaultwarden scope keeps running.**
   - `SyncSettings.vaultwarden` stays set beside `SyncSettings.kemlock`, and the scheduler runs both.
     Each run merges into the phone's vault, and the phone's edits go out through both.
   - The rule is the Kemlock Server sync plan's `SyncSettings` invariant (its design 2 and task
     2.1): at most one of WebDAV and the Kemlock target syncs the vault's own entries.
     `vaultwarden` may sit beside the Kemlock target only after a move, marked as a copy in the
     `vaultwarden` scope's state under `copyOfKey` (`'copyOf'`, `sync.dart`), never in any item.
     This plan relies on it and adds nothing to it.
   - `_keepOnKey` already keeps logins and accounts on a key out of the copy.
   - After a downgrade, an older build sees `vaultwarden` and syncs the plain home as before. It
     keeps the Kemlock target among its unknown keys.
8. **The app reads the device list to see who still uses the Bitwarden API.**
   - The Kemlock Server sync plan registers the phone on the Kemlock API with the same device
     identifier as its Vaultwarden session (`VwCredentials.deviceId`), sent as the sign-in device's
     `bitwardenDeviceIdentifier`, so the server shows one device for both.
   - The rule runs in the app: a device counts when its last Bitwarden API use is within 30 days
     and it has no Kemlock API use. Moved Kemlock phones that keep the copy don't count.
   - The app checks at most once a day and whenever Settings › Sync opens.
   - The server gives, per device, its `name`, `kind`, `lastBitwardenUseAt` and
     `lastKemlockUseAt` (`GET /kem/v1/devices`, read by `KmAuthApi.devices`). It gives no client
     name; `kind` stands for it.
9. **"Go back to Vaultwarden" is offered for 30 days** (owner decision 2).
   - The phone restores the home note and the sealed items from the Bitwarden trash
     (`restoreCipher`) and turns the Kemlock target off for the vault's own entries.
   - The `kem1` items stay, and nothing is deleted. This is cheap because the close only trashed.
10. **A WebDAV file is synced once, then left alone** (owner decision 1).
    - After the check, `SyncSettings.personal` is set to null and the folder is left as it is.
    - Phones that move later merge in by id, and nothing is lost.
    - Weighed: keeping the WebDAV scope running beside the Kemlock API (cheap, but the vault then
      lives in two places).
11. **A closed home points to the move.**
    - When `VwSyncIssue.homeMissing` stops a run, the phone reads `/api/config`, already fetched for
      SSH key items, through the Kemlock Server sync plan's discovery check (its task 12.2).
    - With the `kemlock` member present (`KemlockOffer.fromConfig`), the problem line becomes "This vault moved to Kemlock Server",
      with Sign in. Without it, today's message stays.

Risks and how the plan meets them:

- **A server passes the check, then drops items.** The close only trashes, so Design 9 restores
  the home. The signed manifest shows later loss or rollback as tampering.
- **Phones on a closed sealed home stop syncing.** The move screen names them first. Their sync
  stops at "home gone" and changes nothing; Design 11 offers them the move, and they merge in by id.
- **An item of a newer kind is trashed with the home.** That can't happen: unreadable items block
  the close.
- **WebDAV phones drift from moved ones.** The move screen says so. A phone that moves more than
  180 days later can bring back entries deleted on the server, the same limit WebDAV tombstones
  have today.
- **A large vault takes long.** The move resumes per batch and per file. Files stream from the
  attachment store, and only counts are held in memory.
- **Ids from 0.1.0 aren't UUIDs.** They travel as their legacy-id UUIDs, and the entries keep
  their ids, so nothing on the phone or in the old stores changes. Task 8.2 moves
  `legacy-v0.1.0.json`'s vault. Because the owner is part of the mapping, such an entry moved
  later from the vault into a space gets a new UUID: the server sees a delete and a create, and
  the phone pairs the two by the original id.
- **The removal guard at the first Kemlock sync.** The Kemlock scope's `known` ids start as the
  checked set, so nothing counts as removed.
- **Two moved phones both run the plain copy.** Both write with `lastKnownRevisionDate` and
  `If-Match`, and a stale write retries the merge, as today.

Rollout and rollback:

- Nothing changes until a person signs in to the Kemlock API, and declining keeps everything as it
  was. Design 9 lets a person roll back for 30 days.
- An older build ignores `backmycodes_kemlock_move` and the Kemlock target as unknown keys. It
  syncs a plain copy's home as before, and sees sync off after a sealed move. Its entries stay on
  the phone.

Still open, and safe to settle later:

- The move screens' wording. No mockup of them is on the canvas yet.
- Whether the server's file route will report a SHA-256 later. It doesn't today (task 1.1), so Design
  4's download fallback is the only path; a hash would only replace the download.

## Behaviour

### Starting the move

- **The move is offered at the first Kemlock API sign-in.** This applies to a vault that syncs its
  own entries with Vaultwarden or WebDAV, at its first successful sign-in to the Kemlock API. The
  move screen shows before the Kemlock API's first sync, and nothing is written to either server
  before the person confirms. Declining keeps the old sync and leaves the Kemlock API off for the
  vault's own entries.
  - A sealed home on vault.example.com, at the first Kemlock API sign-in there: the move screen
    opens, and the server holds no `kem1` item of the vault yet.
  - The person taps Not now: Vaultwarden sync goes on, and nothing is written through the Kemlock
    API.
  - A vault that synced nowhere signs in: there is no move screen, and the first sync uploads the
    vault as for any new vault.
- **The move screen says what moves and what stays.** It shows:
  - the entries that move, by kind, and how many files;
  - what happens to the old store: a sealed home is closed, a plain home stays as a Bitwarden copy,
    and a WebDAV file stays as it is;
  - the account's devices still on the Bitwarden API, by name.

  Scenarios:
  - A sealed home of 40 codes and 3 notes with 2 files, and a "Pixel" that used the Bitwarden API
    yesterday: the screen lists 40 codes, 3 notes and 2 files. It says the home will be closed, and
    that "Pixel" stops syncing until it moves.
  - A plain home: the screen says its items stay in Vaultwarden for Bitwarden apps and Amethystora,
    and that this phone keeps them in sync.

### The copy and the check

- **The old store is synced once before the copy.** That ordinary run, files included, is merged
  into the vault first. If it stops (removal guard, home gone, network, wrong key), the move stops
  with that problem before copying anything.
  - Another phone added "Orbit" after this phone's last sync: "Orbit" moves too.
  - The last sync would remove more than a quarter of the entries: the move stops and asks the
    guard's question, as a sync does.
- **Each entry becomes a `kem1` item.** A UUID id stays the item id; any other id is mapped to its
  legacy-id UUID, and the entry keeps its own id inside. Every kind the Kemlock API carries moves,
  including entries Vaultwarden never held: logins, accounts on a security key, cards, identities,
  and entries a plain home held back. Batches hold at most 500 items, in kind order. One manifest
  is signed after the last batch.
  - A 0.1.0 account with the id `acc-1`: the server holds a `kem1` item under the UUID the
    server's legacy-id vector gives, whose entry still has the id `acc-1`.
  - 12 logins that Vaultwarden sync never wrote become 12 `kem1` items.
  - 2 keys a plain home held back become `kem1` items, encrypted like any other.
- **Every note's file moves as its `KMA1` bytes.** A file the phone lacks is first fetched by the
  last sync. The move doesn't reach the check while a named file is neither on the phone nor on the
  Kemlock API.
  - A file a plain home keeps as the plain file: the Kemlock API holds the phone's `KMA1` bytes.
  - A file nobody can supply: the move stops with "A file is missing", names the note, and changes
    nothing in the old store.
- **Nothing changes in the old store before the check passes.** The vault is read back from the
  start. Each item's id and entry hash, and each file's size and hash, must match what was sent. A
  difference or a missing item stops the move, and the next attempt resends what differs.
  - One of 43 items is missing on read-back: nothing is closed, and the next attempt resends it.
  - Everything matches: the move goes on to the old store.

### The old store

- **A sealed home is closed home note first.** After the check, the home note is trashed, then each
  moved sealed item, and codes are unlinked from the person's own logins in the home. Nothing is
  deleted for good. A home holding an item the phone can't read isn't closed: the move finishes,
  the home keeps syncing, and the result says why.
  - A phone still on that home syncs after the close: it stops at home-missing and changes nothing.
  - A sealed item of a kind this build can't read: the home stays open, Vaultwarden sync stays on
    beside the Kemlock API, and the result says one item needs a newer Kemlock.
- **A WebDAV file stays as it is.** After the check, this phone stops syncing the vault's own
  entries with WebDAV. It never changes, writes or deletes `backmycodes-sync.json` or any
  `backmycodes-file-*` file, and its spaces keep syncing.
  - After the move, every file in the folder keeps its bytes and dates, and spaces still sync.
  - Another phone on the same file keeps reading and writing it as before. This phone no longer
    sees its changes until it moves too.
- **A phone whose home was closed is pointed to the move.** When a sync stops because the home is
  gone and `/api/config` shows the Kemlock API, the phone says "This vault moved to Kemlock Server"
  with a sign-in button; otherwise it shows today's problem.
  - The second phone signs in: its entries merge in by id, and nothing is duplicated.

### Resuming and screens

- **The move resumes where it stopped.** Its progress is kept sealed with the vault: the source,
  the step reached, the items and files confirmed, and the check. The move resumes at the next
  opening of the vault or at Try again. A batch sent again makes no second item. An item already on
  the server with other values is merged field by field, never overwritten.
  - Closed after 300 of 900 items and opened again: the other 600 go up, and none is sent twice.
  - Two phones move one home at once. The second finds an item with an older value of one field: it
    merges, writes with `If-Match`, and no edit is lost.
- **The move shows its progress and result.** The step being run is shown with counts: sync, copy,
  files, check, old store. The result shows what moved by kind, what happened to the old store, and
  what was left with its reason. Leaving the screen doesn't stop the move.
  - A plain home's result lists the items by kind and the files, and says the Bitwarden copy stays
    in sync.

### The Bitwarden copy

- **A plain home's items stay and keep syncing.** The home note and every item stay. The home
  syncs through the Bitwarden API beside the Kemlock API, with today's merge and item formats.
  Edits flow both ways: from a Bitwarden app, Amethystora or an unmoved phone to the `kem1` items,
  and from moved devices to the plain items.
  - The person renames "Orbit" to "Orbit Cloud" in the Bitwarden app: after the next sync, the
    `kem1` item and the phone show "Orbit Cloud".
  - An issuer is changed on the moved phone: the next sync writes it to the `kem1` item and to the
    plain item, which keeps every field Kemlock doesn't own.
  - After the move, no plain item is trashed, and Amethystora trashes nothing.
- **The copy holds what it held.** It keeps the plain home's entries under the same rules: kinds
  agreed to plain, the length limit and SSH key items. Logins and other entries Vaultwarden sync
  never wrote aren't added.
  - 12 logins make no plain item.
- **The device list decides whether the copy is needed.** A device still uses the Bitwarden API
  when it used it within 30 days and has never signed in to the Kemlock API. Moved Kemlock phones
  don't count.
  - Amethystora used yesterday: the copy is needed, and Settings › Sync names it as the reason.
  - Only moved phones, and nothing else in 30 days: the copy isn't needed.
- **Removing the copy is offered after 30 days without a device.** Settings › Sync offers the
  removal and says which items it trashes and that older builds then stop syncing. On confirmation,
  Kemlock's own plain items and the home note are trashed, codes come off the person's logins with
  their other fields unchanged, and the home stops syncing. The copy is never removed without that
  confirmation.
  - At 31 days, a card offers the removal, and Vaultwarden is unchanged.
  - After the person confirms, the person's logins keep usernames, passwords and websites, and the
    `kem1` items are unchanged.
  - A Bitwarden app syncs again before the person confirms: the offer is withdrawn, and the copy
    keeps syncing.
- **The copy's problems don't stop the Kemlock API.** A failed copy run (session ended, home gone,
  removal guard) shows on the copy's own line and never stops or rolls back the Kemlock API's sync.
  A copy whose home note is gone stops syncing that home and changes nothing in it.
  - The Bitwarden API refuses the session: the Kemlock API keeps syncing, and the copy's line asks
    to sign in again.

### Staying on the old sync

- **Staying writes what it always wrote.** Vaultwarden and WebDAV sync stay for vaults that don't
  move, byte for byte as the released fixtures pin them. The move adds no field, key or file to
  either store.
  - The Vaultwarden format tests over `formats.json` and `vault-items.json` pass unchanged.
  - The WebDAV fixture tests over `test/fixtures/sync` and `test/fixtures/vault-items` pass
    unchanged.

## Tasks

### 1. Contract with the server

Coding agents don't run builds, tests, CI or `pub get`. Each "Verify" names the test that the single
build-and-test pass after merging runs, or a check the main session or the owner makes after merging.
The commit scope is `sync`, added to `CLAUDE.md` by the main session before building starts.

- [x] 1.1 Once `../kemlock-server`'s OpenAPI spec exists, find or request what the move needs (item
  ids are UUIDs, with older ids mapped on the phone by `crypto.md` "Legacy ids", so no string ids):
  - a create-if-absent op in `items:batch`, or `If-None-Match: *` on `PUT`;
  - a stored file's size and SHA-256;
  - each device's last Bitwarden API and Kemlock API use, as one device when the app sends its
    Vaultwarden device identifier.

  Verify by naming each operation and field in Design 3, 4 and 8.

  Read from the server's `build/vertical-slice` (`routes/items.rs`, `routes/files.rs`,
  `routes/contract.rs`, `dto.rs`), 22 November 2026:
  - **Create-if-absent: served, both ways.** `PUT /kem/v1/items/{id}` takes `If-None-Match: *`
    (201), and a batch write whose `expectedRevision` is null is a new item (`If-Match: <n>`
    and `expectedRevision: <n>` replace). An id that exists is a 409 `stale-revision` naming
    `itemId` and `currentRevision`, the whole batch refused (all or none); an id that is
    another owner's is a 409 `already-exists`. A tombstone counts as existing, so a create over
    one is also a 409. The server has no `GET /items/{id}`, so the phone reads an item through
    `GET /sync`. `KmApi.batch` and `FakeKemlockServer` already do all of this; nothing is built.
  - **A file's size and SHA-256: not served.** `FileDto` is `{fileId, itemId, size, status}`,
    and there is no listing route; a file is reached by `GET /items/{id}/files/{fileId}` and
    nothing else. The size is the one announced at upload. Design 4's download fallback is
    therefore the only path: the phone downloads each moved file and compares its SHA-256 with
    the one it recorded, or, for a file another phone uploaded, opens it with its key. The fake
    server matches the real one and reports no hash, so nothing is built there either.
  - **Device list: served, with one gap.** `GET /kem/v1/devices` answers `{devices: [{id,
    name, kind, createdAt, lastSeenAt, lastKemlockUseAt, lastBitwardenUseAt, current, trusted}]}`;
    both uses are absent when there was none. The sign-in's device body takes
    `bitwardenDeviceIdentifier` (1 to 256 bytes, exactly as the Bitwarden API got it), and the
    device then has the id the Bitwarden API makes from it, so one phone is one device on both
    APIs. `KmDevice` reads all of it. The gap: there is no "client name", only `kind`
    (`kemlock-android`, `kemlock-ios`, `amethystora`, `bitwarden`, ...). The move screen and
    the removal offer name a device by its `name` and `kind`; this plan needs nothing more.
- [x] 1.2 Agree with `docs/plans/add-kemlock-server-sync.md` on three names: the Kemlock target's
  place in `SyncSettings`, the `/api/config` flag, and the device registration's identifier.
  Verify by updating Design 7, 8 and 11 to those names. (The names are `SyncSettings.kemlock`, the
  `kemlock` member of `/api/config`, and `bitwardenDeviceIdentifier`; Design 7, 8 and 11 now
  use them.)

### 2. The move's plan and progress

- [x] 2.1 Add the progress record `backmycodes_kemlock_move` (Design 5). It keeps unknown keys, is
  sealed with `saveEncryptedValue`, and is deleted with its vault by suffix. Verify with a unit
  test that it round-trips, keeps unknown keys, and is removed by `VaultRegistry.removeVaultData`,
  and that `test/vault/unknown_sealed_value_test.dart` lists the key.
- [x] 2.2 Add the plan: every own entry of the kinds the Kemlock API carries, in batches of at most
  500 in kind order (cards and identities included), each with its item UUID (the entry's id or its
  legacy-id UUID) and `sha256(canonical(toJson()))`. Verify with unit tests:
  - 1,201 entries give 3 batches;
  - a login comes after its linked account;
  - logins, accounts on a key, cards, identities, and held-back and too-long entries are in the
    plan;
  - `acc-1` gets the server's legacy-id vector UUID, and a UUID id is left as it is.

### 3. Copy, files and check

- [x] 3.1 The sync step runs the old engine's ordinary run with files, and stops the move with that
  run's `SyncProblem`. Verify with `fake_vaultwarden.dart` and `fake_webdav.dart` that another
  device's new entry is in the plan, and that the guard's stop leaves the Kemlock API untouched.
- [x] 3.2 The copy step creates only absent items, compares and merges (Design 3), and records each
  sent hash once the server confirms it. Verify with the Kemlock Server sync plan's fake API:
  - a batch sent twice leaves one item per id;
  - an equal existing item is skipped;
  - an older field is merged and written with `If-Match`.
- [x] 3.3 The files step uploads each moved note's `KMA1` bytes from the attachment store, or stops
  with "A file is missing". Verify that a plain home's file arrives as the phone's `KMA1` bytes,
  byte for byte, and that a missing file stops the move before the check.
- [x] 3.4 The check step (Design 4) signs one manifest after the last batch and the files, then
  reads `/kem/v1/sync` from an empty cursor and compares ids, hashes, the manifest and the files,
  with the download fallback. Verify:
  - exactly one manifest is sent, after the last batch;
  - one missing item stops the move and is resent next time;
  - one changed byte fails the check;
  - a local edit after the copy is no mismatch.
- [x] 3.5 Resuming: start from the recorded step at vault open and at Try again, and pause the
  vault's own sync while a move is unfinished. Verify with a test that kills the runner after each
  step and resumes it to the same server state, and a scheduler test that spaces still sync.

### 4. The old store

- [x] 4.1 Add `VaultwardenBackend.closeHome`, home note first (Design 6), and give
  `removeFromVault` the same order. Verify that a second phone syncing after the close stops at
  home-missing and changes nothing, and that the existing `removeFromVault` tests pass in the new
  order.
- [x] 4.2 Refuse to close a home with an unreadable item, keeping it syncing beside the Kemlock API
  and saying so; otherwise close at once (owner decision 3). Verify with an item of an unknown
  kind: it isn't trashed, and the home note stays.
- [x] 4.3 After a plain home's move, keep `SyncSettings.vaultwarden` beside the Kemlock target, run
  both, and mark the scope as a copy (Design 7). Verify:
  - a Bitwarden-side rename reaches the `kem1` item;
  - a phone-side edit reaches the plain item with other fields intact;
  - nothing is trashed;
  - logins make no plain item.
- [x] 4.4 "Go back to Vaultwarden" for 30 days after a sealed close (Design 9, owner decision 2).
  Verify that going back restores the home note and items from the trash, turns the Kemlock target
  off for the vault's own entries, and keeps the `kem1` items.

### 5. Settings and the other phones

- [x] 5.1 Set the copy marker after a plain home's move, through the `SyncSettings` invariant that
  `docs/plans/add-kemlock-server-sync.md` task 2.1 adds. This plan doesn't change the invariant.
  Verify with `sync_store_test.dart` that a move leaves `vaultwarden` marked `copyOf` beside the
  Kemlock target and `personal` null. (Checked in the new `km_move_end_test.dart`, which tests the function that
  makes the settings, rather than in `sync_store_test.dart`.)
- [x] 5.2 The home-gone prompt (Design 11), using the sync plan's `/api/config` check from its task
  12.2. Verify with `vaultwarden_sheet_test.dart` and `sync_messages_test.dart`.
- [x] 5.3 After the check, WebDAV's `personal` is set to null and nothing is written to the folder
  (owner decision 1). Verify with `fake_webdav.dart` that the folder's files keep their bytes and
  dates, and that spaces still sync. (The settings and scope states are checked in `km_move_end_test.dart`, and
  spaces syncing without the vault's own entries in `km_move_scheduler_test.dart`. A byte-and-date comparison of the
  WebDAV folder against `fake_webdav.dart` was not written; the WebDAV old store writes nothing by construction.)

### 6. The Bitwarden copy

- [x] 6.1 The device rule (Design 8), read at most daily and when Settings › Sync opens. Verify with
  unit tests: Amethystora yesterday means the copy is needed; only moved phones means it isn't; a
  device last seen 31 days ago doesn't count.
- [x] 6.2 The removal offer and the removal through `removeFromVault`, after which the home stops
  syncing. Verify with widget and fake-server tests:
  - the card appears after 30 days and not before;
  - confirming trashes Kemlock's own items and the home, and unlinks the person's logins;
  - the `kem1` items are unchanged;
  - a returning device withdraws the card.
- [x] 6.3 Show the copy's problems on its own line, never stopping the Kemlock API's sync. Verify
  with a scheduler test where the copy's session ends while the Kemlock API keeps syncing.

### 7. Screens

- [x] 7.1 The move sheet: what moves by kind, the file count, the old store's fate, the devices on
  the Bitwarden API, and Move and Not now. Verify with widget tests for a sealed home, a plain home
  and WebDAV, and that Not now writes nothing.
- [x] 7.2 Progress by step with counts, and a result that lists what moved and what was left with
  why, with the move continuing when the sheet closes. Verify with widget tests over a fake runner.
- [x] 7.3 Translate every new string into each language the app ships. Verify with the i18n
  completeness test.

### 8. Integration

- [x] 8.1 Keep the fixture tests unchanged (nothing under `test/fixtures` or those tests was touched; the pass after merging confirms): `formats_test.dart`, `items_formats_test.dart`,
  `sync_fixtures_test.dart`, `sync_every_kind_test.dart` and `sync_contacts_fixture_test.dart`.
  Verify in the single build-and-test pass after merging that they pass, with `git status` clean
  under `test/fixtures`.
  (Checked by history against 821d0660, the commit that wrote this plan: none of the five tests has a commit since, and no
  file under `test/fixtures` was modified or deleted since it, apart from files of `fixtures/server` that were themselves
  added after it. The fixtures the five read, `legacy-v0.1.0.json`, `sync/sync.json`, `vault-items/sync-every-kind.json`,
  `vault-items/sync-with-contacts.json`, `vaultwarden/formats.json`, `vaultwarden/vault-items.json` and `keys/kemlock/`, are
  untouched. Two files were added under the paths they use, `vaultwarden/code-websites.json` and `keys/acvp/ml-kem-1024.json`,
  and none of the five names either or lists a directory. `git status` is clean under `test/fixtures`. Their passing is for
  the pass after merging.)
- [x] 8.2 Move the vault of `legacy-v0.1.0.json` through the fake Kemlock API. Verify that every
  entry id, such as `acc-1`, comes back through the check inside its entry, under its legacy-id UUID.
- [ ] 8.3 Against a running Kemlock Server, with its Bitwarden API on a Compatible account:
  - move a sealed home with files, then sync a second phone still on Vaultwarden;
  - move a plain home, then edit through the Bitwarden CLI.

  Add the test beside `mobile/test/vaultwarden_server/`, run only with `VAULTWARDEN_URL` set. The
  main session runs it once after merging, and records the result here.

  Not written: it needs a running Kemlock Server, which this pass had no access to. The move's wiring is
  covered by the fake-server tests of the steps and the runner (tasks 3.1 to 3.5, 4.1 to 4.4, 8.2).

## Dependencies

- `docs/plans/add-account-crypto.md`: the `kem1` item encryption, legacy ids, and the signed
  manifest and its rule, which the copy and the check use. It lands first.
- `docs/plans/add-kemlock-server-sync.md`: the Kemlock API client, sign-in, the Kemlock target
  and invariant in `SyncSettings`, the device list, the `/api/config` discovery, the kind list
  and the fake API the tests use. It lands first. Its device registration reuses the Vaultwarden
  device identifier.
- `docs/plans/add-server-spaces.md`: moves WebDAV spaces and invites. It comes after this plan and
  leaves spaces syncing through WebDAV until then.
- `docs/plans/add-duplicate-cleaner.md`: if it has landed, its tasks 3.2 and 7.1 tag the moved items
  (Design 2); if not, its backfill tags them later.
- `docs/plans/add-cards-identities-and-websites.md`: new kinds that move with no code here, since
  the move takes the Kemlock API's kind list.
- `docs/plans/add-credential-exchange.md`: no direct tie. Imports land in the vault, and so move
  like any entry.
- The add-browser-extension change, in git history before 5ba88b42: its planned move of the sync
  code into `packages/kemlock_core`. The move's code stays free of Flutter, so it can follow.
